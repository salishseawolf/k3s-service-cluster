# Runbook — GitOps-First Operations

The repo now has exactly three owners, visible from any file's path:
`infrastructure/` = OpenTofu (human-run), `bootstrap/` = Ansible (runs ~once
per cluster life), everything under `platform/` and `services/` = Argo CD
(continuous). There is no `deploy` command anymore: **merged == deployed**.

## 0. One-time setup before first bootstrap

### Repo pointer
Argo pulls from the **GitHub push-mirror**, not in-cluster Gitea (that break
in the circular dependency is what makes Gitea an ordinary app and lets a
dead cluster rebuild without its own Gitea). Replace every
`https://github.com/CHANGEME/k3s-service-cluster.git` (root apps, appset,
bootstrap mise) with the real mirror URL — one `sed`, committed once. Set the
mirror up in Gitea: Settings → Repository → Push mirror.

### The single domain file
`platform/argocd/root/cluster-values.yaml` is the only file in the repo that
names the domain. Set `domain:` and the gitea `autoDiscoverUrl` host there.
Rebrand or domain cutover = a one-file PR.

### Vault items (1Password) — create/verify before bootstrap
| Item | Fields | Notes |
|---|---|---|
| ArgoCD Github Token | `username`, `password` | read-only PAT for the GitHub mirror |
| Gitea Secrets | `password`, `db_password`, `internal_token`, `secret_key`, `jwt_secret`, `oidc_key`, `oidc_secret`, `actions_token`, `admin_user`, `admin_password` | **oidc_key=** OIDC client ID (use `gitea`), **oidc_secret=** OIDC client secret, **actions_token=** runner registration token, **admin_user/admin_password=** Gitea admin login (no longer the db password) |
| Homarr Secrets | `password`, `oidc_client`, `oidc_secret` | `password` doubles as its db password (basic-auth) |
| Paperless Secrets | `secret_key`, `db_password`, `oidc_client`, `oidc_secret` | |
| VolSync B2 &lt;pvc&gt; (×5: gitea-data, homarr-data, paperless-data, paperless-media, copyparty-data) | `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | restic env verbatim, one item **per PVC** (repos must not be shared).<br>`RESTIC_REPOSITORY` = `s3:https://s3.us-west-004.backblazeb2.com/k3s-service-cluster/volsync/<ns>/<pvc>` |
| Authentik Deployment Secrets | `secret_key`, `db_password`, `bootstrap_email`, `bootstrap_password` | verify |
| SeaweedFS Secrets | `db_password`, `backup_access_key`, `backup_secret_key` | verify |
| Gatus Secrets | `password` | doubles as its db password |
| Umami Secrets | `db_password`, `app_secret` | `app_secret` is Umami's `APP_SECRET` hashing key; `db_password` is also consumed by bootstrap secret_zero for `umami-db-user-auth` |
| StepCA Secrets | `ca_password`, `provisioner_password`, `root_ca_crt`, `intermediate_ca_crt`, `intermediate_ca_key`, `ca_json`, `defaults_json`, `ssh_host_ca_key`, `ssh_user_ca_key` | consumed by bootstrap secret_zero |
| Cloudflare DNS Challenge | `password` (API token), `domain`, `zone_id`, `email` | issuer reads key `password` |
| Redis Password | `password` | alphanumeric only (embeds in redis:// URLs) |

## 1. Fresh deployment (also the disaster-recovery procedure)

```
tofu -chdir=infrastructure/tofu apply     # or step 1 of:
mise run bootstrap                        # tofu + K3s + 1P Connect +
                                          #   secret zero + Argo CD
kubectl -n argocd get applications -w     # watch the cascade
```

Bootstrap Ansible does exactly four things beyond K3s itself: installs
1Password Connect+Operator (the helm values carry the Connect credential —
this IS secret-zero delivery), creates the typed secrets the operator cannot
emit (CNPG `kubernetes.io/basic-auth` ×7, step-ca `smallstep.com/*` ×5 —
see `bootstrap/ansible/roles/secret_zero/`), installs Argo CD, and applies
`platform/argocd/root/`. Everything after that is the reconciler:

| Wave | Apps | Gate |
|---|---|---|
| 0 | argocd (self), cert-manager-crd, cnpg-operator | operator health |
| 10 | cert-manager-config, step-ca, database, redis | CNPG cluster healthy |
| 20 | seaweedfs, identity | filer + authentik up |
| 30 | seaweedfs-csi, volsync | **PVC canary Job must bind+mount a real volume** |
| 40 | services ApplicationSet (everything else) | — |

If wave 30's canary fails, wave 40 never starts: no consumer ever deploys
against broken storage.

## 2. Cutover from the live cluster (one-time)

The live cluster keeps running from its current state throughout; Argo
*adopts* rather than recreates wherever possible.

1. Complete §0 (vault items, repo pointer, cluster-values).
2. Run `mise run //bootstrap/ansible:deploy` against the LIVE cluster —
   idempotent for K3s/1P; adds secret_zero + Argo CD.
3. kubectl-applied services (redis, copyparty, paperless, homarr,
   gitea-actions, seaweedfs, seaweedfs-csi, gatus, database CRs):
   ServerSideApply adoption is automatic — Argo takes ownership on first
   sync. Watch for immaterial diffs (field-manager churn) on first pass.
4. Helm-deployed services (identity, gitea, velero, cert-manager, step-ca):
   `helm uninstall <release> --keep-history` per service, then let the wave
   sync. **PVCs and CNPG volumes survive** (Prune=false everywhere, and helm
   uninstall does not delete PVCs). Do identity in a quiet window — sessions
   drop while authentik restarts.
5. Outpost switch: copyparty + seaweedfs-filer move from manual outpost
   Deployments to authentik-managed (`ak-outpost-*` services). The blueprint
   creates the new outposts; delete the old Deployments/Secrets after the
   IngressRoutes go green.
6. Gitea OAuth: the auth source now registers via chart values
   (cluster-values.yaml). Delete the old CLI-registered source in Gitea
   admin if it duplicates.

## 3. Day-2 operations

- **Change anything**: PR → CI validates (helm template + kubeconform +
  kube-linter + gitleaks) → merge → Argo converges. The Argo diff is the
  review surface.
- **Add a service**: `mkdir services/<name>/app` with the standard anatomy
  (namespace w/ PSA labels, networkpolicy, onepassworditems, workload,
  ingressroute). The ApplicationSet discovers it. See docs/MIGRATION.md.
- **Rotate a secret**: rotate in 1Password; the operator re-syncs; restart
  consumers if they don't hot-reload. Nothing in git changes.
- **Upgrade Argo**: PR against `platform/argocd/self/Chart.yaml`.
- **Never** move CNPG storage onto `seaweedfs-storage`: the filer's metadata
  lives in CNPG. That cycle makes fresh deploys unbootstrappable — the
  two-StorageClass split is the acyclicity of the storage graph.

## 4. Known residue (deliberate)

- `bootstrap/ansible/roles/secret_zero/` exists because the 1P Operator
  emits only Opaque secrets. Adopting External Secrets Operator (1Password
  provider, typed secrets + templating) would shrink it to just the Connect
  credential — worth it if the residue ever grows.
- CNPG barman-cloud plugin enabled via ObjectStore CRD; daily backups to B2
  with 30d retention; instances at 3 for HA.
- Forward-auth on Gatus/Homarr blocks non-browser API clients; join the
  `internal` group before edge auth locks you out.
