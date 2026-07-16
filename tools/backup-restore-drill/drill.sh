#!/bin/bash
set -e
TOFU_DIR="$MISE_PROJECT_ROOT"/../test-cluster/tofu

echo "==> Phase 1: Provision test cluster (OpenTofu)..."
cd "$TOFU_DIR"
tofu init -no-color
tofu apply -auto-approve
echo ""

echo "==> Phase 2: Bootstrap K3s (Ansible)..."
cd "$MISE_PROJECT_ROOT"/../../bootstrap/ansible
ansible-galaxy collection install -r requirements.yml
ANSIBLE_CONFIG=ansible.cfg ansible-playbook \
  -i inventory/test/hcloud.yml \
  playbooks/k3s-cluster.yml \
  -e hcloud_project_label=k3s-service-cluster-test \
  -e k3s_cluster_init_node=k3s-test-node-01
echo ""

echo "==> Phase 3: Install restore operators..."
# cert-manager CRDs (needed by barman-cloud plugin, even without full operator)
kubectl apply --server-side --force-conflicts -f \
  https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.crds.yaml

# CNPG operator (via Helm chart, matching production approach)
# Remove all stale resources from cnpg-system namespace (raw manifest → Helm migration)
kubectl delete namespace cnpg-system --ignore-not-found --wait=false 2>/dev/null || true
# Wait for namespace to be fully deleted
while kubectl get namespace cnpg-system 2>/dev/null; do sleep 2; done
# Also remove stale CNPG CRDs
for crd in $(kubectl get crd -o name 2>/dev/null | grep 'cnpg.io' || true); do
  kubectl delete "$crd" --ignore-not-found 2>/dev/null || true
done
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update
helm upgrade --install cnpg cloudnative-pg \
  --repo https://cloudnative-pg.github.io/charts \
  --version 0.27.0 \
  --namespace cnpg-system --create-namespace --wait
kubectl -n cnpg-system wait --for=condition=Ready pods -l app.kubernetes.io/name=cloudnative-pg --timeout=120s 2>/dev/null || true

# Clean stale barman-cloud plugin resources from previous failed run (if any)
kubectl -n cnpg-system delete pod -l app.kubernetes.io/instance=plugin-barman-cloud --ignore-not-found --now 2>/dev/null || true
helm delete plugin-barman-cloud --namespace cnpg-system 2>/dev/null || true

# barman-cloud plugin — pre-create TLS certs since cert-manager isn't running
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/barman-server.key -out /tmp/barman-server.crt \
  -subj "/CN=barman-cloud" 2>/dev/null
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/barman-client.key -out /tmp/barman-client.crt \
  -subj "/CN=barman-cloud-client" 2>/dev/null
kubectl -n cnpg-system create secret tls barman-cloud-server-tls \
  --cert=/tmp/barman-server.crt --key=/tmp/barman-server.key \
  --dry-run=client -o yaml | kubectl apply -f - --validate=false
kubectl -n cnpg-system create secret tls barman-cloud-client-tls \
  --cert=/tmp/barman-client.crt --key=/tmp/barman-client.key \
  --dry-run=client -o yaml | kubectl apply -f - --validate=false
rm -f /tmp/barman-server.key /tmp/barman-server.crt /tmp/barman-client.key /tmp/barman-client.crt

helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud \
  --version 0.7.0 --namespace cnpg-system --create-namespace \
  --set certificate.createIssuer=false \
  --set certificate.createClientCertificate=false \
  --set certificate.createServerCertificate=false

# Velero
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update
echo ""

echo "==> Phase 4: Restore CNPG database from B2..."
kubectl create ns database --dry-run=client -o yaml | kubectl apply -f -
kubectl -n database create secret generic cnpg-backup-secret \
  --from-literal=s3_key_id="$CNPG_B2_KEY_ID" \
  --from-literal=s3_application_key="$CNPG_B2_APP_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - --validate=false

# ObjectStore CR
cat <<'OBJEOF' | kubectl apply -f -
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: cnpg-b2-store
  namespace: database
spec:
  configuration:
    destinationPath: "s3://k3s-service-cluster/cnpg/"
    endpointURL: "https://s3.us-west-004.backblazeb2.com"
    s3Credentials:
      accessKeyId:
        name: cnpg-backup-secret
        key: s3_key_id
      secretAccessKey:
        name: cnpg-backup-secret
        key: s3_application_key
  retentionPolicy: "30d"
OBJEOF

# Recovery cluster CR
cat <<'CLUEOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: main-db
  namespace: database
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17
  bootstrap:
    recovery:
      source: prod-backup
  externalClusters:
    - name: prod-backup
      barmanObjectStore:
        destinationPath: "s3://k3s-service-cluster/cnpg/"
        endpointURL: "https://s3.us-west-004.backblazeb2.com"
        serverName: main-db
        s3Credentials:
          accessKeyId:
            name: cnpg-backup-secret
            key: s3_key_id
          secretAccessKey:
            name: cnpg-backup-secret
            key: s3_application_key
  storage:
    size: 10Gi
    storageClass: hcloud-volumes
  walStorage:
    size: 5Gi
    storageClass: hcloud-volumes
CLUEOF

echo "Waiting for CNPG recovery (up to 15 min)..."
kubectl -n database wait --for=condition=Ready cluster/main-db --timeout=900s || \
  echo "Timed out — check: kubectl -n database get pods"
echo ""

echo "==> Phase 5: Restore Velero PVCs from B2..."
# Install Velero with B2 credentials
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket k3s-service-cluster \
  --prefix velero/ \
  --backup-location-config region=us-west-004,s3ForcePathStyle=true,s3Url=https://s3.us-west-004.backblazeb2.com \
  --secret-file <(cat <<SECRETS
[default]
aws_access_key_id=$VELERO_B2_KEY_ID
aws_secret_access_key=$VELERO_B2_APP_KEY
SECRETS
  ) \
  --use-node-agent \
  --uploader-type kopia \
  --namespace velero \
  --wait

# Restore PVCs from the latest backup
LATEST=$(velero get backups -o json 2>/dev/null | python3 -c "import sys,json; b=json.load(sys.stdin).get('items',[]); print(b[0]['metadata']['name'] if b else '')" 2>/dev/null || echo "")
if [ -n "$LATEST" ]; then
  echo "Restoring from backup: $LATEST"
  velero restore create --from-backup "$LATEST" \
    --include-resources persistentvolumeclaims,persistentvolumes \
    --exclude-namespaces database,cnpg-system \
    --wait
else
  echo "No backups found. Check velero get backups"
fi
echo ""

echo "==> Phase 6: Data validation..."
echo "---"
echo "=== Database check ==="
kubectl -n database exec main-db-1 -c postgres -- psql -U postgres -c "\\l" 2>/dev/null || echo "Database not ready yet"
echo "---"
echo "=== Velero backup status ==="
velero get backups 2>/dev/null || echo "Velero not ready"
echo "=== Velero restore status ==="
velero get restores 2>/dev/null || echo "No restores yet"
echo "=== PVC status ==="
kubectl get pvc --all-namespaces 2>/dev/null || echo "No PVCs"
echo ""
echo "Drill complete. Validate further with:"
echo "  kubectl -n database exec main-db-1 -c postgres -- psql -U postgres -c \"\\l\""
echo "  kubectl -n database exec main-db-1 -c postgres -- psql -U postgres -d authentik -c \"\\dt\""
echo "  kubectl get pvc --all-namespaces"

