# Full Cluster Restore Test — Technical Strategy

## Goal

Provision a temporary, isolated 3-node K3s cluster on Hetzner that mirrors
production topology (3 converged nodes + control-plane LB + private network,
bootstrapped by the SAME Ansible playbooks as prod) and restore the full
production workload from Backblaze B2 backups (Velero kopia + CNPG
barman-cloud). Prove the backup pipeline AND the bootstrap runbook end-to-end
with zero cross-talk to production.

---

## 1. DNS / Boundaries

### Problem
Cloudflare wildcard (`*.salishseawolf.com`) resolves to the production LB.
Any app restored to the test cluster that serves on the same domain will be
unreachable (DNS points to prod), and conversely, the test cluster cannot
create DNS entries that collide with prod.

### Solution: Separate registered domain via Cloudflare + test-specific cluster-values

**Approach: Separate domain (`salishseawolf.bid`)**

- The user owns `salishseawolf.bid` — a completely separate domain with no
  overlap to production.
- Create a Cloudflare DNS record: `*.salishseawolf.bid` → the test
  control-plane LB's public IP.
- The test cluster uses `salishseawolf.bid` as its domain — no DNS collision
  with `*.salishseawolf.com`.
- All application IngressRoutes, Authentik blueprints, Gitea autoDiscoverUrl,
  etc. will derive from this domain via the single `cluster-values.yaml`.

**Implementation:**

1. Before provisioning, manually add a Cloudflare A record:
   ```
   *.salishseawolf.bid  →  <test-server-public-ip>  (TTL 300, unproxied)
   ```
2. The test cluster's `platform/argocd/root/cluster-values.yaml` is patched
   to set `domain: salishseawolf.bid`.
3. Authentik's `AUTHENTIK_HOST` env (rendered from domain ConfigMap) becomes
   `auth.salishseawolf.bid`.
4. Gitea's `autoDiscoverUrl` becomes
   `https://auth.salishseawolf.bid/application/o/gitea/.well-known/openid-configuration`.
5. All cert-manager Certificate resources will request certs for
   `*.salishseawolf.bid` — Let's Encrypt HTTP-01 or DNS-01 challenge
   will work. Prefer the DNS-01 solver (Cloudflare credentials are already in
  the vault) — it needs no inbound 80/443, so the test firewall can stay
  locked to the admin IP.

**Cleanup:** Delete the `*.salishseawolf.bid` record from Cloudflare
after teardown.

**Alternative (simpler, no DNS at all):** Access test apps via
`http://<server-ip>:<nodeport>` or `kubectl port-forward`. This skips DNS
entirely but means OIDC redirects won't work (Authentik needs a resolvable
hostname). The separate-domain approach is preferred for realism.

---

## 2. OIDC / SSO (Authentik)

### Problem
Authentik is part of production. It authenticates users at
`auth.salishseawolf.com` and issues OIDC tokens with an issuer URL rooted in
that domain. Apps on the test cluster cannot redirect users to prod Authentik
and then back to `salishseawolf.bid` — the redirect URI mismatch will
break OIDC.

Additionally, Authentik's blueprints (13 of them) register OAuth2/Proxy
providers with hardcoded redirect URIs containing the domain. These will need
the test domain.

### Solution: Restore Authentik to the test cluster with the test domain

**Step 1: Restore the Authentik database from CNPG backup**
The Authentik helm chart stores all state in its PostgreSQL database
(`authentik` database on the CNPG `main-db` cluster). When the database is
restored, all applications, providers, users, groups, and flows are intact.

**Step 2: Domain rewrite after restore**
The blueprints that create OAuth2/Proxy providers embed the domain in
redirect URIs (e.g., `https://gitea.salishseawolf.com/...`). After the
Authentik server comes up on `salishseawolf.bid`, the following
providers will have stale redirect URIs:

| Provider | Stale URI | New URI |
|---|---|---|
| Gitea OIDC | `*.salishseawolf.com` | `*.salishseawolf.bid` |
| Homarr OIDC | `homarr.salishseawolf.com` | `homarr.salishseawolf.bid` |
| Paperless OIDC | `paperless.salishseawolf.com` | `paperless.salishseawolf.bid` |
| ArgoCD OIDC | `argocd.salishseawolf.com` | `argocd.salishseawolf.bid` |
| Copyparty proxy | `files.salishseawolf.com` | `files.salishseawolf.bid` |
| Gatus proxy | `status.salishseawolf.com` | `status.salishseawolf.bid` |
| SeaweedFS proxy | `s3.salishseawolf.com` | `s3.salishseawolf.bid` |

