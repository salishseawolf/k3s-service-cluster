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
`docs/MIGRATION.md` (service anatomy), `docs/RCA-2026-10-SEAWEEDFS.md`
(why app storage was node-local until 2026-10, and the storage rules below).

## Ground rules (non-negotiable)

1. **Secrets never touch git or logs.** Only `op://` references are ever
   written to disk in this repo. Never echo resolved secret values, never
   paste them into command output you report, never commit `.secrets.env*`,
   `kubeconfig`, or anything matching `.gitignore`.
2. **You do not widen the perimeter.** Know what the perimeter actually is
   (see [Perimeter](#perimeter)): the Hetzner firewall does **not** cover
   traffic through the load balancer, so for 80/443/2222 the real controls
   are Traefik (`ClientIP`/`ipAllowList`) and Authentik forward-auth. Each of
   these requires explicit human approval first: changing
   `allowed_admin_cidr` or `adminSourceRanges`, opening firewall rules, adding
   or changing an LB service in `infrastructure/tofu/main.tf`, adding a route
   without forward-auth, removing forward-auth from a route, or widening a
   `ClientIP`/`ipAllowList` source list.
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
  kimai/                     Time tracking with its own MariaDB (SAML)
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
the root and wildcard DNS records resolve to the LB IP and `api.<domain>` to
the three node IPs; `kubectl get nodes` works through the generated
kubeconfig (`https://api.<domain>:6443`); 3 Ready nodes; Argo CD is running
in `argocd`.

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
`internal` group in Authentik. Most forward-auth gates (and Kimai) admit
only that group. Flag it; do not block on it.

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
`Umami Secrets`, `Kimai Secrets`, `Kimai SAML Signing`.

### VolSync B2 credentials (one scoped key per PVC)

**Human step:** the B2 admin key lives in the human's `Personal` vault
(`op://Personal/Backblaze`), which agents cannot read. When a new PVC needs a
backup, write the `ReplicationSource` (copy
`services/kimai/app/templates/volsync.yaml`), then hand the human this
procedure and wait for the item before relying on the backup.

Every backed-up PVC gets its own B2 application key, limited to its own
prefix in the `k3s-service-cluster` bucket, and its own `VolSync B2 <pvc>`
item. Never reuse another PVC's key or item.

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

In a PSA `restricted` namespace, the `ReplicationSource` (and any restore
`ReplicationDestination`) also needs a `moverSecurityContext` with
`runAsNonRoot` and `RuntimeDefault` seccomp; see the kimai template.

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
Apps load it as a Helm value file by **relative path** from their chart
directory (one Argo source). Don't reintroduce it as a second same-repo
source with `ref: values`: Argo then fails syncs ("cannot reference a
different revision of the same repository") whenever a push lands mid-sync.
Set `domain:` and gitea `autoDiscoverUrl` there. Rebrand = one-file PR.

## Service Scaffolding

When adding a new service under `services/<name>/app/`:

- Helm chart (Chart.yaml, values.yaml, templates/)
- Namespace with PSA labels (namespace.yaml)
- NetworkPolicy (networkpolicy.yaml)
- OnePasswordItem CRs for secrets (onepassworditems.yaml)
- Workload (deployment.yaml or statefulset.yaml)
- IngressRoute (ingressroute.yaml) with the `authentik-forward-auth`
  middleware (namespace `identity`), plus a forward-auth provider and
  application for the host in `services/identity/app/templates/configmap-blueprints.yaml`
  and an entry in the embedded outpost's providers list (it is replaced, not
  merged). A route without forward-auth is a perimeter change (ground rule 2)
- Service (service.yaml)
- PVC annotations: `Prune=false,Delete=false`
- The ApplicationSet auto-discovers it by directory

## Network

- **Hetzner Cloud Firewall**: direct-to-node traffic only (admin IP + private net)
- **firewalld** on each node (public zone: SSH/HTTP/HTTPS/K8s API/Gitea SSH)
- **Kubernetes NetworkPolicies** per namespace (default-deny ingress)
- **Traefik** hostNetwork DaemonSet with authenticated forward-auth middleware
- **Authentik** as SSO/identity provider with proxy outposts

### Perimeter

Hetzner Cloud Firewalls cannot be attached to load balancers, and the LB
reaches the nodes over the private network, which the firewall allows. So
**everything the LB forwards is reachable from the whole internet**, and
access control happens behind it:

| Entry | Path | Enforced by |
|---|---|---|
| 80/443 | LB (PROXY protocol, real client IP) → Traefik | per route: Authentik forward-auth, or public by design |
| 2222 (Gitea SSH) | LB (PROXY protocol) → Traefik TCP | `gitea-ssh-allowlist` MiddlewareTCP: `adminSourceRanges` |
| 6443 (K3s API) | **not on the LB**; `api.<domain>` = one A record per node | Hetzner firewall: admin IP only |
| 22 (node SSH) | direct to nodes | Hetzner firewall: admin IP only |

Web routes, by design:

- **Public:** the personal site, Copyparty share links (`files.`, for
  people outside the org), Umami's tracking paths, and Authentik itself
  (`auth.`, the login page, rate-limited).
- **Everything else is behind forward-auth.** Apps with their own Authentik
  login (Gitea, Paperless OIDC; Kimai SAML) are gated too, so no request
  reaches their code without an Authentik session.
- **Token exceptions** bypass forward-auth only with a `ClientIP` rule:
  Gitea's git smart-HTTP, `/api` and `/v2` (`adminSourceRanges` + pod
  network `10.42.0.0/16`), and Argo CD's `/api` (`adminSourceRanges`).
  `ClientIP` sees the real client only because the LB sends PROXY protocol
  and Traefik trusts it on that entrypoint; an LB service without
  `proxyprotocol = true` makes every client look like the LB's private IP
  (`192.168.1.10`), which `adminSourceRanges` admits.
- **In-cluster clients** of `git.<domain>` (Gitea Actions' `actions/checkout`)
  resolve it to Traefik's ClusterIP via a CoreDNS rewrite
  (`services/gitea/app/templates/coredns-custom.yaml`), so they arrive from
  the pod network (the runner's egress policy allows Traefik's port 8443 on
  the nodes for this). Gatus checks gated apps on their internal Services with
  the public `Host` header instead of through Traefik.

The kubeconfig points at `https://api.<domain>:6443` with
`tls-server-name: kubernetes` (K3s fixes `--tls-san` at install; the built-in
`kubernetes` SAN avoids reinstalling). kubectl fails over across the three
A records.

## Storage

App data (including databases) lives on `seaweedfs-storage`; system storage
(CNPG, step-ca, SeaweedFS's own disk) on `hcloud-volumes`. **Exception:**
monitoring never depends on the storage it watches, so Loki uses a Hetzner
volume and Prometheus and Alertmanager use capped `emptyDir`s (history resets
on pod restart, by choice). Until 2026-10 every
`seaweedfs-storage` PVC was silently node-local disk
(`docs/RCA-2026-10-SEAWEEDFS.md`). Rules that came out of it:

- **Never set a bare `WEED_*` parent-key env var** on `weed` (`WEED_MASTER`,
  `WEED_FILER`, ...). viper lets it shadow every nested key; `WEED_MASTER`
  disabled volume growth for three months. Full-key vars
  (`WEED_MASTER_VOLUME_GROWTH_COPY_1`) are fine.
- **Verify a mount is real:** a pod's volume must show `fuse.seaweedfs` in
  `/proc/mounts`, not `ext4`. The wave-30 canary enforces this; keep it.
- **SeaweedFS advertises `seaweedfs-headless.seaweedfs.svc.cluster.local`**,
  never its pod IP; mount clients cache the address and hang on reads after a
  restart otherwise.
- **One `weed server` pod holds all app storage.** Restarting or evicting it is
  an outage for every app (mounts reconnect afterwards). Its 1 CPU / 1 GiB
  request fits only where a node has room; watch that node's disk and memory
  and the `SeaweedFS*` alerts.
- **FUSE client memory is not the app's.** Each volume's `weed mount` client
  runs in the node's `seaweedfs-mount` pod, outside the app's limits, and
  buffers writes in RAM. Prometheus's grew to 4.2 GB and OOM-starved node-02
  (2026-10-13). Don't put heavy writers (TSDBs, busy databases) on SeaweedFS
  without capping the mount side.
- **Stopping an app to work on its volume:** render the chart first (some, like
  Loki, ignore `replicas: 0`), and remember VolSync movers also hold the
  volume. A stale mount client only goes away once no pod on that node uses
  the volume.
- **On nodes, move files by their real path.** `mv` across mount points (a bind
  mount of `/` included) copies, and filled node-02 once.
- Restic locks left by killed movers: `mise run //services/<svc>:backup:locks`
  and `...:backup:<repo>:unlock [--all]`.

## Security

- All secrets in 1Password, never in git
- Prune=false on all PVCs (data survives Argo pruning)
- PSA: restricted cluster-wide, baseline/privileged per-namespace where needed
- etcd encryption at rest (AES-CBC)
- CNPG barman-cloud plugin enabled; daily backups to Backblaze B2 with 30d retention
- VolSync restic backups of app PVCs to Backblaze B2
- Alert email is opt-in: Alertmanager mails only alerts labelled
  `notify: email` (to admin@salishseawolf.com, via Resend); everything else
  goes to the null receiver. A service opts in with a PrometheusRule carrying
  `release: monitoring` (see services/kimai/app/templates/prometheusrule.yaml)
