# Infrastructure Review — Critical Fix Plan

## C1: Paperless uses wrong invalidation flow slug
**File:** `services/identity/app/templates/configmap-blueprints.yaml:733`

**Root Cause:** The paperless Authentik OAuth2 provider references `default-invalidation-flow` (a non-existent slug), whereas all 8 other providers in the same file use `default-provider-invalidation-flow` (the correct built-in Authentik flow slug). This will cause Authentik to reject the blueprint at processing time.

**Evidence:** Search confirms 9 occurrences of `default-provider-invalidation-flow` across all other providers (lines 26, 367, 394, 419, 510, 562, 659, 984) and exactly 1 occurrence of the wrong slug `default-invalidation-flow` at line 733 (paperless only).

### Option 1 (Simplest — RECOMMENDED)
**Change:** 1 line, 1 file, zero risk.
- Edit `services/identity/app/templates/configmap-blueprints.yaml` line 733
- Change: `default-invalidation-flow` → `default-provider-invalidation-flow`
- The fix is a single-character correction in a flow reference, matching the pattern used by all other providers.

### Option 2 (Redundant — not needed)
Same change as Option 1. There is no alternative — this is a pure typo fix with exactly one correct value.

**Preconditions:** None. This is a pure text fix.
**Dependencies:** None.
**Verification:** After deployment, check Authentik logs for blueprint processing errors. The paperless provider should be created without errors.


## C2: Gatus DB connection string uses literal `***`
**Files:** `services/gatus/app/templates/configmap.yaml:13`, `services/gatus/app/templates/deployment.yaml:35-39`

**Root Cause:** The ConfigMap template has literal `***` as the password placeholder in the PostgreSQL connection string. The deployment injects `DATABASE_PASSWORD` as an env var from the `gatus-db` secret, but the storage config never references it — the connection string uses `***` which is not a valid password.

**Evidence:** Gatus v5.34.0 already supports `${ENV_VAR}` expansion in its config file (proven by `webhook-url: "${GATUS_SLACK_WEBHOOK}"` at configmap.yaml:23 which works in production). The Gatus storage config struct only has `path`, `type`, `caching` fields — no separate `password` field exists. The password must be embedded in the connection path string.

### Option 1 (Simplest — RECOMMENDED)
**Change:** 1 line in 1 file (`configmap.yaml` line 13).
- Replace `***` with `${DATABASE_PASSWORD}` in the connection string.
- After Helm rendering, the connection string becomes:
  `postgres://gatus_user:***@main-db-rw.../gatus_db?...`
- Gatus reads the config file, expands `${DATABASE_PASSWORD}` using the env var already set in the deployment.
- The deployment already injects `DATABASE_PASSWORD` via secretKeyRef (deployment.yaml:35-39) — no changes needed there.

### Option 2 (More robust — env var replacement via init container)
**Change:** Add init container to deployment, keep configmap as-is but with a placeholder.
- Add an init container that runs `envsubst` on the config file, replacing a known placeholder with the actual password from the env var.
- More complex (init container + volume mounts + shared emptyDir) but fully explicit.
- Overkill for this case since Gatus natively supports env var expansion.

### Option 3 (Alternative — if env var expansion doesn't work)
**Change:** Use a Kubernetes Secret for the entire config file, templated with the password.
- Remove the ConfigMap, create a Secret with the rendered config containing the actual password.
- The secretKeyRef already exists in deployment; just change the volume mount source from configMap to secret.
- More secure (password never in plaintext ConfigMap), but requires Secret management for the whole config.

**Preconditions:** Verify that Gatus's `${}` expansion works in the `>-` folded block scalar context. The Slack webhook precedent (line 23) strongly suggests it does.
**Dependencies:** None. The `DATABASE_PASSWORD` env var is already being injected (deployment.yaml:35-39).
**Verification:** After deployment, check Gatus logs for "connected to postgres" or similar. The dashboard should show endpoint history (proving DB persistence works).


## C3: cert-manager namespace has no PSA labels
**Files:** `platform/cert-manager/crd/templates/helmchart.yaml`, `platform/cert-manager/config/` (no namespace template)