**Step 3: Post-restore domain migration**
Option A (preferred): Reset the Authentik admin password via bootstrap
credentials and manually update each provider's redirect URI in the Admin
UI.  This takes ~10 minutes and is the simplest approach.

Option B (scripted): After the Authentik pod is running, exec into it and use
`ak` CLI to patch providers:
```bash
kubectl -n identity exec deploy/identity-authentik-server -- ak update provider-oauth2 gitea-oidc --redirect-uris "https://gitea.salishseawolf.bid/..."
```
Repeat for each provider. This is faster but requires knowing all provider
names (they can be listed with `ak list provider-oauth2`).

Option C (re-apply blueprints): Edit the blueprint ConfigMap to replace all
references to `salishseawolf.com` with `salishseawolf.bid`, then apply
it. Authentik will re-create providers with the correct URIs. Caveat: this
may conflict with existing database state; test carefully.

**Bottom line:** Authentik is restored from the same database, brought up on
the test domain, and providers are patched to use the test domain. No
interaction with prod Authentik at any point.

---

## 3. Secrets (1Password)

### Problem
The production cluster uses 1Password Connect + Operator to sync secrets. The
test cluster needs the same secrets to start applications, but must do so
without risking writes or token leakage to prod.

### Approach A: Reuse production 1Password Connect token (read-only)

The 1Password Operator uses a Service Account token scoped to the `K3s
Service Cluster` vault. The token has full read access to all vault items.

**Safety analysis:**
- The token is already stored in the agent's environment
  (`OP_SERVICE_ACCOUNT_TOKEN` in `/root/.hermes/.env` and referenced via
  `mise.toml`).
- The operator only reads secrets and creates Kubernetes Secret objects. It
  cannot write back to 1Password.
- Running a second Connect+Operator instance against the same vault is
  supported by 1Password — each Connect instance connects independently.

**Procedure:**
```bash
# On the machine running the test (which already has access):
export OP_CONNECT_JWT=$(op connect token create test-cluster-connect --vault "K3s Service Cluster" --server <your-1p-server>)
export OP_OPERATOR_TOKEN="<copy from agent env>"
```
Then run the same Ansible bootstrap playbook with these env vars set. The
1Password Connect and Operator will deploy on the test cluster and sync all
vault items.

**Alternative (safer): Create a dedicated Service Account**
1. In 1Password, create a new Service Account `test-cluster-operator`
2. Grant it read-only access to the `K3s Service Cluster` vault
3. Use its token for the test cluster
4. Revoke the Service Account after teardown

This is preferred because:
- The token is scoped to a single test purpose
- It can be revoked independently
- Audit log shows exactly what the test cluster accessed

**Key vault items the test cluster needs:**

| Item | Purpose |
|---|---|
| `ArgoCD Github Token` | Argo reads repo from GitHub mirror |
| `BackBlaze Velero B2 Bucket` | Velero restores from B2 |
| `BackBlaze CNPG B2 Bucket` | CNPG restores from B2 |
| `Authentik Deployment Secrets` | Authentik bootstrap |
| `Gitea Secrets` | Gitea OIDC, admin, DB creds |
| `Homarr Secrets` | Homarr encryption + OIDC |
| `Paperless Secrets` | Paperless secret key + OIDC |
| `Redis Password` | Redis requirepass |
| `Cloudflare DNS Challenge` | cert-manager DNS-01 solver |
| `Gatus Secrets` | Gatus DB password |
| `SeaweedFS Secrets` | SeaweedFS DB password |
| `Resend SMTP` | Authentik email |

---

## 4. Backblaze B2 Read Access

### Problem
The backup bucket `k3s-service-cluster` is shared. The test cluster must read
from it without writing, deleting, or corrupting anything.

### Safety analysis

**Velero restore:**
- Velero `restore create` is a read-only operation from B2's perspective. It
  downloads backup tarballs and creates Kubernetes resources + PVCs.
