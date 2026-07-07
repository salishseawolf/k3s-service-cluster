# AGENT.md — Full Infrastructure Deployment

You are the deployment agent for the Salish Sea Wolf LLC K3s Service Cluster.
Your mission: take this repository from a clean checkout to a fully deployed,
verified cluster, following the staged sequence below. You execute; you verify
after every stage; you stop and report when a gate fails or a human decision
is required. Authoritative references in-repo: `docs/RUNBOOK.md` (live-cluster
procedure), `docs/PLAN.md` (rationale), `docs/MIGRATION.md` (GitOps recipes).
Where this file and those disagree, this file wins for ordering, RUNBOOK.md
wins for verification detail.

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
   `helm uninstall`, `kubectl delete ns`, deleting volumes/snapshots/backups:
   present the exact command and wait for a human yes. Exception: the
   ephemeral `netpol-canary` namespace you create yourself.
4. **Idempotent retries only.** Every `mise run ...:deploy` task is safe to
   re-run. If a task fails twice for the same reason, stop and report —
   do not improvise workarounds, do not edit code to route around a failure.
5. **One stage at a time.** Never run the monolithic `mise run deploy`
   blindly; use the staged sequence below so each gate is actually checked.

## Stage 0 — Environment bootstrap

```bash
cd <repo-root>
mise trust && mise install
op whoami || eval $(op signin)      # stop and ask the human if signin fails
# Service-account agents: source OP_SERVICE_ACCOUNT_TOKEN from /root/.hermes/.env
# instead of signing in interactively.
```

Configure your two personal secrets in **`/tmp/.secrets.env.agent`** — the root
`mise.toml` already loads this file via `env._.file`, so nothing else needs
wiring:

```bash
umask 177
cat > /tmp/.secrets.env.agent <<'EOF'
# Agent personal/deployment secrets — op:// references only, resolved by `op run`.
HCLOUD_TOKEN=*** Agent/K3s Service Cluster Hermes Hetzner/token
TF_VAR_cloudflare_api_token=*** Agent/K3s Service Cluster Cloudflare DNS Challenge/add more/token
EOF
chmod 600 /tmp/.secrets.env.agent
```

**Gate 0:** all of the following resolve without error (check existence, do
not print values):

```bash
op read "op://Hermes Agent/K3s Service Cluster Hermes Hetzner/token" > /dev/null
op read "op://Hermes Agent/K3s Service Cluster Cloudflare DNS Challenge/add more/token" > /dev/null
op read "op://K3s Service Cluster/Admin Allow List/IPV4" > /dev/null
op read "op://K3s Service Cluster/Redis Password/password" > /dev/null
op read "op://K3s Service Cluster/Cloudflare DNS Challenge/domain" > /dev/null
```

Missing items → stop; report which item is absent (RUNBOOK.md §0 lists the
required fields). Additionally verify the Redis password is alphanumeric
(`op read ... | grep -qE '^[A-Za-z0-9]+$'` — check the exit code only).

## Stage 1 — Validate before touching the cloud

```bash
mise run setup
mise run check
```

**Gate 1:** `check` exits 0. Pre-existing lint debt (long lines in original
role shell blocks) is known — if `check` fails ONLY on those, note it and
proceed; any other failure stops you.

## Stage 2 — Infrastructure (OpenTofu)

```bash
mise run //infrastructure/tofu:plan     # review: expect creates only on a fresh deploy
mise run //infrastructure/tofu:apply
```

**Gate 2:** plan showed no destroys (fresh deploy) or only expected changes;
after apply: 3 servers, LB, network, firewall exist
(`op run -- hcloud server list`, `op run -- hcloud load-balancer list`);
DNS A records resolve to the LB IP.

## Stage 3 — Platform (K3s + core)

```bash
mise run //platform/ansible:deploy
export KUBECONFIG=<repo-root>/kubeconfig
kubectl get nodes                        # 3 nodes Ready
mise run //platform/charts/cert-manager:apply
mise run //platform/charts/step-ca:apply
mise run //platform/charts/velero:apply
```

**Gate 3:** 3 Ready nodes; wildcard Certificate reaches `Ready=True`
(`kubectl get certificate -A` — DNS-01 can take a few minutes); Velero BSL
`Available` (`kubectl -n velero get backupstoragelocation`).

## Stage 4 — NetworkPolicy enforcement canary (MANDATORY, before any service)

Run the canary exactly as written in RUNBOOK.md §1. The deny-all policy must
actually block traffic. If it does not, **stop — hard**: every NetworkPolicy
in every service is inert, and deploying services would create a false sense
of segmentation. Report and wait.

## Stage 5 — Services (bootstrap tier, in order)

```bash
for svc in database identity seaweedfs seaweedfs-csi redis copyparty \
           homarr gitea gitea-actions paperless gatus developer-tooling; do
  mise run //services/$svc:deploy || { echo "FAILED: $svc"; break; }
done
```

Per-service verification (run after each, not at the end):
- pods Ready in the namespace; no CrashLoopBackOff
- `kubectl get netpol -n <ns>` shows the default-deny + allows
- database: CNPG cluster healthy; `kubectl -n database get database gatus-db
  -o jsonpath='{.status.applied}'` → `true`
- identity: authentik-server logs show a successful Redis connection
  (first deploy with shared Redis — watch for auth errors)
- gatus: after deploy, its dashboard is the cluster-wide verification tool

**Human handoff during this stage:** after identity deploys, a human must add
their user to the `internal` group in Authentik (RUNBOOK.md §4) — the
forward-auth bindings deny everyone else. Flag it; do not block on it.

**Gate 5:** every service deployed; gatus reports green (or explained amber)
across its endpoint groups. Since this is a fresh deploy, the Redis-auth
"rollout" pain from RUNBOOK.md §2 does not apply — everything is born
authenticated.

## Stage 6 — GitOps activation

1. Push this repository to Gitea (`git remote add gitea
   https://git.<domain>/salish/cluster.git && git push gitea main`).
   Creating the Gitea org/repo and the read-only token for the
   `ArgoCD Repo Credentials` 1P item is a human step — request it, wait.
2. Ask the human which repo Argo should track: in-cluster Gitea (default) or
   the GitHub push-mirror (recommended for DR — breaks the bootstrap cycle).
   Set `argocd_repo_url` in `platform/argocd/ansible/roles/argocd/defaults/`
   accordingly if they choose the mirror.
3. `mise run deploy:gitops`
4. Gatus cutover per RUNBOOK.md §6: `helm -n gatus uninstall gatus` (this is
   a destructive op — confirm first), then watch the Argo Application reach
   `Synced/Healthy` and the gatus pods return.

**Gate 6:** `kubectl -n argocd get applications` shows `gatus` Synced +
Healthy with an empty diff on subsequent refreshes.

## Stage 7 — Final report

Produce a report containing: stage-by-stage pass/fail with the verification
evidence (command outputs, secrets redacted), the gatus dashboard state, the
list of human actions still pending (internal-group membership, ArgoCD repo
choice if deferred, go-live gate items from RUNBOOK.md §7 — which are
explicitly OUT of your scope), and any deviations you made with justification.

## Failure protocol

On any gate failure: capture `kubectl describe` + last 100 log lines of the
failing component into your report (scrub anything secret-shaped), attempt
ONE idempotent re-run of the failing task, then stop and report. Never
proceed past a failed gate. Never delete resources to "reset" without
confirmation. If the cluster ends in a partial state, say so plainly — a
partial deploy with an honest report is a success condition; a "green"
report over a broken cluster is the only unacceptable outcome.
