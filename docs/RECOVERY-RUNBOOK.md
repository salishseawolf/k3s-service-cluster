# Disaster Recovery Runbook

## Overview
Complete procedure for restoring the K3s Service Cluster from scratch after a
total infrastructure loss (all nodes destroyed). Infrastructure-as-code means
the cluster configuration is fully recoverable from git; the challenge is
restoring persistent data from Backblaze B2 backups.

### Backup inventory
| Data | Location | Backup Method | RPO |
|---|---|---|---|
| CNPG PostgreSQL (6 databases) | `s3://k3s-service-cluster/cnpg/` | barman-cloud (daily + WAL) | ~1h |
| SeaweedFS filer metadata | CNPG `seaweedfs_filer` DB | CNPG barman-cloud | ~1h |
| SeaweedFS volume data | `s3://k3s-service-cluster/seaweedfs/` | CronJob (daily S3 sync) | 24h |
| PVC data (Gitea, Paperless, Homarr, etc.) | B2 velero/ prefix | Velero kopia (daily) | 24h |
| Secrets | 1Password vault | Operator re-creates from vault | N/A (git) |
| Cluster config (CRDs, Argo, etc.) | Git | Argo CD re-deploys | N/A (git) |
| Certificates | N/A | cert-manager auto-renew | N/A (git) |
| Redis | N/A | Ephemeral (no backup needed) | N/A |

## Recovery Procedure

### Phase 0 — Bootstrap the cluster
```bash
# From a machine with git, OpenTofu, and 1Password CLI access:
export OP_SERVICE_ACCOUNT_TOKEN="op://...SA token..."
ssh-agent bash -c 'ssh-add <(op read "op://K3s Service Cluster/K3s Service Cluster SSH Key/private key")'
cd k3s-service-cluster
mise run bootstrap
```
This creates the Hetzner servers, installs K3s, deploys 1Password Connect,
secret_zero, and Argo CD. Argo immediately begins reconciling all 19 apps
from git. **Do not let Argo finish** — CNPG will deploy a new empty cluster
which must be overwritten with the backup before apps consume it.

### Phase 1 — Stop Argo from pruning CNPG data
Before Argo's cascade deploys the database (wave 10), pause the database app:
```bash
argocd app pause database
```
Or delete the database Application if necessary:
```bash
kubectl -n argocd delete application database
```

### Phase 2 — Restore CNPG from barman-cloud backup
The CNPG operator can bootstrap a Cluster from an existing backup. Create a
temporary recovery Cluster manifest (`restore-db.yaml`):
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: main-db-restore
  namespace: database
spec:
  instances: 3
  storage:
    size: 20Gi
    storageClass: hcloud-volumes
  bootstrap:
    recovery:
      source: b2-backup
      recoveryType: latest  # or point in time: '2026-07-10T03:00:00Z'
  externalClusters:
    - name: b2-backup
      barmanObjectStore:
        destinationPath: s3://k3s-service-cluster/cnpg/
        endpointURL: https://s3.us-west-004.backblazeb2.com
        s3Credentials:
          accessKeyId:
            name: cnpg-backup-secret
            key: s3_key_id
          secretAccessKey:
            name: cnpg-backup-secret
            key: s3_application_key
        wal:
          maxParallel: 8
  managed:
    roles: []  # roles will be restored from backup
```
Apply and wait for recovery:
```bash
kubectl apply -f restore-db.yaml
kubectl -n database wait --for=condition=Ready cluster/main-db-restore --timeout=600s
```

Verify all 6 databases are present:
```bash
kubectl -n database exec main-db-restore-1 -c postgres -- psql -U postgres -c "\l"
```

Once verified, delete the empty cluster and create a new one with the
correct name that recovers from the backup:
```bash
kubectl -n database delete cluster main-db

# Create a new Cluster CR with bootstrap.recovery pointing at the backup
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: main-db
  namespace: database
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:17.4
  storage:
    size: 20Gi
    storageClass: hcloud-volumes
  bootstrap:
    recovery:
      source: b2-backup
      recoveryType: latest
  externalClusters:
    - name: b2-backup
      barmanObjectStore:
        destinationPath: s3://k3s-service-cluster/cnpg/
        endpointURL: https://s3.us-west-004.backblazeb2.com
        s3Credentials:
          accessKeyId:
            name: cnpg-backup-secret
            key: s3_key_id
          secretAccessKey:
            name: cnpg-backup-secret
            key: s3_application_key
        wal:
          maxParallel: 8
EOF
```

### Phase 3 — Restore Velero backups
Once CNPG is restored, SeaweedFS will start with its metadata intact. Then
restore PVC data from Velero:
```bash
# List available backups
velero get backups

# Find the latest successful backup and restore
velero restore create --from-backup <latest-backup-name> --wait

# Exclude CNPG namespaces to avoid overwriting the just-restored databases
velero restore create --from-backup <latest-backup-name> \
  --exclude-namespaces database,cnpg-system --wait
```

### Phase 4 — Restore SeaweedFS volume data
The SeaweedFS volume data is backed up via CronJob to B2. Restore manually:
```bash
# Identify the SeaweedFS volume pod
kubectl -n seaweedfs get pods -l app.kubernetes.io/name=seaweedfs

# Exec into the backup-tools sidecar and sync from B2
kubectl -n seaweedfs exec deployment/seaweedfs -c backup-tools -- \
  aws s3 sync s3://k3s-service-cluster/seaweedfs/ /data/ \
  --endpoint-url https://s3.us-west-004.backblazeb2.com
```

### Phase 5 — Re-enable Argo CD management
```bash
argocd app sync root  # re-creates the database app from git
argocd app unpause database  # if paused
```

Argo will reconcile all apps. Expect temporary health degradation as pods
catch up. Monitor:
```bash
kubectl -n argocd get applications -w
```

### Validation
1. All 19 apps reach Synced/Healthy
2. Authentik login works at `https://auth.<domain>/`
3. Gitea at `https://git.<domain>/` — repos, issues, PRs intact
4. Paperless at `https://paperless.<domain>/` — documents searchable
5. Homarr at `https://dashboard.<domain>/` — widgets load
6. Copyparty at `https://files.<domain>/` — shares accessible
7. Gatus reports all-green for all endpoints

## Appendix: Restore testing drill
**Never trust a backup that hasn't been restored.** Perform a drill at least
monthly:
1. Create a scratch namespace
2. Restore CNPG into it (Point-in-Time or latest)
3. Verify database integrity (row counts, latest records)
4. Validate a specific known-good record exists
5. Tear down scratch namespace

## Appendix: Key credentials
| Item | 1Password Vault |
|---|---|
| B2 CNPG backup | `BackBlaze CNPG B2 Bucket` |
| B2 Velero backup | `BackBlaze Velero B2 Bucket` |
| B2 SeaweedFS backup | `SeaweedFS Secrets` |
| Argo CD admin login | `argocd-initial-admin-secret` (K8s secret) |
| Authentik admin login | `akadmin` (bootstrap user) |
| SSH key | `K3s Service Cluster SSH Key` |
| Service account token | `/root/.hermes/.env` |
