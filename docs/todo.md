# Infrastructure Review — Todo

## Pending Verification (on next fresh deploy)
- [ ] Gitea OIDC resolves with production LE cert
- [ ] Database syncs cleanly with managed roles + quota

## Backups
- [x] kimai MariaDB: hourly `mariadb-dump` CronJob into the `kimai-db-dump` PVC, uploaded by VolSync; failure email via Alertmanager
- [x] kimai backups: dump works (needed a connect-wait loop: K3s admits a new pod to the NetworkPolicy allow-sets a few seconds after start), kimai-data upload Successful under PSA `restricted`, `amtool` test email received
- [ ] kimai backups: confirm a `kimai-db-dump` snapshot exists (`mise run //services/kimai:backup:db-dump:snapshots`); the 21:45 run on 2026-10-08 skipped an empty volume, so the first real upload came later
- [ ] kimai backups: restore drill: restore `kimai-db-dump`, import `kimai.sql` into a scratch database, compare row counts (`kimai2_timesheet`, `kimai2_users`) with the live DB; this also tests the runbook's restore commands, which have never been run
- [x] kimai: deleted the failed pre-fix Job `kimai-mariadb-dump-29858295` (2026-10-09)
- [x] VolSync cache: ReplicationSource caches moved from `local-path` to `seaweedfs-storage` (2026-10-09). With `copyMethod: Direct` the mover runs on the app pod's node, and a `local-path` cache stayed on the node of its first run, so a rescheduled app deadlocked its backup (homarr ~45h on 2026-10-06..08, loki-data on 2026-10-09). Restores (docs/RECOVERY-RUNBOOK.md) keep `local-path`
- [ ] storage: two StorageClasses are marked default (`hcloud-volumes` and K3s' `local-path`), so a PVC without a class lands on either. `local-path` must stay (VolSync restore caches use it), and K3s re-applies its manifest on start, so the fix is a bootstrap change (K3s `.skip` + own local-storage manifest with the annotation `"false"`)
- [ ] step-ca: at the next fresh deploy, set `ca.db.storageClass: hcloud-volumes` in `platform/step-ca/crd/templates/helmchart.yaml`. Its PVC comes from the chart default (no class, so the cluster default), and StatefulSet `volumeClaimTemplates` are immutable, so it can't be pinned on the live cluster. Not backed up by choice (see docs/RECOVERY-RUNBOOK.md inventory)

## SeaweedFS (after the 2026-10-09/10 incident)
Every app PVC was node-local disk until 2026-10-10 (`WEED_MASTER` disabled volume growth; the CSI node DaemonSet lacked mount propagation). Fixed and all apps migrated; these are the follow-ups.
- [x] RCA write-up: `docs/RCA-2026-10-SEAWEEDFS.md` (both root causes, the node-02 disk fill, the stale-IP mount clients); lessons in AGENT.md "Storage" (2026-10-10)
- [ ] alert on stale FUSE mount clients: only visible in the `seaweedfs-mount` pods' logs (`read http://<ip>:8080/... failed`), not in metrics. Needs the Loki ruler (not configured) plus an Alertmanager route
- [x] NetworkPolicy: `weed server` now admits only `seaweedfs-csi` (all ports), `gatus` (8333, 9333, 8888, 8080), `monitoring` (9327) and Traefik's node addresses on 8888 (`values.traefikSources`: node IPs plus each node podCIDR's .0/.1, measured 2026-10-13; update if nodes are rebuilt). Verified 2026-10-13: existing and fresh mounts, scrape, Gatus, filer UI via every node, and an ordinary pod is refused
- [ ] single point of failure: one `weed server` pod holds all app storage, so a SeaweedFS restart or eviction is an outage for every app (mounts now reconnect by themselves). Decide: run it HA (separate master/volume/filer, replication) or accept it and rely on the `SeaweedFSDown` alert. It also needs 1 CPU / 1 GiB, which only fits where a node has room (it moved node-02 to node-03 on 2026-10-13)
- [x] backups: first clean runs after the stale-mount fix confirmed (paperless 2026-10-10). Loki's then failed silently until 2026-10-13: a stale restic lock broke forget while each retry saved a snapshot (1,073 pruned once unlocked). `prometheus-main-db` and `alertmanager-db` removed: both run on `emptyDir` since 2026-10-13
- [ ] FUSE reads run at about 2-5 MB/s; fine for current apps, benchmark before putting anything throughput-heavy on SeaweedFS
- [ ] Gitea admin: delete the offline `gitea-runner-01` registration left by the runner's fresh volume
- [x] deleted the rescue copies: `/root/swfs-rescue-20261010/` on all three nodes and `/root/kimai-old-db/` on node-03 (a Kimai dump with password hashes), node-01 on 2026-10-13, the rest 2026-10-14 after confirming Kimai's hourly dump and VolSync uploads succeed

