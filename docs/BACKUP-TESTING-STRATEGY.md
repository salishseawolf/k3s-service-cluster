# Backup Testing Strategy

## Context

Current backups (CNPG barman-cloud + Velero kopia → B2) are now running
successfully, but **no restore has ever been tested**. A restore test is the
only way to prove the backup pipeline works end-to-end.

**Constraints:**
- Production cluster must not be interrupted
- All three nodes are in use (no spare capacity for a full clone)
- Test must be as realistic as possible without risking prod data

## Strategy 1 — Full Cluster Restore (separate infrastructure)

Provision a temporary 3-node K3s cluster mirroring production topology
(3 converged nodes at prod's server type + control-plane LB + private
network, ~€0.03-0.05/hr all-in), bootstrap it with the SAME Ansible playbooks
as production, and perform a full restore from B2. Spin it up, test, tear
down — well under €1 for a full-day drill. There is no recurring cost: all
resources are destroyed after each drill. Because the drill runs the real
bootstrap path (HA etcd, hcloud-ccm/csi, CIS args), it validates the
provisioning runbook as well as the backups.

**Steps:**
1. Provision the mirrored 3-node cluster via `tools/test-cluster/tofu` and
   bootstrap it with the production Ansible playbooks (test inventory)
2. Install Velero + CNPG operator + plugin-barman-cloud on the test cluster
3. Restore Velero backup (all PVCs, configs, resources)
4. Restore CNPG backup (database cluster)
5. Verify each service (Homarr, Paperless, Gitea, etc.) starts and serves data

**Pros:** Most realistic test — validates the full recovery runbook
**Cons:** 1-2 hours to provision and test; doesn't exercise the production
cluster's restore path (different infra)

**Best for:** Annual full DR drill

## Strategy 2 — In-Cluster Namespace Restore

Use Velero's `--namespace-mappings` restore feature to restore all backups into
isolated namespaces (e.g., `*-restore`) within the live cluster. CNPG cluster
can be restored as `main-db-restore` in the same `database` namespace (pods
don't conflict since the original Cluster CR owns the live pods).

**Steps:**
1. Restore Velero backup with `--namespace-mappings`:
   `velero restore create --from-backup velero-default-backup-20260713000030
   --namespace-mappings gitea:gitea-restore,paperless:paperless-restore,...`
2. Restore CNPG database: create a new Cluster CR with
   `bootstrap.recovery.source` pointing to the same B2 ObjectStore
3. Verify restored data in isolated namespaces

**Caveat:** Services that connect to external resources (Redis, shared DB
roles) will try to use production services unless their configs are overridden.
Some apps (ArgoCD, Traefik) are cluster-scoped and can't be fully namespace-
isolated.

**Pros:** No extra cost; uses the real cluster's restore path; fast (30-60 min)
**Cons:** Not a full DR test; namespace mapping doesn't cover cluster-scoped
resources; apps with hardcoded service references may conflict

**Best for:** Quarterly backup validation

## Strategy 3 — Component-Level Validation

Test each backup system independently without standing up full applications.

**CNPG restore test:**
```bash
# Create a restore job that extracts a backup and verifies database contents
kubectl -n database create job db-restore-test --image=... \
  -- barman-cloud-restore ... --test
# Or: use CNPG's bootstrap.recovery to create a temporary read-only cluster
```

**Velero restore test:**
```bash
# Restore a single PVC to a debug pod and verify file contents
velero restore create --from-backup velero-default-backup-... \
  --include-resources persistentvolumeclaims \
  --namespace-mappings homarr:homarr-restore
```

**Steps:**
1. Create a temporary CNPG cluster from backup (`bootstrap.recovery.source`)
   with `instances: 1` and no services
2. Connect to the temp cluster and run `SELECT count(*)` on each managed DB
3. Restore one Velero backup PVC to a temporary namespace
4. Verify file integrity (compare checksums, file counts)

**Pros:** Fastest (15-30 min); validates data integrity; no cross-service
conflicts; zero cost
**Cons:** Doesn't test application startup/bootstrapping; doesn't test service
connectivity; least realistic

**Best for:** Weekly/monthly backup health checks

## Recommendation

**Primary: Strategy 2 (In-Cluster Namespace Restore), quarterly.**

Run a namespace-mapped restore to test the full application boot sequence
without cluster-scoped resources. The namespace mapping handles service
isolation, and a restored CNPG cluster validates database integrity. This is
the best balance of realism vs. cost.

**Complementary: Strategy 3 (Component Validation), monthly.**

Run a quick CNPG bootstrap.recovery test and a Velero PVC restore as a
lighter-weight monthly health check. Catches data corruption early without
the overhead of a full namespace restore.

**Annual: Strategy 1 (Full Cluster Restore).**

Provision a fresh cluster end-to-end to validate the complete DR runbook.
This is insurance against the worst case (total infrastructure loss).

## Branch / Merge Policy

The domain override in `platform/argocd/root/cluster-values.yaml`
(`salishseawolf.com` → `salishseawolf.bid`) **must never reach `main`**.
Production ArgoCD tracks `main` with automated sync (prune + selfHeal); merging
the override performs a live domain cutover of production.

Structure:
- `restore-test-tooling` — docs + `tools/test-cluster/` only. Additive and
  safe; this is what merges to `main`.
- `test-full-cluster-restore` — `restore-test-tooling` plus the single
  domain-override commit. Never merged; rebased onto `main` before each drill,
  deleted or reset after.
