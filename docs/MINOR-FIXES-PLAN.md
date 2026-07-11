# Plan: Minor Items & Suggestions

## m1 — Inconsistent namespace name quoting

**Issue:** Some namespace templates quote the name (`name: 'copyparty'`), some don't (`name: gitea`).

**Fix:** Remove quotes from the 6 namespaces that use them (copyparty, homarr, paperless, gitea-actions, seaweedfs, seaweedfs-csi). Quoted strings are valid YAML but inconsistent with the rest of the codebase.

**Files to modify:**
- `services/copyparty/app/templates/01-namespace-copyparty_namespace.yaml`
- `services/homarr/app/templates/01-namespace-homarr_namespace.yaml`
- `services/paperless/app/templates/01-namespace-paperlessnamespace.yaml`
- `services/gitea-actions/app/templates/01-namespace-gitea_actions_namespace.yaml`
- `platform/storage/seaweedfs/templates/01-namespace-swnamespace.yaml`
- `platform/storage/seaweedfs-csi/templates/01-namespace-seaweedfscsinamespace.yaml`

**Effort:** ~2 minutes (1-line change per file)

---

## m2 — Unpinned sidecar images

**Issue:** Three sidecar images use unpinned tags, risking unexpected upgrades on pod restart.

### m2a — `bitnami/kubectl:latest`
**File:** `platform/storage/seaweedfs/templates/25-cronjob-seaweedfs-backup.yaml:25`
**Fix:** Pin to `bitnamilegacy/kubectl:1.31` (Bitnami deprecated versioned tags on Docker Hub; the `bitnamilegacy` org provides frozen snapshots). Add a comment noting this should be revisited when a maintained alternative is available.

### m2b — `python:3.11-slim`
**File:** `platform/storage/seaweedfs/templates/29-deployment-seaweedfs-backup-check.yaml:25`
**Fix:** Pin to `python:3.11.15-slim` (current latest 3.11.x patch).

### m2c — `busybox` (no tag)
**File:** `services/homarr/app/templates/08-deployment-homarr.yaml:28`
**Fix:** Pin to `busybox:1.37.0` (latest stable release with named tags on Docker Hub).

**Effort:** ~5 minutes (1-line change per file)

---

## m3 — Empty values.yaml stubs lack domain injection comment

**Issue:** Five services have `domain: ""` with no explanation of where the domain comes from.

**Fix:** Add a comment above `domain: ""`:
```yaml
# Injected by the root ApplicationSet from platform/argocd/root/cluster-values.yaml
domain: ""
```

**Files to modify:**
- `services/copyparty/app/values.yaml`
- `services/gitea-actions/app/values.yaml`
- `services/homarr/app/values.yaml`
- `services/paperless/app/values.yaml`
- `platform/storage/seaweedfs-csi/values.yaml`

**Effort:** ~3 minutes (1-line addition per file)

---

## m4 — Gitea values.yaml references disabled valkey-cluster

**Issue:** `services/gitea/app/values.yaml:31` has `valkey-cluster: {enabled: false}` — a dead config left over from the Gitea chart's optional subchart. Gitea uses the shared Redis, not valkey.

**Fix:** Remove the line entirely.

**Files to modify:**
- `services/gitea/app/values.yaml` (line 31)

**Effort:** ~1 minute

---

## m5 — Stale identity certificate placeholder template

**Issue:** `services/identity/app/templates/certificate.yaml` is an empty 2-line comment file. It renders nothing and is confusing.

**Fix:** Delete the file.

**Files to modify:**
- `services/identity/app/templates/certificate.yaml`

**Effort:** ~1 minute

---

## m6 — Poorly named paperless deployment files

**Issue:** Three deployment files:
- `50-deployment.yaml` — paperless main
- `50-deployment-2.yaml` — tika
- `50-deployment-3.yaml` — gotenberg

**Fix:** Rename to:
- `50-deployment.yaml` (unchanged — single source of truth for references)
- Add comments at the top of `50-deployment-2.yaml` and `50-deployment-3.yaml` documenting which service they deploy

