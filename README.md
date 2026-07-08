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
platform/           Argo CD — cert-manager, step-ca, velero, argocd, storage
services/*/app/     Argo CD — application Helm charts
```

Argo reconciles in waves: 0 (argocd self, cnpg, cert-manager CRDs) → 10
(database, redis, cert-manager config, step-ca) → 20 (seaweedfs, identity) →
30 (seaweedfs-csi, velero — PVC canary gate) → 40 (everything else).

## Day-to-day

- **Change anything**: PR → CI validates → merge → Argo converges
- **Add a service**: `mkdir services/<name>/app` + standard anatomy
- **Rotate a secret**: rotate in 1Password; operator re-syncs
- **Rebrand**: edit `platform/argocd/root/cluster-values.yaml` (one file)

## Documentation

| File | What |
|---|---|
| `docs/RUNBOOK-GITOPS.md` | GitOps operations, vault checklist, fresh deploy |
| `docs/MIGRATION.md` | Template for adding new services |