- Velero does NOT write to the backup storage location during a restore.
- The B2 Application Key used by Velero (`BackBlaze Velero B2 Bucket`) needs
  only `readBuckets` + `listBuckets` permissions. In practice, the existing
  key likely has full read/write (it's also used for backups), but a restore
  never calls write APIs.

**CNPG barman-cloud restore:**
- CNPG's `bootstrap.recovery` runs `barman-cloud-restore` which downloads
  base backups + WAL segments from the B2 bucket.
- It does not create new backups or write to the bucket during restore.
- The B2 Application Key (`BackBlaze CNPG B2 Bucket`) needs only read
  permissions. Again, the existing key has write for daily backups, but the
  restore path never writes.

**Risk mitigation — create read-only B2 keys for the test:**
For maximum safety, create dedicated B2 Application Keys:
1. `test-cluster-velero-read` — scoped to `k3s-service-cluster`, prefix
   `velero/`, permissions: `readBuckets` only
2. `test-cluster-cnpg-read` — scoped to `k3s-service-cluster`, prefix
   `cnpg/`, permissions: `readBuckets` only

Create these in 1Password as separate items or overwrite the existing
OnePasswordItem CRs on the test cluster to point to the read-only variants.

**Verdict:** B2 read access is safe. The restore operations are inherently
read-only. Creating scoped, read-only keys adds defense-in-depth and prevents
any possible misconfiguration from writing to the production backup bucket.

---

## 5. Network Isolation

### Production network topology
- Hetzner private network: `192.168.0.0/16` (subnet `192.168.1.0/24`)
- Production nodes: `192.168.1.2`, `192.168.1.3`, `192.168.1.4`
- Production LB: `192.168.1.10`
- Hetzner Cloud Firewall on all prod nodes:
  - Ingress 22, 6443 → admin IP only (`73.97.54.81/32`)
  - Ingress 80, 443 → admin IP + `192.168.0.0/16`
  - Ingress all TCP/UDP → `192.168.0.0/16`
  - ICMP → `192.168.0.0/16`

### Test cluster network design

**Option A: Same private network (isolated via IP)**
- Place the test nodes on the SAME `k3s-network` (`192.168.0.0/16`)
- Assign it a static IP outside the production subnet range, e.g.
  `192.168.2.0/24` or `192.168.1.100/32`
- The test nodes CAN reach production nodes on `192.168.1.0/24` over the
  private network (the prod firewall allows all traffic from
  `192.168.0.0/16`).

**RISK:** The test nodes can reach prod Kubernetes API on port 6443, prod
  Traefik on 80/443, and any pods on the private network. A misconfigured
  service restoration could connect to production resources.

**Option B: Separate Hetzner private network (recommended)**
- Create a new `hcloud_network` for the test: `k3s-network-test` with range
  `10.0.0.0/16` (or `192.168.200.0/24`)
- The test nodes are on this isolated network. They cannot reach production
  nodes on `192.168.0.0/16` because Hetzner private networks are isolated
  from each other.
- The test nodes' public IPs have their OWN firewall with only the admin IP
  whitelisted (ingress traffic arrives via the test LB, mirroring prod).

**Recommended configuration:** implemented in `tools/test-cluster/tofu/`
(3 nodes on `10.0.1.2-4`, LB on `10.0.1.10`, separate network `10.0.0.0/16`,
prod-mirrored firewall). See that module rather than duplicating HCL here.

**Key isolation properties:**
- Test nodes are on a separate Hetzner private network (`10.0.0.0/16`) with
  no route to the production `192.168.0.0/16` network.
- Test firewall's internal rules only admit `10.0.0.0/16` — prod's
  `192.168.0.0/16` is not in the rules (and vice versa on the prod firewall).
- Ansible-level isolation: the test dynamic inventory matches only
  `project=k3s-service-cluster-test`; the prod inventory matches only
  `project=k3s-service-cluster`. Neither playbook run can see the other
  environment's nodes, LB, or network.
- **Result:** No IP-level connectivity between test and prod in either
  direction. They are two isolated networks.

**Kubernetes-level isolation:**
- Restored pods on the test cluster reference services by cluster-local DNS
  (e.g., `main-db-rw.database.svc.cluster.local`). These resolve inside the
  test cluster's own DNS — they cannot accidentally reach production because
  the test cluster has its own CoreDNS.

**Known exception — external services:**
- Authentik's email backend: Resend SMTP (`smtp.resend.com:465`). The test
  cluster will try to send emails during bootstrap. This is harmless but
  should be noted (Authentik sends bootstrap emails).
- Gitea's push mirror: If Gitea restores its push-mirror config, it will try
  to push to GitHub. Mitigation: delete the push-mirror config after restore
  or ensure the GitHub token is read-only.

---

## 6. Post-Test Cleanup

### Must remove (order matters):

1. **Cloudflare DNS records**
   ```bash
   # Remove the test wildcard record
   # Via API or Cloudflare dashboard
   curl -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
     -H "Authorization: Bearer ${CF_TOKEN}"
   ```

2. **Hetzner resources**
   ```bash
   cd test-cluster/tofu
   tofu destroy
   ```
   This destroys: server, network, subnet, firewall, and any other Hetzner
   resources created for the test.

3. **1Password Service Account (if created)**
   - In 1Password: Settings → Service Accounts → find `test-cluster-operator`
   - Revoke or delete it

4. **B2 Application Keys (if created)**
   - In Backblaze B2: App Keys → find `test-cluster-*` keys
   - Delete them

5. **Local artifacts**
   ```bash
   rm -f bootstrap/ansible/kubeconfig   # test cluster kubeconfig
   ```

6. **cert-manager Let's Encrypt certificates**
   - The test cluster will have requested real Let's Encrypt certificates for
     `*.salishseawolf.bid`. These are automatically deleted when the
     cluster is destroyed (they exist only as Kubernetes Secrets and
     cert-manager CRs). No cleanup needed.
   - Let's Encrypt rate limits: `salishseawolf.bid` is its own registered
     domain with its own quota (50 certs/week) — it does NOT count against
     `salishseawolf.com`. A single test run uses 1-2 certs either way.

### Must NOT touch:
- Production Hetzner resources (network `k3s-network`, nodes
  `k3s-converged-node-*`, LB, firewall `k3s-firewall`)
- `salishseawolf.com` Cloudflare records (root + wildcard)
- B2 bucket contents (never delete or modify)
- 1Password vault items (only delete test-specific SA tokens)

### Verification checklist after teardown:
- `hcloud server list` — no `k3s-test-*` servers
- `hcloud load-balancer list` — no `k3s-control-plane-lb-test`
- `hcloud volume list` — no volumes from test PVCs
- `hcloud network list` — no `k3s-network-test`
- `hcloud firewall list` — no `k3s-firewall-test`
- Cloudflare DNS zone: no `*.salishseawolf.bid` record
- `curl https://auth.salishseawolf.bid` → should fail to resolve or
  connect
- Production cluster: `kubectl get nodes` — all three nodes healthy, no
  unexpected namespaces

---

## 7. Step-by-Step Procedure

### Prerequisites
- Access to machine with:
  - `op` CLI (1Password) authenticated
  - `tofu` (OpenTofu)
  - `ansible`
  - `kubectl`
  - `mise` (task runner)
  - `hcloud` CLI or Hetzner Cloud API token
- Production cluster healthy and accessible (for reference, not modification)
- Git push access to the GitHub mirror (for the test cluster-values change)

### Phase 0 — Prepare test infrastructure (15 min)

**0.1 Test OpenTofu lives in the repo**

`tools/test-cluster/tofu/` mirrors `infrastructure/tofu` — 3 nodes
(`k3s-test-node-01..03`), a control-plane LB, private network `10.0.0.0/16`,
and the prod firewall rule set. It reuses production's `cloud-init.yaml` and
`files/provision.d/` scripts via relative path, so node provisioning is
byte-identical to prod. All resources carry `project=k3s-service-cluster-test`
so neither the prod dynamic inventory nor `hcloud_facts` can ever match them.

**0.2 Create Cloudflare DNS record**
```bash
# Get the zone ID from 1Password
ZONE_ID=$(op read "op://K3s Service Cluster/Cloudflare DNS Challenge/zone_id")
CF_TOKEN=$(op read "op://Hermes Agent/K3s Service Cluster Cloudflare DNS Challenge/token")

# We'll create the record AFTER provisioning the server (need its public IP)
```

**0.3 Prepare test cluster-values**
```bash
# In the repo, create a test branch:
cd /workspace
git checkout -b test-full-cluster-restore

# Edit platform/argocd/root/cluster-values.yaml:
# domain: "salishseawolf.bid"
# gitea.oauth.autoDiscoverUrl: "https://auth.salishseawolf.bid/..."
```

**0.4 Create read-only B2 keys (optional but recommended)**
```bash
# Create in Backblaze B2 Console or via API:
# Key 1: test-velero-read — bucket k3s-service-cluster, prefix velero/, read-only
# Key 2: test-cnpg-read — bucket k3s-service-cluster, prefix cnpg/, read-only
```

**0.5 Create 1Password Service Account (optional but recommended)**
- 1Password → Settings → Service Accounts → Create
- Name: `test-cluster-operator`
- Vault: `K3s Service Cluster`
- Permissions: Read Only
- Save the token as `$TEST_OP_OPERATOR_TOKEN`
- Create a Connect token: `op connect token create test-cluster-connect
  --vault "K3s Service Cluster" --server <server>`
- Save as `$TEST_OP_CONNECT_JWT`

### Phase 1 — Provision test infrastructure (10 min)

**1.1 Apply OpenTofu**
```bash
cd tools/test-cluster/tofu

# Set required env vars
export HCLOUD_TOKEN=$(op read "op://Hermes Agent/K3s Service Cluster Hermes Hetzner/token")
export TF_VAR_admin_cidr="73.97.54.81/32"
export TF_VAR_ssh_key_name="<ssh-key-name>"  # same as prod

tofu init
tofu apply
```

**1.2 Create DNS record**

⚠️ The record lives in the **salishseawolf.bid zone**, not the .com zone. The
`zone_id` stored in "Cloudflare DNS Challenge" is the .com zone — look up the
.bid zone ID separately, and confirm the API token's zone scope covers it.

```bash
LB_IP=$(tofu output -raw test_lb_ip)
BID_ZONE_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=salishseawolf.bid" \
  -H "Authorization: Bearer ${CF_TOKEN}" | jq -r '.result[0].id')
curl -X POST "https://api.cloudflare.com/client/v4/zones/${BID_ZONE_ID}/dns_records" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "A",
    "name": "*.salishseawolf.bid",
    "content": "'${LB_IP}'",
    "ttl": 300,
    "proxied": false,
    "comment": "Test cluster restore — temporary"
  }'
```

### Phase 2 — Bootstrap K3s and ArgoCD (15 min)

**2.1 Bootstrap K3s with the SAME Ansible playbooks as production**

This is the realism payoff of the 3-node mirror: the drill exercises the
actual DR bootstrap path — HA embedded etcd (cluster-init + serial joins),
CIS-hardened K3s args, hcloud-ccm, hcloud-csi, and the encryption/audit
config — exactly as it would run after total infrastructure loss.

The test inventory (`inventory/hcloud-test.yml`) only matches
`project=k3s-service-cluster-test`, and the two extra-vars repoint the
init-node name and the `hcloud_facts` label lookups; nothing here can touch
prod nodes.

```bash
cd bootstrap/ansible

export HCLOUD_TOKEN=$(op read "op://Hermes Agent/K3s Service Cluster Hermes Hetzner/token")
export K3S_TOKEN=$(openssl rand -hex 16)
export K3S_ETCD_SECRET=$(openssl rand -base64 32)

ansible-playbook -i inventory/hcloud-test.yml playbooks/k3s-cluster.yml \
  -e hcloud_project_label=k3s-service-cluster-test \
  -e k3s_cluster_init_node=k3s-test-node-01

# Kubeconfig is retrieved by the playbook (endpoint = the test LB IP)
export KUBECONFIG=./kubeconfig
kubectl get nodes   # expect 3 Ready nodes
```

⚠️ Exposure note: like prod, the LB's services (6443/80/443/2222) cannot have
a Hetzner firewall attached and are publicly reachable. The node firewall
restricts direct node access to the admin IP, and apps are gated by
TLS + Authentik — but during the drill, restored production data sits behind
a public LB on `*.salishseawolf.bid`. Keep the drill window short and tear
down promptly. (This is also true of prod's LB, which is worth a separate
review.)

**2.2 Install 1Password Connect + Operator**
```bash
helm repo add 1password https://1password.github.io/connect-helm-charts/
helm repo update

# NOTE: connect.credentials expects the 1password-credentials.json file
# produced by `op connect server create` — NOT a connect token JWT and NOT a
# service-account token. Three distinct artifacts:
#   1password-credentials.json  → Connect server identity (connect.credentials)
#   connect token (JWT)         → clients talking TO Connect (operator.token)
#   service-account token       → only for direct SA integrations, unused here
op connect server create test-cluster --vaults "K3s Service Cluster"
# ^ writes 1password-credentials.json to the current directory
TEST_OP_CONNECT_JWT=$(op connect token create test-cluster-connect \
  --server test-cluster --vault "K3s Service Cluster")

helm upgrade --install onepassword-connect 1password/connect \
  --namespace 1password --create-namespace \
  --set-file connect.credentials=1password-credentials.json \
  --set operator.create=true \
  --set operator.token.value="$TEST_OP_CONNECT_JWT" \
  --wait
```

**2.3 Patch OnePasswordItem CRs for test B2 keys (if using read-only keys)**
```bash
# Once 1P Operator syncs, the secrets will appear. If using read-only B2 keys,
# edit the B2 credential secrets to use test keys instead:
kubectl -n velero patch secret velero-b2-credentials --type merge -p '{
  "stringData": {
    "cloud": "[default]\naws_access_key_id=<test-key-id>\naws_secret_access_key=<test-key-secret>"
  }
}'

kubectl -n database patch secret cnpg-backup-secret --type merge -p '{
  "stringData": {
    "s3_key_id": "<test-cnpg-key-id>",
    "s3_application_key": "<test-cnpg-key-secret>"
  }
}'
```

**2.4 Install ArgoCD**
```bash
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version 7.7.11 \
  --namespace argocd --create-namespace \
  --values /workspace/platform/argocd/self/values.yaml \
  --wait
```

**2.5 Point ArgoCD at the test branch**

⚠️ A repository secret has no functional `targetRevision` field — revision is
set per-Application. And every root Application / ApplicationSet in
`platform/argocd/root/` hardcodes `targetRevision: main`, so a test cluster
bootstrapped from those manifests renders everything (including
`cluster-values.yaml`) from **main**, not from the test branch. To use the
full GitOps path on the test cluster you must rewrite the revision when
applying the root manifests:

```bash
# Register the repo (credentials only — no revision here):
kubectl -n argocd create secret generic cluster-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/salishseawolf/k3s-service-cluster.git \
  --dry-run=client -o yaml | kubectl label -f - --local \
  argocd.argoproj.io/secret-type=repository | kubectl apply -f -

# Apply root apps with the revision rewritten to the test branch:
grep -rl 'targetRevision: main' platform/argocd/root/ | while read f; do
  sed 's/targetRevision: main/targetRevision: test-full-cluster-restore/' "$f"
done | kubectl apply -f -
```

**Alternative — manual deploy without ArgoCD (simpler, more controlled):**
Instead of deploying full ArgoCD with the gitops pipeline, manually deploy
only the backup/restore operators:
```bash
# hcloud-ccm and hcloud-csi are already installed by the Ansible bootstrap
# (same roles as prod) — verify before proceeding, since every PVC stays
# Pending without a working CSI driver:
kubectl -n kube-system get pods | grep -E "hcloud|csi"
kubectl get storageclass hcloud-volumes

# Install CNPG operator
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.1.yaml

# Install Velero (note: plugin image name is lowercase)
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket k3s-service-cluster \
  --prefix velero/ \
  --backup-location-config region=us-west-004,s3ForcePathStyle=true,s3Url=https://s3.us-west-004.backblazeb2.com \
  --secret-file <(echo "[default]
aws_access_key_id=<b2-key-id>
aws_secret_access_key=<b2-key>") \
  --use-node-agent \
  --uploader-type kopia \
  --wait
```

This is simpler because you skip the entire ArgoCD → wave → ApplicationSet
cascade and just run the restore directly. Recommended for a first test.

### Phase 3 — Restore from backups (20 min)

**3.1 Restore CNPG database**
```bash
# Create the backup secret that CNPG Operator needs
kubectl -n database create secret generic cnpg-backup-secret \
  --from-literal=s3_key_id=<b2-key-id> \
  --from-literal=s3_application_key=<b2-key>

# Create the ObjectStore
cat <<EOF | kubectl apply -f -
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
EOF

# Create the recovery cluster
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: main-db
  namespace: database
spec:
  instances: 3   # mirrors prod; drop to 1 to speed up recovery if desired
  imageName: ghcr.io/cloudnative-pg/postgresql:17.4
  storage:
    size: 20Gi
    storageClass: hcloud-volumes
  bootstrap:
    recovery:
      source: cnpg-b2-store
      recoveryType: latest
  managed:
    roles: []
EOF

# Wait for recovery to complete (can take 10-20 min for 20Gi)
kubectl -n database wait --for=condition=Ready cluster/main-db --timeout=1800s

# Verify databases
kubectl -n database exec main-db-1 -c postgres -- psql -U postgres -c "\l"
# Expected: authentik, gitea, homarr, paperless, seaweedfs_filer, gatus
```

**3.2 Restore Velero PVC data**

⚠️ **Restore data, not manifests.** The Velero backup contains production's
*manifests* — IngressRoutes, ConfigMaps, Authentik blueprints — all bearing
`salishseawolf.com`. Restoring the whole backup reintroduces the prod domain
regardless of the test branch's `cluster-values.yaml` patch, and (if ArgoCD is
running) selfHeal/prune will fight the restored objects. The split is:
**Velero restores PVs/PVCs (data); all config comes from Git on the test
branch (test domain).**