### Follow-ups from 2026-10-13 (node-02 OOM, `docs/RCA-2026-10-SEAWEEDFS.md`)
- [ ] alert on FUSE client memory: `container_memory_working_set_bytes{namespace="seaweedfs-csi", container="seaweedfs-mount"}` above ~1.5 GiB per node, email. Baseline 2026-10-13 21:29: 167-541 MiB per node; largest client Kimai MariaDB at 281 MiB (node-01), so watch whether it grows
- [ ] memory limits: `seaweedfs-mount` has none (a limit that trips kills every mount on the node, so size it with the alert data first), and VolSync movers have `resources: {}`
- [x] Kimai: `MARIADB_AUTO_UPGRADE=1` on the MariaDB StatefulSet; the 11.8 to 13 system-table upgrade ran 2026-10-13 (system tables backed up first, user tables untouched, data verified: 2 users, 73 timesheets)
- [x] Kimai MariaDB probes (2026-10-13): switch to the image's `healthcheck.sh --connect --innodb_initialized` (uses `/var/lib/mysql/.my-healthcheck.cnf`, created by the upgrade). Today's probe connects without a password, logging `Access denied for user 'mysql'@'127.0.0.1'` every 10 s, and the TCP probe logs `Aborted connection`
- [ ] Gatus: external check on Prometheus `/-/ready`, since an `emptyDir` eviction restarts it with no one to alert
- [ ] Renovate: stop majors landing together (six merged at once on 2026-10-13; Redis 8 broke five apps). E.g. `major: {dependencyDashboardApproval: true}` plus one major at a time with app checks between

