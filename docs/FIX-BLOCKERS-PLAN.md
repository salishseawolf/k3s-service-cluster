# Plan: Fix Two Blockers

## Issue 1 — Argo CD OIDC URLs hardcoded

**Problem:** `platform/argocd/self/values.yaml` hardcodes `salishseawolf.com` in
`url`, `oidc.config.issuer`, and `oidc.config.logoutURL`. Static Helm values
can't be templated.

**Fix:** Create a template that owns the entire `argocd-cm` ConfigMap, using
`{{ .Values.domain }}`. Disable the upstream chart's own `argocd-cm` creation
to avoid dual-ownership conflicts.

### Step 1 — Disable upstream argocd-cm creation
In `platform/argocd/self/values.yaml`, add:
```yaml
configs:
  cm:
    create: false
```

This tells the upstream `argo-cd` chart not to create its own `argocd-cm`.
The new template will be the sole owner.

### Step 2 — Remove hardcoded OIDC + RBAC from values.yaml
Remove `url`, `oidc.config`, and `logoutURL` from the `configs.cm` section.
Keep `admin.enabled: "true"` (moves to the template). Remove the `configs.rbac`
section (moves to the template).

### Step 3 — Create full argocd-cm template
Create `platform/argocd/self/templates/argocd-cm.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: "https://argocd.{{ .Values.domain }}"
  admin.enabled: "true"
  oidc.config: |
    name: Authentik
    issuer: https://auth.{{ .Values.domain }}/application/o/argocd/
    clientID: $argocd-oidc:oidc_client
    clientSecret: $argocd-oidc:password
    requestedScopes: ["openid", "profile", "email"]
    requestedIDTokenClaims: {"groups": {"essential": true}}
    logoutURL: https://auth.{{ .Values.domain }}/application/o/argocd/end-session/
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly
  policy.csv: |
    g, infrastructure, role:admin
```

### Step 4 — Add domain value
Add `domain: ""` to `platform/argocd/self/values.yaml` so the template has
a value. The root ApplicationSet injects the real domain via `$values`.

### Risk
- On first deploy, the new template creates `argocd-cm` from scratch with
  OIDC config + admin enabled + URL set. No race condition — single owner.
- On upgrade, Helm sees the old `argocd-cm` (created by upstream chart) and
  adopts it. The `create: false` prevents the upstream chart from creating a
  duplicate. Template replaces upstream entirely.
- If `domain` is empty, URLs become `https://argocd.` (broken). Ensure the
  root app always injects a valid domain.

---

## Issue 2 — Services project blocks LimitRange

**Problem:** `platform/argocd/root/projects/services.yaml:21` has:
```yaml
namespaceResourceBlacklist:
  - group: ''
    kind: LimitRange
```

This blocks the LimitRange resources we just added to all 6 service charts.

**Fix:** Remove the LimitRange entry from the namespaceResourceBlacklist.

### Files to modify:
- `platform/argocd/root/projects/services.yaml` — remove the LimitRange entry

### Risk
- **None.** LimitRanges are safe namespace-scoped resources. The `platform`
  project already allows them.

---

## Verification
1. `helm template --set domain=test.com platform/argocd/self/` — check output
   has `argocd-cm` with `auth.test.com`, `argocd.test.com` URLs
2. Check that `argocd-rbac-cm` also appears in the output
3. `mise run check` — passes lint
