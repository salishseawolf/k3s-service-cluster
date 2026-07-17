# CLAUDE.md

File provides guidance to AI agents when working with this repository.

## Agent Behavior

- **Do NOT pivot or make changes without explicit user approval.** Questions and observations are not change requests — treat them as discussion unless the user explicitly says "yes" or "do it". If uncertain, ask before acting.

## Project Overview

This is a 3-node HA K3s cluster on Hetzner Cloud (hel1, salishseawolf.com).
Provisioned with OpenTofu, bootstrapped with Ansible, and continuously
reconciled by Argo CD. Admin IP is 73.97.54.81/32.

## Repository Structure

```
infrastructure/tofu/        OpenTofu — Hetzner servers, network, LB, firewall,
                            Cloudflare DNS (A + wildcard records)
bootstrap/                  Ansible (one-time per cluster life)
  ansible/                   K3s install, 1Password Connect+Operator,
                             secret_zero (typed secrets), Argo CD install
  node-tooling/              Developer tooling on cluster nodes
platform/                   Argo CD — cluster-scoped or shared services
  argocd/root/               Root apps, projects, ApplicationSet, cluster-values.yaml
  argocd/self/               Argo manages its own chart
  cert-manager/              config + CRD charts
  step-ca/                   config + CRD charts
  volsync/                   Umbrella chart — VolSync operator (restic movers → B2)
  storage/                   seaweedfs + seaweedfs-csi charts
services/*/app/             Argo CD — application Helm charts
  database/                  CNPG cluster with managed roles for all app principals
  redis/                     Redis with requirepass
  identity/                  Authentik umbrella chart + all 13 blueprints
  gitea/                     Gitea with SSH, OIDC, actions
  gitea-actions/             Runner deployment
  copyparty/                 File sharing
  homarr/                    Dashboard (edge-gated forward-auth)
  paperless/                 Document management (OIDC)
  gatus/                     Health monitoring (edge-gated)
  developer-tooling/         (under bootstrap/
```

## Deployment Flow

There is no `deploy` command. Merged == deployed (Argo reconciles).

```
mise run setup        tofu init + ansible galaxy collections
mise run bootstrap    tofu apply → K3s → 1Password Connect → secret_zero → Argo CD
mise run check        yamllint + tofu validate + ansible-lint + helm template all
mise run destroy      tofu destroy
```

Argo waves: 0 (argocd self, cert-manager-crd, cnpg-operator) → 10
(cert-manager-config, step-ca, database, redis) → 20 (seaweedfs, identity) →
30 (seaweedfs-csi, volsync — PVC canary gate) → 40 (services ApplicationSet).

If wave 30's canary fails, wave 40 never starts.

## Secrets

All secrets are in 1Password, resolved at runtime via `op run` or projected
into the cluster by the 1Password Operator (OnePasswordItem CRs).

### Agent secrets file

`/tmp/.secrets.env.agent` is loaded by root `mise.toml` via `_.file`:
```env
HCLOUD_TOKEN=op://Hermes Agent/K3s Service Cluster Hermes Hetzner/token
TF_VAR_cloudflare_api_token=op://Hermes Agent/K3s Service Cluster Cloudflare DNS Challenge/token
```

### Root env vars (mise.toml)
Reference the shared `K3s Service Cluster` vault:
```toml
TF_VAR_cloudflare_zone_id = "op://K3s Service Cluster/Cloudflare DNS Challenge/zone_id"
TF_VAR_domain = "op://K3s Service Cluster/Cloudflare DNS Challenge/domain"
```

### Vault items reference (see docs/RUNBOOK-GITOPS.md for full table)

Key items: `ArgoCD Github Token`, `Gitea Secrets` (10 fields including
oidc_key/secret, actions_token, admin_user/password), `Homarr Secrets`,
`Paperless Secrets`, `VolSync B2 <pvc>` (one item per backed-up PVC, restic env fields),
`Authentik Deployment Secrets`, `Cloudflare DNS Challenge`, `Redis Password`,
`StepCA Secrets`, `SeaweedFS Secrets`, `Gatus Secrets`.

## Essential Commands

```bash
mise run setup                 # install deps + init
mise run bootstrap             # full cluster bootstrap
mise run check                 # lint everything
mise run destroy               # tear down cloud resources
mise run //infrastructure/tofu:plan   # tofu plan only
mise run //bootstrap/ansible:deploy   # re-run K3s/Argo bootstrap
kubectl -n argocd get applications -w # watch Argo reconcile
```

## Domain

Single source of truth: `platform/argocd/root/cluster-values.yaml`
Set `domain:` and gitea `autoDiscoverUrl` there. Rebrand = one-file PR.

## Service Scaffolding

When adding a new service under `services/<name>/app/`:

- Helm chart (Chart.yaml, values.yaml, templates/)
- Namespace with PSA labels (namespace.yaml)
- NetworkPolicy (networkpolicy.yaml)
- OnePasswordItem CRs for secrets (onepassworditems.yaml)
- Workload (deployment.yaml or statefulset.yaml)
- IngressRoute (ingressroute.yaml with forward-auth if edge-gated)
- Service (service.yaml)
- PVC annotations: `Prune=false,Delete=false`
- The ApplicationSet auto-discovers it by directory

## Network

- **Hetzner Cloud Firewall** external traffic (admin IP + private net)
- **firewalld** on each node (public zone: SSH/HTTP/HTTPS/K8s API/Gitea SSH)
- **Kubernetes NetworkPolicies** per namespace (default-deny ingress)
- **Traefik** hostNetwork DaemonSet with authenticated forward-auth middleware
- **Authentik** as SSO/identity provider with proxy outposts

## Security

- All secrets in 1Password, never in git
- Prune=false on all PVCs (data survives Argo pruning)
- PSA: restricted cluster-wide, baseline/privileged per-namespace where needed
- etcd encryption at rest (AES-CBC)
- CNPG barman-cloud plugin enabled; daily backups to Backblaze B2 with 30d retention