## Monitoring & alerting
All default kube-prometheus-stack alerts go to the `null` receiver; only `notify: email` alerts are mailed (see `amtool alert query` for what's firing).
- [x] volsync-metrics `TargetDown` (2026-08-07 to 2026-10-13): the VolSync chart always creates its own ServiceMonitor without a bearer token (401) next to the repo's working one. Fixed with `metrics.disableAuth: true` and the duplicate removed; `VolSyncBackupStuck` / `VolSyncBackupOutOfSync` now email for every ReplicationSource (`platform/volsync/templates/prometheusrule-volsync.yaml`)
- [ ] CNPG `TargetDown` for `database/main-db` (since 2026-08-07): likely the `database` NetworkPolicy doesn't admit Prometheus
- [ ] decide which default alerts deserve `notify: email`: `KubeJobNotCompleted` (would have caught homarr's stuck backup), `KubeJobFailed`, `TargetDown` all flagged real problems while unrouted
- [ ] `PrometheusOutOfOrderTimestamps` (~1.6 samples/s): not the VolSync duplicate (removed 2026-10-13, still firing). Prometheus logs it for `serviceMonitor/monitoring/prometheus-kubelet` (cAdvisor), so look there: `prometheus_target_scrapes_sample_out_of_order_total` by scrape pool, and kubelet `honorTimestamps`
- [ ] capacity: `KubeCPUOvercommit` / `KubeMemoryOvercommit`: the cluster can't fit all pod requests after losing a node (short ~0.89 CPU, ~779 MB since 2026-10-07). (`KubeCPUQuotaOvercommit` / `KubeMemoryQuotaOvercommit` disabled 2026-10-09: per-namespace quotas are deliberate ceilings)
- [ ] once kube-prometheus-stack ships prometheus-operator ≥ v0.90 (which knows `force_implicit_tls`), optionally move Alertmanager from `smtp.resend.com:2587` (STARTTLS) to `:2465` + `force_implicit_tls: true` in `services/monitoring/app/values.yaml`. Until then the operator's strict parse rejects the field and silently keeps the last good config; check with `amtool config show` after any Alertmanager config change
- [x] Grafana: add Alertmanager as a data source (`http://prometheus-alertmanager.monitoring:9093`, `implementation: prometheus`, `handleGrafanaManagedAlerts: false`) to see routing/silences there
- [x] Loki: confirm logs arrive after the 2026-10-09 fix (confirmed 2026-10-09) (Alloy `loki_source_file_files_active_total` > 0 and `loki_write_sent_entries_total` rising; `{namespace="kimai"}` in Grafana Explore). Until then Loki was empty since deploy: `loki.source.file` never expanded the `__path__` globs (0 files tailed), and `auth_enabled: true` made Grafana fail with `no org id`. No logs from before the fix exist
- [x] kimai-db-dump: first backup 2026-10-09 23:27. The "Directory is empty" runs predate the dump; once it existed, B2 refused with `Access Denied` because the key's name prefix (`volsync/kimai/kimai-mariadb-dumps`) didn't cover the repo path (`volsync/kimai/kimai-db-dump`). Replaced with a correctly scoped key. Note: the 1Password operator doesn't recreate a deleted Secret until it restarts (`kubectl -n 1password rollout restart deploy/onepassword-connect-operator`)
- [x] mise: shorten monitoring's backup task names (`prometheus-main-db`/`alertmanager-db`/`loki-data` → `prometheus`/`alertmanager`/`loki`)
- [x] gatus: the "Traefik Dashboard" check (never passed: dashboard not exposed, and the bare domain is the personal site, so nginx logged a 404 every minute) replaced by a TCP check on `traefik.kube-system.svc.cluster.local:443` (2026-10-13)
- [x] node-exporter: `kernel_hung` collector fails every scrape (`/host/proc/sys/kernel/hung_task_detect_count` missing on this kernel); disable it (`--no-collector.kernel_hung`) (done 2026-10-14: `extraArgs: [--no-collector.kernel_hung]`)

## Minor
- [ ] m1: Inconsistent namespace name quoting
- [x] m6: Poorly named paperless deployment files (renamed by workload: paperless, tika, gotenberg; 1P items by secret name)
- [x] m7: the copyparty "share" IngressRoute was an auth bypass, not just undocumented: `Query(h, .{0,})` is an exact match in Traefik v3, so `?h=.{0,}` skipped forward-auth and copyparty trusted client-sent `X-Authentik-*` headers (confirmed 2026-10-09: forged `probe`/`infrastructure` got browse + upload on `/`). Reachable only from the admin IP/private net. Route deleted 2026-10-09; share links (`/shr`) go through forward-auth
- [x] copyparty: any pod could forge identity. Confirmed 2026-10-14: from the paperless pod, `curl copyparty.copyparty:3923/?ls` with `X-Authentik-Username`/`-Groups` headers got read/write/move/delete/admin (no headers: no permissions), because `allow-ingress-traefik` admitted all of `10.42.0.0/16` and `xff-src` trusted it. Fixed: both now use `traefikSources` (private net + each node's flannel `/31`) in `services/copyparty/app/values.yaml`; the same request is refused, Gatus and logged-in browser loads through every node's Traefik still work
- [x] copyparty: forged `probe` user removed. The IdP store lives in the container (`/root/.config/copyparty/idp.db`), so restarts clear it; empty after the 2026-10-14 fix rolled out
- [ ] copyparty: if shares should work logged out, add a `PathPrefix(/shr/)` route with a middleware that strips client `X-Authentik-*` headers
- [ ] traefik: Grafana's IngressRoutes name `wildcard-salishseawolf-com-tls`, which doesn't exist in `monitoring` (Traefik logs `Error configuring TLS` and falls back to the default cert); use `tls: {}` like the other routes
- [ ] authentik: the outpost's Kubernetes integration creates Ingresses outside git (`copyparty/ak-outpost-copyparty` for `files.`, `seaweedfs/ak-outpost-seaweedfs-filer` for `filer-s3.`) pointing at a missing `authentik-outpost-tls` secret. Decide whether the integration should manage Ingresses at all (the IngressRoutes already route through forward-auth), and add `filer-s3.` to AGENT.md's Perimeter section if it stays
- [x] argocd: `cannot reference a different revision of the same repository` (stuck syncs on 2026-10-10 and 2026-10-13, the second left Loki down). Fixed 2026-10-13: every app uses one source and loads `cluster-values.yaml` by relative path (`monitoring-crd` keeps two sources: different repos)

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
