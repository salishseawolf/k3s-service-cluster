# AGENT.md

Guidance for AI agents working in this repository (Claude Code loads it via
`CLAUDE.md`).

## Agent Behavior

- **Do NOT pivot or make changes without explicit user approval.** Questions
  and observations are not change requests. Treat them as discussion unless
  the user explicitly says "yes" or "do it". If uncertain, ask before acting.

## Project Overview

This is a 3-node HA K3s cluster for Salish Sea Wolf LLC on Hetzner Cloud
(hel1, salishseawolf.com). Provisioned with OpenTofu, bootstrapped with
Ansible, and continuously reconciled by Argo CD. Admin IP is 73.97.54.81/32.

Authoritative references in-repo: `docs/RUNBOOK-GITOPS.md` (operations, vault
checklist, fresh deploy), `docs/RECOVERY-RUNBOOK.md` (disaster recovery),
`docs/MIGRATION.md` (service anatomy), `docs/PLAN.md` (rationale).

## Ground rules (non-negotiable)

1. **Secrets never touch git or logs.** Only `op://` references are ever
   written to disk in this repo. Never echo resolved secret values, never
   paste them into command output you report, never commit `.secrets.env*`,
   `kubeconfig`, or anything matching `.gitignore`.
2. **You do not widen the perimeter.** Ports 80/443 stay admin-CIDR-only.
   Changing `allowed_admin_cidr`, opening firewall rules, or any change to
   `infrastructure/tofu/main.tf` firewall blocks requires explicit human
   approval first.
3. **Destructive operations require confirmation.** `tofu destroy`,
   `mise run destroy`, `helm uninstall`, `kubectl delete ns`, deleting
   volumes/snapshots/backups: present the exact command and wait for a human
   yes.
4. **Idempotent retries only.** `mise run bootstrap` and
   `mise run //bootstrap/ansible:deploy` are safe to re-run. If a task fails
   twice for the same reason, stop and report. Do not improvise workarounds,
   and do not edit code to route around a failure.
5. **Git is the deploy mechanism.** Do not `kubectl apply` or `helm install`
   anything Argo owns; Argo will revert it or fight it. Change the repo
   instead.

## Repository Structure

```
infrastructure/tofu/        OpenTofu: Hetzner servers, network, LB, firewall,
                            Cloudflare DNS (A + wildcard records)
bootstrap/                  Ansible (one-time per cluster life)
  ansible/                   K3s install, 1Password Connect+Operator,
                             secret_zero (typed secrets), Argo CD install
  node-tooling/              Developer tooling on cluster nodes
platform/                   Argo CD: cluster-scoped or shared services
  argocd/root/               Root apps, projects, ApplicationSet, cluster-values.yaml
  argocd/self/               Argo manages its own chart
  cert-manager/              config + CRD charts
  step-ca/                   config + CRD charts
  monitoring-crd/            Prometheus operator CRDs (workloads in services/monitoring)
  volsync/                   Umbrella chart: VolSync operator (restic movers → B2)
  storage/                   seaweedfs + seaweedfs-csi charts
services/*/app/             Argo CD: application Helm charts
  database/                  CNPG cluster with managed roles for all app principals
  redis/                     Redis with requirepass
  identity/                  Authentik umbrella chart + all blueprints
  gitea/                     Gitea with SSH, OIDC, actions
  gitea-actions/             Runner deployment
  copyparty/                 File sharing
  homarr/                    Dashboard (edge-gated forward-auth)
  paperless/                 Document management (OIDC)
  gatus/                     Health monitoring (edge-gated)
  umami/                     Privacy-first web analytics
  monitoring/                Prometheus, Loki, Alloy, Grafana
  personal-site/             Static personal site
  renovate/                  Renovate CronJob (dependency update PRs)
scripts/                    check-rendered-charts.sh (used by mise check + CI)
docs/                       Runbooks, plans, todo
```

## Deployment Flow

There is no `deploy` command. Merged == deployed (Argo reconciles). GitHub
(`https://github.com/salishseawolf/k3s-service-cluster.git`) is the repo of
record; Argo pulls from it, not from in-cluster Gitea.

```
mise run setup        tofu init + ansible galaxy collections
mise run bootstrap    tofu apply → K3s → 1Password Connect → secret_zero → Argo CD
mise run check        yamllint + tofu validate + ansible-lint + helm template all
mise run destroy      tofu destroy
```

Argo waves:

| Wave | Apps | Gate |
|---|---|---|
| 0 | argocd (self), cert-manager-crd, cnpg-operator, plugin-barman-cloud, monitoring-crd | operator health |
| 10 | cert-manager-config, step-ca-crd, step-ca-config, database, redis | CNPG cluster healthy |
| 20 | seaweedfs, identity | filer + authentik up |
| 30 | seaweedfs-csi, volsync | **PVC canary Job must bind+mount a real volume** |
| 40 | services ApplicationSet (everything else under `services/*/app`) | none |