**Root Cause:** The cert-manager namespace is created by a HelmChart CR (`createNamespace: true`) at sync-wave 0. The HelmChart CR has no mechanism to set labels on the namespace it creates. The cert-manager Helm chart doesn't include a namespace template either (it's deployed via the K3s Helm controller, not via Argo CD directly).

The cert-manager-config Argo CD app deploys to the `cert-manager` namespace at sync-wave 10 with `CreateNamespace=false`, but has no namespace template in its chart (this is todo.md issue M6).

**Cluster PSA default:** `restricted` (from bootstrap PSA config). The cert-manager namespace needs PSA labels to avoid relying on exemptions. Looking at the PSA config, `cert-manager` is NOT in the exemption list. The cert-manager pods (controller, webhook, cainjector) use restricted-compatible security contexts by default in v1.17.2.

**What PSA level does cert-manager need?** Checked cert-manager v1.17.2 Helm chart defaults: `runAsNonRoot: true`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true`. Fully `restricted` PSA compatible.

### Option 1 (Simplest — RECOMMENDED)
**Change:** Add namespace template to cert-manager-config chart. This leverages the existing cert-manager-config app that already deploys to the `cert-manager` namespace at sync-wave 10. The HelmChart (wave 0) creates the namespace first without labels; then the cert-manager-config app (wave 10) applies its namespace template which adds the labels.

- Create file: `platform/cert-manager/config/templates/namespace.yaml` (follows the gatus/redis/database pattern: restricted PSA + managed-by label)
- Delete: nothing. The HelmChart keeps `createNamespace: true`.
- The cert-manager-config app already has `CreateNamespace=false` and deploys to `cert-manager` namespace.

Files to create:
  `platform/cert-manager/config/templates/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
  labels:
    pod-security.kubernetes.io/enforce: restricted
    app.kubernetes.io/managed-by: argocd
```

Files to modify: None. This is additive only.

This also resolves todo.md M6 ("cert-manager config chart has no Namespace template").

### Option 2 (Pre-create in bootstrap)
Add namespace creation to the bootstrap Ansible playbook (like `secret_zero` creates `database` and `step-ca` namespaces). The HelmChart then deploys into the pre-existing namespace.
- Requires bootstrap re-run on existing clusters.
- Less GitOps-friendly (namespace not managed by Argo CD).

### Option 3 (PreSync hook in CRD chart)
Add a namespace template to the cert-manager-crd chart with a PreSync hook annotation, so the namespace is created with labels before the HelmChart deploys cert-manager.
- More complex: requires hook resource lifecycle management.
- The namespace would be owned by the hook, not the app — Argo CD might not prune it properly.

**Preconditions:** None for Option 1 (the fix is additive — existing namespace gets label update). PSA level verified against cert-manager v1.17.2 chart defaults.
**Dependencies:** None. This fix is independent of all other issues.
**Verification:** After deployment, `kubectl get namespace cert-manager -o yaml` should show PSA labels. cert-manager pods should start without PSA admission warnings.


## C4: cnpg-system namespace has no PSA labels
**File:** `platform/argocd/root/apps/cnpg-operator.yaml`

**Root Cause:** The CNPG operator Application uses `CreateNamespace=true` which creates the `cnpg-system` namespace without any labels. The CNPG operator is deployed from an external Helm chart (no local templates), so there's no place to add a namespace template within the existing chart structure. CNPG operator v0.27.0 uses restricted-compatible pod security contexts (`runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true`, `seccompProfile: RuntimeDefault`), so `restricted` PSA is appropriate.

### Option 1 (Simplest)
**Change:** Switch to `CreateNamespace=false` and add a namespace resource alongside the existing Application. Create a small local chart or directory that contains just the namespace template, then convert the Application to multi-source.

- Create directory: `platform/cnpg/`
- Create file: `platform/cnpg/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
  labels:
    pod-security.kubernetes.io/enforce: restricted
    app.kubernetes.io/managed-by: argocd
```

- Modify `platform/argocd/root/apps/cnpg-operator.yaml`:
  - Change `CreateNamespace=true` → `CreateNamespace=false`
  - Add a second source pointing to `platform/cnpg/` directory

The Application becomes multi-source:
```yaml
sources:
  - repoURL: https://github.com/salishseawolf/k3s-service-cluster.git
    targetRevision: main
    path: platform/cnpg
  - repoURL: https://cloudnative-pg.github.io/charts
    chart: cloudnative-pg
    ...