Alternatively, rename all three:
- `50-deployment-paperless.yaml`
- `51-deployment-tika.yaml`
- `52-deployment-gotenberg.yaml`

**Risk:** Renaming requires updating any references in Helm notes, CI, or documentation. A git rename (`git mv`) preserves git history but changes the file path. Simpler: add clarifying comments only.

**Files to modify:**
- `services/paperless/app/templates/50-deployment-2.yaml`
- `services/paperless/app/templates/50-deployment-3.yaml`

**Effort:** ~5 minutes (add header comments)

---

## m7 — Share IngressRoute auth bypass undocumented

**Issue:** `services/copyparty/app/templates/12-ingressroute-copyparty-share.yaml` has no comment explaining that the share link route intentionally bypasses Authentik auth.

**Fix:** Add comment at the top of the file:
```yaml
# Share links bypass Authentik forward-auth intentionally — copyparty's
# built-in access controls handle authorization for the /shr endpoint.
# Priority 150 ensures this route matches before the auth-gated catch-all.
```

**Files to modify:**
- `services/copyparty/app/templates/12-ingressroute-copyparty-share.yaml`

**Effort:** ~2 minutes

---

## S1 — Add PodDisruptionBudget for CNPG database cluster

**Issue:** No PDB on the database cluster. Both PostgreSQL pods could be taken down simultaneously during node maintenance.

**Fix:** Add a new file `services/database/app/templates/poddisruptionbudget.yaml`:
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: main-db-pdb
  namespace: database
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      cnpg.io/cluster: main-db
```
CNPG deprecated the `postgresql` label. The correct label is `cnpg.io/cluster: main-db` (where `main-db` comes from `{{ .Values.clusterName }}` in the Helm chart).

**Risk:** Low — PDBs are advisory during voluntary disruptions (node drains, deployments). A `maxUnavailable: 1` with 2 instances means kubernetes will wait for one pod to become ready before draining the other.

**Files to create:**
- `services/database/app/templates/poddisruptionbudget.yaml`

**Effort:** ~10 minutes (create, commit)

---

## S2 — Add egress NetworkPolicy restrictions

**Issue:** Most service namespaces allow unrestricted egress. Only gitea-actions has egress restrictions.

**Fix:** Add a default-deny-egress policy and allow rules to each service namespace. Template:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: '{{ .Values.namespace }}'
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
    # Allow intra-namespace traffic
    - to:
        - podSelector: {}
```

**Scope:** 6 service namespaces (gitea, gatus, copyparty, homarr, paperless, gitea-actions, seaweedfs, seaweedfs-csi).

**Risk:** Medium — adding egress restrictions can break things. Each namespace's specific dependencies need to be documented (e.g., gitea needs egress to database, redis, identity; homarr needs egress to identity for OIDC; etc.). Recommend per-namespace analysis before implementation.

**Effort:** ~2-3 hours (research dependencies, create templates, test)

---

## S3 — Add ResourceQuota + LimitRange to service namespaces

**Issue:** Service namespaces (gitea, gatus, copyparty, homarr, paperless, gitea-actions) have no resource quotas. A misconfigured pod could consume unbounded resources.

**Fix:** Add `resourcequota.yaml` and `limitrange.yaml` to each service chart's templates. Model from the database chart:
```yaml
# resourcequota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: service-quota
  namespace: '{{ .Release.Namespace }}'
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 4Gi
    limits.cpu: "4"
    limits.memory: 8Gi

# limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: pod-defaults
  namespace: '{{ .Release.Namespace }}'
spec:
  limits:
    - type: Container
      default:
        cpu: 200m
        memory: 256Mi
      defaultRequest:
        cpu: 50m
        memory: 64Mi
```

**Risk:** Low — ResourceQuota prevents unbounded consumption. LimitRange sets safe defaults for pods without explicit resource requests.

**Effort:** ~30 minutes (create files for 6 service namespaces)

---
