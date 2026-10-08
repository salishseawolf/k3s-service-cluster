# K3s Service Cluster

A 3-node HA K3s cluster on Hetzner Cloud, managed via OpenTofu + Ansible
(bootstrap) + Argo CD (continuous reconciliation).

## Quick start

### Prerequisites

- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) signed in
- Access to the `K3s Service Cluster` and `Hermes Agent` vaults
- The domain's Cloudflare DNS API token in the vault

### Bootstrap (one-time)

```bash
mise install
mise run setup                 # tofu init + ansible galaxy
mise run bootstrap             # tofu apply → K3s → 1Password Connect →
                               #   secret_zero → Argo CD
kubectl -n argocd get applications -w    # watch the cascade
```

### Architecture

```
infrastructure/     OpenTofu (human-run) — servers, network, LB, DNS
bootstrap/          Ansible (runs ~once) — K3s, 1Password, secret_zero, Argo
platform/           Argo CD — cert-manager, step-ca, volsync, argocd, storage
services/*/app/     Argo CD — application Helm charts
```

Argo reconciles in waves: 0 (argocd self, cnpg, cert-manager CRDs) → 10
(database, redis, cert-manager config, step-ca) → 20 (seaweedfs, identity) →
30 (seaweedfs-csi, volsync — PVC canary gate) → 40 (everything else).

## Day-to-day

- **Change anything**: PR → CI validates → merge → Argo converges
- **Add a service**: `mkdir services/<name>/app` + standard anatomy
- **Rotate a secret**: rotate in 1Password; operator re-syncs
- **Rebrand**: edit `platform/argocd/root/cluster-values.yaml` (one file)
- **Back up a new PVC**: one scoped B2 key + one 1P item per PVC (below),
  then a `ReplicationSource` (copy `services/kimai/app/templates/volsync.yaml`)

### Creating a VolSync B2 key and 1P item (per PVC)

Every backed-up PVC gets its own B2 application key, limited to its own
prefix in the `k3s-service-cluster` bucket, and its own `VolSync B2 <pvc>`
item. No key is shared, so a leaked key exposes one service's backups only.

```bash
# 1. Authorize as the account admin key (op://Personal/Backblaze: app_key_id + its key)
b2 account authorize

# 2. (Optional) see the existing VolSync keys, their prefixes and capabilities
b2 key list

# 3. Create the scoped key. Prints keyId + applicationKey ONCE: copy both now.
b2 key create --bucket k3s-service-cluster --name-prefix volsync/<ns> \
  VolSync-<pvc> deleteFiles,listBuckets,listFiles,readFiles,writeFiles

# 4. Don't leave the admin key cached in ~/.config/b2
b2 account clear
```

Capabilities mirror the existing VolSync keys (confirmed by authorizing as
`VolSync B2 paperless-media`'s key): restic reads, lists and writes its
repository, and needs `deleteFiles` for the weekly prune. `--name-prefix` is
a plain string match, so `volsync/<ns>/` (trailing slash) is the tighter
form if another namespace could share the prefix.

Then create `VolSync B2 <pvc>` in the `K3s Service Cluster` vault, with
field labels exactly as below (the operator turns labels into the Secret
keys restic reads):

| Field | Value |
|---|---|
| `RESTIC_REPOSITORY` | `s3:https://s3.us-west-004.backblazeb2.com/k3s-service-cluster/volsync/<ns>/<pvc>` |
| `RESTIC_PASSWORD` | new random value (`openssl rand -hex 32`); encrypts the repo, so losing it loses the backups |
| `AWS_ACCESS_KEY_ID` | the new `keyId` |
| `AWS_SECRET_ACCESS_KEY` | the new `applicationKey` |

## Documentation

| File | What |
|---|---|
| `docs/RUNBOOK-GITOPS.md` | GitOps operations, vault checklist, fresh deploy |
| `docs/MIGRATION.md` | Template for adding new services |