```bash
# List available backups
velero get backups

# Restore ONLY volume data from the latest backup, excluding CNPG namespaces
# (database is restored via barman-cloud in 3.1)
LATEST=$(velero get backups -o json | jq -r '.items[0].metadata.name')
velero restore create --from-backup "$LATEST" \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --exclude-namespaces database,cnpg-system \
  --wait

# Everything else (Deployments, IngressRoutes, ConfigMaps, blueprints) is
# deployed from the test branch in Phase 4 and binds to the restored PVCs
# by name.
```

### Phase 4 — Bring up applications (15 min)

**4.1 Install cert-manager (needed for TLS)**
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml
```

**4.2 Create minimal services for Authentik to boot**

Authentik needs: PostgreSQL (restored), Redis (deploy fresh — Redis is
ephemeral), and the blueprints ConfigMap.

```bash
# Deploy Redis (state is ephemeral, no restore needed)
helm upgrade --install redis oci://registry-1.docker.io/bitnamicharts/redis \
  --namespace redis --create-namespace \
  --set auth.password=<from-1password> \
  --wait

# Create Authentik namespace and secrets from 1Password
kubectl create namespace identity

# Copy the Authentik secrets from the 1Password Operator CR approach, or
# manually create secrets:
kubectl -n identity create secret generic authentik-secrets \
  --from-literal=secret_key=$(op read "op://K3s Service Cluster/Authentik Deployment Secrets/secret_key") \
  --from-literal=db_password=$(op read "op://K3s Service Cluster/Authentik Deployment Secrets/db_password") \
  --from-literal=bootstrap_email=$(op read "op://K3s Service Cluster/Authentik Deployment Secrets/bootstrap_email") \
  --from-literal=bootstrap_password=$(op read "op://K3s Service Cluster/Authentik Deployment Secrets/bootstrap_password")
