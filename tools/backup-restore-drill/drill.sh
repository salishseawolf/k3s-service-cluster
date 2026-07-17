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
  imageName: ghcr.io/cloudnative-pg/postgresql:18
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
# Idempotency: clean up from any previous run
echo "  Cleaning up prior run resources..."
kubectl -n velero delete restore -l velero.io/backup 2>/dev/null || true
for ns in $(kubectl get pods --all-namespaces -l run=backup-debug -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\\n' | sort -u); do
  kubectl -n "$ns" delete pod backup-debug --ignore-not-found --now 2>/dev/null || true
done
# Remove stale PVCs from previous runs (except database — handled by CNPG)
for claim in $(kubectl get pvc --all-namespaces -o json 2>/dev/null | python3 -c "
import sys,json; exclude={'database','velero','kube-system','default','cnpg-system'};
[print(f'{i[\"metadata\"][\"namespace\"]}/{i[\"metadata\"][\"name\"]}') for i in json.load(sys.stdin).get('items',[]) if i['metadata']['namespace'] not in exclude]
" 2>/dev/null || true); do
  ns=$(echo "$claim" | cut -d/ -f1)
  name=$(echo "$claim" | cut -d/ -f2)
  kubectl -n "$ns" delete pvc "$name" --ignore-not-found --wait=false 2>/dev/null || true
done

# Install Velero with B2 credentials
# Use op inject to reliably resolve secret references — env-var expansion
# via heredocs is fragile with op run + mise interplay.
op inject -i /dev/stdin -o /tmp/velero-credentials.txt <<'INJEOF'
[default]
aws_access_key_id=op://K3s Service Cluster/BackBlaze Velero B2 Bucket/s3_key_id
aws_secret_access_key=op://K3s Service Cluster/BackBlaze Velero B2 Bucket/s3_application_key
INJEOF

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket k3s-service-cluster \
  --prefix velero/ \
  --backup-location-config region=us-west-004,s3ForcePathStyle=true,s3Url=https://s3.us-west-004.backblazeb2.com \
  --secret-file /tmp/velero-credentials.txt \
  --use-node-agent \
  --uploader-type kopia \
  --namespace velero \
  --wait

# Restore PVCs from the latest backup
LATEST=$(velero get backups -o json 2>/dev/null | python3 -c "import sys,json; b=json.load(sys.stdin).get('items',[]); print(b[0]['metadata']['name'] if b else '')" 2>/dev/null || echo "")
if [ -n "$LATEST" ]; then
  echo "Restoring from backup: $LATEST"

  # Discover and create decoy StorageClasses for all SCs in restored PVCs
  # (Velero restores PVCs with their original StorageClass names; the test
  # cluster doesn't have them, so we create stand-ins backed by Hetzner CSI)
  ALL_SCS=$(kubectl get pvc --all-namespaces -o jsonpath='{.items[*].spec.storageClassName}' \
    2>/dev/null | tr ' ' '\\n' | sort -u | grep -v '^$' || echo "")
  for sc in $ALL_SCS; do
    kubectl delete sc "$sc" --ignore-not-found 2>/dev/null || true
    kubectl apply -f - <<SCEOF 2>/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $sc
provisioner: hcloud.csi.hetzner.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
SCEOF
  done

  # Create Velero Restore CR for PVCs (exclude database — handled by CNPG)
  kubectl apply -f - <<RSEOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: pvc-restore
  namespace: velero
spec:
  backupName: LATEST_PLACEHOLDER
  excludedNamespaces:
  - database
  - cnpg-system
  - kube-system
  - velero
  - default
  includedResources:
  - persistentvolumeclaims
  restorePVs: true
  preserveNodePorts: false
RSEOF
  kubectl -n velero patch restore pvc-restore --type=json \
    -p='[{"op":"replace","path":"/spec/backupName","value":"'"$LATEST"'"}]'

  # Wait for PVCs to appear (Velero creates them asynchronously)
  echo "Waiting for PVCs to be restored..."
  for i in $(seq 1 30); do
    PVC_COUNT=$(kubectl get pvc --all-namespaces --ignore-not-found \
      2>/dev/null | tail -n+2 | wc -l)
    [ "$PVC_COUNT" -gt 0 ] && break
    sleep 5
  done

  # Strip volumeName from all restored PVCs so Hetzner CSI can provision
  TEST_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "k3s-test-node-01")
  echo "Stripping volumeName from restored PVCs..."
  for claim in $(kubectl get pvc --all-namespaces -o json 2>/dev/null | \
    python3 -c "import sys,json; [print(f'{p[\"metadata\"][\"namespace\"]}/{p[\"metadata\"][\"name\"]}') for p in json.load(sys.stdin).get('items',[]) if p['metadata']['namespace'] not in ('database','velero','kube-system','default','cnpg-system')]" 2>/dev/null || true); do
    ns=$(echo "$claim" | cut -d/ -f1)
    name=$(echo "$claim" | cut -d/ -f2)
    kubectl -n "$ns" patch pvc "$name" --type=json \
      -p='[{"op":"remove","path":"/spec/volumeName"}]' 2>/dev/null || true
  done

  # Create debug pods to trigger PVC binding (WaitForFirstConsumer) + Kopia restore
  for pvc in $(kubectl get pvc --all-namespaces -o json 2>/dev/null | \
    python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); exclude={'database','velero','kube-system','default','cnpg-system'}; seen=set(); [print(f'{i[\"metadata\"][\"namespace\"]}:{i[\"metadata\"][\"name\"]}') for i in items if i['metadata']['namespace'] not in exclude and i['metadata']['namespace'] not in seen and not seen.add(i['metadata']['namespace'])]" 2>/dev/null || true); do
    ns=$(echo "$pvc" | cut -d: -f1)
    echo "Creating debug pod in namespace: $ns"

    # Build volume mounts dynamically from PVCs in this namespace
    VOLUMES=""
    MOUNTS=""
    idx=0
    for pvc_name in $(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      VOLUMES="$VOLUMES,{\"name\":\"vol$idx\",\"persistentVolumeClaim\":{\"claimName\":\"$pvc_name\"}}"
      MOUNTS="$MOUNTS,{\"name\":\"vol$idx\",\"mountPath\":\"/data/$pvc_name\"}"
      idx=$((idx + 1))
    done
    VOLUMES="[${VOLUMES:1}]"
    MOUNTS="[${MOUNTS:1}]"

    # Spa a PSA-compliant debug pod that sleeps so user can exec in
    kubectl run backup-debug -n "$ns" --image=alpine:3.21 --restart=Never --overrides='{
      "spec":{
        "nodeSelector":{"kubernetes.io/hostname":"'"$TEST_NODE"'"},
        "containers":[{
          "name":"backup-debug",
          "image":"alpine:3.21",
          "command":["sleep","infinity"],
          "securityContext":{
            "allowPrivilegeEscalation":false,
            "capabilities":{"drop":["ALL"]},
            "runAsNonRoot":true,
            "runAsUser":1000,
            "runAsGroup":1000,
            "seccompProfile":{"type":"RuntimeDefault"}
          },
          "volumeMounts":'"$MOUNTS"'
        }],
        "volumes":'"$VOLUMES"'
      }
    }' 2>/dev/null || echo "  WARNING: could not create debug pod in $ns"
  done

  # Wait for debug pods to be Ready (triggers CSI binding + Kopia restore)
  echo "Waiting for PVC binding and Kopia restore..."
  for ns in $(kubectl get pods --all-namespaces -l run=backup-debug \
    -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\\n' | sort -u); do
    echo "  Waiting for $ns..."
    kubectl -n "$ns" wait --for=condition=Ready pod/backup-debug --timeout=300s 2>/dev/null && \
      echo "  $ns: Ready" || \
      echo "  WARNING: $ns: not Ready within 5m (check kubectl -n $ns describe pod/backup-debug)"
  done

  # Verify Kopia restore completion via node-agent logs
  echo "=== Kopia restore status ==="
  kubectl -n velero logs daemonset/node-agent --tail=5 2>/dev/null | \
    grep -E 'restore|completed|error|failed' | tail -3 || echo "  No restore events in node-agent logs yet"
  echo ""
  echo "=== Manual verification available ==="
  for ns in $(kubectl get pods --all-namespaces -l run=backup-debug \
    -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\\n' | sort -u); do
    echo "  kubectl exec -it -n $ns backup-debug -- sh"
  done
  echo ""
  echo "File counts per namespace:"
  for ns in $(kubectl get pods --all-namespaces -l run=backup-debug \
    -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\\n' | sort -u); do
    count=$(kubectl -n "$ns" exec backup-debug -- find /data -type f 2>/dev/null | wc -l)
    echo "  $ns: $count files"
  done
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
echo "=== Restored PVCs ==="
kubectl get pvc --all-namespaces --ignore-not-found 2>/dev/null || echo "No PVCs"
echo "=== Debug pods ==="
kubectl get pods --all-namespaces -l run=backup-debug -o wide 2>/dev/null | tail -n+2 | awk '{print $1"/"$2": "$3}' || echo "No debug pods"
echo "=== PVC status ==="
kubectl get pvc --all-namespaces 2>/dev/null || echo "No PVCs"
echo ""
echo "Drill complete. Validate further with:"
echo "  kubectl -n database exec main-db-1 -c postgres -- psql -U postgres -c \"\\l\""
echo "  kubectl -n database exec main-db-1 -c postgres -- psql -U postgres -d authentik -c \"\\dt\""
echo "  kubectl get pvc --all-namespaces"