If wave 30's canary fails, wave 40 never starts.

## Fresh deployment procedure (gated)

Use this when standing up a cluster from a clean checkout (also the
disaster-recovery path; for data restore see `docs/RECOVERY-RUNBOOK.md`).
Verify after every stage; stop and report when a gate fails or a human
decision is required.

### Stage 0: Environment

```bash
mise trust && mise install
op whoami || eval $(op signin)      # stop and ask the human if signin fails
# Service-account agents: source OP_SERVICE_ACCOUNT_TOKEN from /root/.hermes/.env
# instead of signing in interactively.
```

Write the agent secrets file described under [Secrets](#secrets).

**Gate 0:** these resolve without error (check existence, do not print
values):

```bash
op read "op://Hermes Agent/K3s Service Cluster Hermes Hetzner/token" > /dev/null
op read "op://Hermes Agent/K3s Service Cluster Cloudflare DNS Challenge/token" > /dev/null
op read "op://K3s Service Cluster/Admin Allow List/IPV4" > /dev/null
op read "op://K3s Service Cluster/Redis Password/password" > /dev/null
op read "op://K3s Service Cluster/Cloudflare DNS Challenge/domain" > /dev/null
```

Missing items: stop and report which item is absent
(`docs/RUNBOOK-GITOPS.md` §0 lists every required vault item and field).
Also verify the Redis password is alphanumeric
(`op read ... | grep -qE '^[A-Za-z0-9]+$'`, check the exit code only).

### Stage 1: Validate before touching the cloud

```bash
mise run setup
mise run check
```

**Gate 1:** `check` exits 0. Temporary kube-linter exceptions are marked
`TODO(lint)` and already pass; any failure stops you.

### Stage 2: Infrastructure plan

```bash
mise run //infrastructure/tofu:plan
```

**Gate 2:** on a fresh deploy the plan shows creates only. Any destroy or
unexpected change: stop and show the human.

### Stage 3: Bootstrap

```bash
mise run bootstrap
kubectl get nodes                        # 3 nodes Ready
```

**Gate 3:** 3 servers, LB, network and firewall exist
(`op run -- hcloud server list`, `op run -- hcloud load-balancer list`);
DNS A records resolve to the LB IP; 3 Ready nodes; Argo CD is running in
`argocd`.

### Stage 4: Watch the Argo cascade

```bash
kubectl -n argocd get applications -w
```

**Gate 4:** each wave reaches `Synced/Healthy` before the next starts.
In particular: the wildcard Certificate reaches `Ready=True`
(`kubectl get certificate -A`, DNS-01 can take a few minutes); the CNPG
cluster is healthy; the wave 30 PVC canary succeeds. Then every
`services/*` Application is `Synced/Healthy` and gatus reports green (or
explained amber) across its endpoint groups.

**Human handoff:** after identity is up, a human must add their user to the
`internal` group in Authentik. Forward-auth denies everyone else. Flag it;
do not block on it.

### Stage 5: Final report

Stage-by-stage pass/fail with the verification evidence (command outputs,
secrets redacted), the gatus dashboard state, the list of human actions
still pending, and any deviations you made with justification.

### Failure protocol

On any gate failure: capture `kubectl describe` + the last 100 log lines of
the failing component into your report (scrub anything secret-shaped),
attempt ONE idempotent re-run of the failing task, then stop and report.
Never proceed past a failed gate. Never delete resources to "reset" without
confirmation. If the cluster ends in a partial state, say so plainly. A
partial deploy with an honest report is a success condition; a "green"
report over a broken cluster is the only unacceptable outcome.

## Secrets

All secrets are in 1Password, resolved at runtime via `op run` or projected
into the cluster by the 1Password Operator (OnePasswordItem CRs).

### Agent secrets file

`/tmp/.secrets.env.agent` is loaded by root `mise.toml` via `_.file`:

```bash
umask 177
cat > /tmp/.secrets.env.agent <<'EOF'
# Agent personal/deployment secrets: op:// references only, resolved by `op run`.
HCLOUD_TOKEN=op://Hermes Agent/K3s Service Cluster Hermes Hetzner/token
TF_VAR_cloudflare_api_token=op://Hermes Agent/K3s Service Cluster Cloudflare DNS Challenge/token
EOF
chmod 600 /tmp/.secrets.env.agent
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
`Paperless Secrets`, `VolSync B2 <pvc>` (one item per backed-up PVC, restic
env fields), `Authentik Deployment Secrets`, `Cloudflare DNS Challenge`,
`Redis Password`, `StepCA Secrets`, `SeaweedFS Secrets`, `Gatus Secrets`,
`Umami Secrets`.

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

Single source of truth: `platform/argocd/root/cluster-values.yaml`.
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

- **Hetzner Cloud Firewall**: external traffic (admin IP + private net)
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
- VolSync restic backups of app PVCs to Backblaze B2