```

**4.3 Deploy Authentik**
```bash
helm upgrade --install identity authentik/authentik \
  --namespace identity \
  --set authentik.postgresql.host=main-db-rw.database.svc.cluster.local \
  --set authentik.postgresql.name=authentik \
  --set authentik.postgresql.user=authentik \
  --set authentik.redis.host=redis-master.redis.svc.cluster.local \
  --set authentik.email.host=smtp.resend.com \
  --set authentik.email.port=465 \
  --set authentik.email.use_ssl=true \
  --set authentik.email.use_tls=false \
  --set postgresql.enabled=false \
  --set redis.enabled=false \
  --set server.ingress.enabled=false \
  --set "global.env[0].name=AUTHENTIK_HOST" \
  --set "global.env[0].value=auth.salishseawolf.bid" \
  --set "global.env[1].name=AUTHENTIK_SECRET_KEY" \
  --set "global.env[1].valueFrom.secretKeyRef.name=authentik-secrets" \
  --set "global.env[1].valueFrom.secretKeyRef.key=secret_key" \
  --set "global.env[2].name=AUTHENTIK_POSTGRESQL__PASSWORD" \
  --set "global.env[2].valueFrom.secretKeyRef.name=authentik-secrets" \
  --set "global.env[2].valueFrom.secretKeyRef.key=db_password" \
  --set "global.env[3].name=AUTHENTIK_BOOTSTRAP_EMAIL" \
  --set "global.env[3].valueFrom.secretKeyRef.name=authentik-secrets" \
  --set "global.env[3].valueFrom.secretKeyRef.key=bootstrap_email" \
  --set "global.env[4].name=AUTHENTIK_BOOTSTRAP_PASSWORD" \
  --set "global.env[4].valueFrom.secretKeyRef.name=authentik-secrets" \
  --set "global.env[4].valueFrom.secretKeyRef.key=bootstrap_password" \
  --wait