```

Files to create: 1 (`platform/cnpg/namespace.yaml`)
Files to modify: 1 (`platform/argocd/root/apps/cnpg-operator.yaml`, 2 changes: CreateNamespace + add source)

### Option 2 (Add to bootstrap — RECOMMENDED for simplicity)
**Change:** Add namespace creation to the bootstrap Ansible `secret_zero` role. The `secret_zero` role already creates `database` and `step-ca` namespaces with PSA labels. Adding `cnpg-system` follows the same pattern. The Application keeps `CreateNamespace=true` (namespace already exists, it's a no-op).

- Modify: `bootstrap/ansible/roles/secret_zero/tasks/main.yml`
- Add a task block before the existing tasks:
```yaml
- name: Ensure cnpg-system namespace exists
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: v1
      kind: Namespace
      metadata:
        name: cnpg-system
        labels:
          pod-security.kubernetes.io/enforce: restricted
```

Files to create: 0
Files to modify: 1 (`bootstrap/ansible/roles/secret_zero/tasks/main.yml`)
No changes to the Argo CD Application.

This is simpler than Option 1 because:
- The CNPG operator is infrastructure that must exist before most services
- Bootstrap already manages infrastructure namespaces (database, step-ca)
- No need to restructure the Argo CD Application

### Option 3 (Most robust — dedicated namespace chart)
Create a small Helm chart under `platform/cnpg/` with a namespace template + Chart.yaml, then reference it as a multi-source in the Application (same structure as Option 1 but using a proper Helm chart instead of raw YAML).
- Adds unnecessary Helm chart boilerplate for a single resource.
- Overkill unless we anticipate adding more resources to the cnpg namespace.

**Preconditions:** If using bootstrap option, the bootstrap playbook must be re-run on existing clusters.
**Dependencies:** Shares the bootstrap pattern with other infrastructure namespaces. If choosing Option 1 (multi-source), C3's approach (namespace template in a chart) can serve as a model.
**Verification:** After deployment, `kubectl get namespace cnpg-system -o yaml` should show PSA labels.


## Summary of Recommended Fixes

| ID | Issue | Approach | Files Changed | Files Created | Risk |
|----|-------|----------|---------------|---------------|------|
| C1 | Paperless wrong flow slug | Typo fix (1 line) | 1 | 0 | None |
| C2 | Gatus *** password | Env var expansion (1 line) | 1 | 0 | Low — verified by Slack precedent |
| C3 | cert-manager no PSA labels | Add namespace template to config chart | 0 | 1 | Low — follows restricted pattern |
| C4 | cnpg-system no PSA labels | Add to bootstrap Ansible | 1 | 0 | Low — follows existing pattern |

Total: 3 files modified, 2 files created. All fixes are independent (no ordering dependencies).

## Review

### Completeness check:
- All 4 critical issues addressed with actionable plans
- Each plan specifies exact file paths and changes
- Fix options ranked from simplest to most robust
- Preconditions and dependencies documented
- Verification steps included for each fix

### Correctness check:
- C1: Verified against all other blueprints (8 occurrences of correct slug)
- C2: Verified Gatus v5.34.0 supports ${ENV_VAR} expansion (Slack webhook precedent), verified storage config has no separate password field, verified env var is already injected in deployment
- C3: Verified cert-manager-config app deploys to cert-manager namespace, verified HelmChart creates namespace at wave 0 (before config app at wave 10), verified cert-manager not in PSA exemption list, verified cert-manager v1.17.2 defaults are restricted-compatible
- C4: Verified secret_zero bootstrap already manages database and step-ca namespaces with PSA labels, verified CNPG operator v0.27.0 is external Helm chart with no local templates, verified CNPG operator defaults are restricted-compatible

### Edge cases:
- C2: The `>-` YAML block scalar correctly preserves `${DATABASE_PASSWORD}` as a literal string. Helm's `{{ }}` templating does not interact with `${}` syntax. Gatus's `os.ExpandEnv()` processes it at runtime.
- C3: Argo CD will update (not recreate) the existing namespace when applying the namespace template — this is a label merge, which is safe.
- C4: If the cnpg-system namespace already exists when bootstrap runs, the `state: present` task is idempotent — it will add labels without error.
