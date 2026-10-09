# Infrastructure Review — Todo

## Pending Verification (on next fresh deploy)
- [ ] Gitea OIDC resolves with production LE cert
- [ ] Database syncs cleanly with managed roles + quota

## Backups
- [x] kimai MariaDB: hourly `mariadb-dump` CronJob into the `kimai-db-dump` PVC, uploaded by VolSync; failure email via Alertmanager
- [x] kimai backups: dump works (needed a connect-wait loop: K3s admits a new pod to the NetworkPolicy allow-sets a few seconds after start), kimai-data upload Successful under PSA `restricted`, `amtool` test email received
- [ ] kimai backups: confirm a `kimai-db-dump` snapshot exists (`mise run //services/kimai:backup:db-dump:snapshots`); the 21:45 run on 2026-10-08 skipped an empty volume, so the first real upload came later
- [ ] kimai backups: restore drill: restore `kimai-db-dump`, import `kimai.sql` into a scratch database, compare row counts (`kimai2_timesheet`, `kimai2_users`) with the live DB; this also tests the runbook's restore commands, which have never been run
- [ ] kimai: delete the failed pre-fix Job `kimai-mariadb-dump-29858295` (keeps the built-in `KubeJobFailed` firing until removed)
- [ ] VolSync cache: decide the restic cache StorageClass for all ReplicationSources (`seaweedfs-storage` / `hcloud-volumes` / keep `local-path` + alert). With `copyMethod: Direct` the mover must run on the app pod's node, but a `local-path` cache is pinned to the node of its first run, so a rescheduled app deadlocks its backup (homarr was stuck ~45h on 2026-10-06..08: "volume node affinity conflict"). Workaround until decided: delete the `volsync-src-<pvc>-cache` PVC and the stuck Job
- [ ] storage: two StorageClasses are marked default (`hcloud-volumes` and K3s' `local-path`), so a PVC without a class lands on either. `local-path` must stay (VolSync caches use it), and K3s re-applies its manifest on start, so the fix is a bootstrap change (K3s `.skip` + own local-storage manifest with the annotation `"false"`)
- [ ] step-ca: at the next fresh deploy, set `ca.db.storageClass: hcloud-volumes` in `platform/step-ca/crd/templates/helmchart.yaml`. Its PVC comes from the chart default (no class, so the cluster default), and StatefulSet `volumeClaimTemplates` are immutable, so it can't be pinned on the live cluster. Not backed up by choice (see docs/RECOVERY-RUNBOOK.md inventory)

## Monitoring & alerting
All default kube-prometheus-stack alerts go to the `null` receiver; only `notify: email` alerts are mailed (see `amtool alert query` for what's firing).
- [ ] volsync-metrics `TargetDown` (firing since 2026-08-07): Prometheus can't scrape VolSync, so `volsync_volume_out_of_sync` is missing and `KimaiBackupNotUploaded` can never fire; the VolSync Grafana dashboard is empty. Start with the target's `lastError` (`/api/v1/targets`)
- [ ] CNPG `TargetDown` for `database/main-db` (since 2026-08-07): likely the `database` NetworkPolicy doesn't admit Prometheus
- [ ] decide which default alerts deserve `notify: email`: `KubeJobNotCompleted` (would have caught homarr's stuck backup), `KubeJobFailed`, `TargetDown` all flagged real problems while unrouted
- [ ] `PrometheusOutOfOrderTimestamps` (~1.8 samples/s dropped): look for two ServiceMonitors scraping the same target (the custom volsync one next to an operator-created one?)
- [ ] capacity: `KubeCPUOvercommit` / `KubeMemoryOvercommit`: the cluster can't fit all pod requests after losing a node (short ~0.89 CPU, ~779 MB since 2026-10-07). `KubeCPUQuotaOvercommit` / `KubeMemoryQuotaOvercommit` are expected (per-namespace quotas are ceilings); disable or tune
- [ ] once kube-prometheus-stack ships prometheus-operator ≥ v0.90 (which knows `force_implicit_tls`), optionally move Alertmanager from `smtp.resend.com:2587` (STARTTLS) to `:2465` + `force_implicit_tls: true` in `services/monitoring/app/values.yaml`. Until then the operator's strict parse rejects the field and silently keeps the last good config; check with `amtool config show` after any Alertmanager config change
- [ ] Grafana: add Alertmanager as a data source (`http://prometheus-alertmanager.monitoring:9093`, `implementation: prometheus`, `handleGrafanaManagedAlerts: false`) to see routing/silences there
- [ ] Loki: confirm logs arrive after the 2026-10-09 fix (Alloy `loki_source_file_files_active_total` > 0 and `loki_write_sent_entries_total` rising; `{namespace="kimai"}` in Grafana Explore). Until then Loki was empty since deploy: `loki.source.file` never expanded the `__path__` globs (0 files tailed), and `auth_enabled: true` made Grafana fail with `no org id`. No logs from before the fix exist
- [ ] kimai-db-dump: VolSync's mover reports "Directory is empty skipping backup" (Successful) although `kimai.sql` is there and readable by uid/gid 999 (`drwxrws--- 0:999`); no repo exists in B2 yet. Catch a :45 run live (`kubectl -n kimai logs -f job/volsync-src-kimai-db-dump`, plus its pod's node and `securityContext`), or read it in Loki once logs flow
- [ ] mise: shorten monitoring's backup task names (`prometheus-main-db`/`alertmanager-db`/`loki-data` → `prometheus`/`alertmanager`/`loki`)

## Minor
- [ ] m1: Inconsistent namespace name quoting
- [ ] m6: Poorly named paperless deployment files
- [ ] m7: Share IngressRoute auth bypass undocumented

## Suggestions
- [ ] S2: Add egress NetworkPolicy restrictions where safe
- [ ] S5: Consider cluster monitoring

## Fix linting issues
Temporary kube-linter exceptions, marked `TODO(lint)` in the manifests
(`grep -rn "TODO(lint)" services platform`). Fixing one means removing its
`ignore-check.kube-linter.io/*` annotation; `mise run check` must still pass.
Permanent by-design exceptions (CSI node/mount, node-exporter, gitea-actions
dind, volsync probe ports, monitoring dangling-service) are not listed here.
- [ ] seaweedfs PDB: decide whether `maxUnavailable: 0` stays as a deliberate drain gate (moving seaweedfs is an outage for every PVC) or becomes `1`; add `unhealthyPodEvictionPolicy: AlwaysAllow` either way
- [ ] seaweedfs: map write paths outside `/data` for a read-only root; migrate ownership of root-owned data, then run non-root
- [ ] seaweedfs-csi controller: run the CSI sidecars (provisioner, attacher, resizer, livenessprobe) non-root with a read-only root; the PVC canary gates breakage
- [ ] copyparty: migrate PVC data ownership, then run as uid 1000; map write paths for a read-only root
- [ ] paperless: verify the `/run` emptyDir (`medium: Memory`) is already 0777, then remove the root `fix-perms` init container
- [ ] paperless: map the main container's write paths for a read-only root
- [ ] paperless tika: read-only root plus an emptyDir at `/tmp` (test with `podman run --read-only --tmpfs /tmp`)
- [ ] paperless gotenberg: read-only root plus an emptyDir at `/tmp` (same test)
- [ ] gitea: set `containerSecurityContext.readOnlyRootFilesystem: true` after a podman `--read-only` test (rootless image writes `/data` and `/tmp`)
- [ ] identity: authentik server and worker with a read-only root (SSO for everything, so test separately)
- [ ] monitoring grafana: read-only root (the chart supports it; writes `/var/lib/grafana` and `/tmp`)
- [ ] monitoring alloy: read-only root with an emptyDir for `/tmp/alloy`
- [ ] homarr: `init-nginx` read-only root (low risk, writes only to emptyDirs); main container read-only root and non-root after podman tests (exceptions predate the `TODO(lint)` marker)
- [ ] kimai: read-only root for kimai (apache, writes `var/cache` and `var/log`) and kimai-mariadb (writes `/tmp`); map the paths to emptyDirs, then drop their `TODO(lint)` annotations; test each with `podman run --read-only --tmpfs /tmp`