```

**4.4 Deploy Traefik IngressRoute for Authentik**
```yaml
# Create a simple IngressRoute for Authentik
cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: authentik
  namespace: identity
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(\`auth.salishseawolf.bid\`)
      services:
        - name: identity-authentik-server
          port: 80
  tls:
    secretName: authentik-tls
EOF
```

**4.5 Verify Authentik login**
```bash
# Get the bootstrap credentials
echo "Admin user: akadmin"
echo "Password: $(op read 'op://K3s Service Cluster/Authentik Deployment Secrets/bootstrap_password')"

# Open https://auth.salishseawolf.bid/if/flow/initial-setup/
# Log in with akadmin / <password>
```

**4.6 Patch OIDC providers in Authentik**
Through the Admin UI or `ak` CLI, update each OAuth2/Proxy provider's
redirect URIs to use `salishseawolf.bid` instead of `salishseawolf.com`.

**4.7 Deploy remaining apps incrementally**
At this point, deploy apps one by one to verify each restores correctly:

1. **Gitea** — verify repos and OIDC login
2. **Paperless** — verify documents are searchable
3. **Homarr** — verify dashboard loads
4. **Gatus** — verify health checks
5. **SeaweedFS** — verify filer and volumes mount
6. **Copyparty** — verify file shares

For each app, deploy it from the test branch (which has the domain already
patched in `cluster-values.yaml`) using `helm template` + `kubectl apply`, or
let ArgoCD handle it if you chose the full ArgoCD approach.

### Phase 5 — Validation (10 min)

- [ ] All 3 test nodes Ready: `kubectl get nodes` (k3s-test-node-01..03)
- [ ] CNPG cluster healthy: `kubectl -n database get cluster main-db`
- [ ] All 6 databases present: `psql -U postgres -c "\l"`
- [ ] Velero PVCs restored: `kubectl get pvc --all-namespaces | grep -v database`
- [ ] Authentik login works at `auth.salishseawolf.bid`
- [ ] Gitea login works via Authentik OIDC at `gitea.salishseawolf.bid`
- [ ] Paperless documents searchable
- [ ] Homarr dashboard loads with widgets
- [ ] SeaweedFS filer accessible
- [ ] No unexpected connections to production (on each test node:
  `ss -tnp | grep 192.168` should be empty)
- [ ] Production cluster unchanged: `kubectl --kubeconfig <prod-kubeconfig> get nodes` all Ready

### Phase 6 — Teardown (5 min)

```bash
# 1. Delete Cloudflare DNS record
CF_RECORD_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=*.salishseawolf.bid" \
  -H "Authorization: Bearer ${CF_TOKEN}" | jq -r '.result[0].id')
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${CF_RECORD_ID}" \
  -H "Authorization: Bearer ${CF_TOKEN}"

# 2. Destroy Hetzner resources (3 nodes, LB, network, subnet, firewall,
#    and any hcloud Volumes the CSI driver created)
cd tools/test-cluster/tofu
tofu destroy -auto-approve

# CSI-created Volumes are deleted with their PVCs; verify none remain:
hcloud volume list | grep -v k3s-converged || true

# 3. Revoke 1Password Service Account (if created)
# Via 1Password web UI or CLI

# 4. Delete B2 test keys (if created)
# Via Backblaze B2 Console

# 5. Clean up local artifacts
rm -f bootstrap/ansible/kubeconfig

# 6. Delete test branch (optional)
cd /workspace
git checkout main
git branch -D test-full-cluster-restore
```

---

## Summary: Safety Boundaries

| Boundary | Production | Test | Cross-talk prevented by |
|---|---|---|---|
| DNS | `*.salishseawolf.com` → prod LB | `*.salishseawolf.bid` → test node | Separate subdomain; different IPs |
| Network | `192.168.0.0/16` private net | `10.0.0.0/16` private net | Separate Hetzner networks; no peering |
| Ansible | inventory matches `project=k3s-service-cluster` | inventory matches `project=k3s-service-cluster-test` | Disjoint label selectors; `hcloud_facts` parameterized |
| Firewall | Prod firewall: admin IP + private net | Test firewall: admin IP + public 80/443 | No rules allowing cross-traffic |
| 1Password | Prod Connect+Operator (SA token) | Test Connect+Operator (dedicated SA token) | Separate Service Account; revocable |
| B2 | Read/write keys | Read-only keys (or same keys, restore is read-only) | Restore operations never write; optional read-only keys |
| CNPG | `main-db` (3 instances, HA) | `main-db` (1 instance, restore) | Separate cluster; no network connectivity |
| Redis | Production Redis | Fresh deploy (ephemeral) | Separate cluster |
| Authentik | `auth.salishseawolf.com` | `auth.salishseawolf.bid` | Different domain; separate database instance |
| Git | `main` branch on GitHub mirror | `test-full-cluster-restore` branch | Separate branch; no push back |

**Estimated total time:** 90-120 minutes
**Estimated cost:** roughly €0.03-0.05/hr all-in (3 nodes at prod's server
type + one lb11 + CSI-created Volumes) — well under €1 for a full-day drill.
Note: CX21 from the original draft was deprecated by Hetzner in Sep 2024 and
is no longer orderable; the module defaults to the same server type as
production nodes for a faithful mirror.
**Risk to production:** None — all boundaries are at the network and DNS level
