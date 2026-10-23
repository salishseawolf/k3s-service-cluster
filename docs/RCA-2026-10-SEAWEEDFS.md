# RCA: SeaweedFS never stored app data (2026-07-08 to 2026-10-10)

All times UTC. Status: resolved 2026-10-10 04:25; a follow-up incident on
2026-10-13 (node-02 OOM from a FUSE client) is covered below. Follow-ups in `docs/todo.md`
("SeaweedFS (after the 2026-10-09/10 incident)").

## Summary

From the first deploy until 2026-10-10, no app volume on the
`seaweedfs-storage` StorageClass was actually stored in SeaweedFS. Every such
PVC was a plain directory on the local disk of whichever node its pod ran on.
When a pod moved to another node it started on a different, usually empty,
directory and its data stayed behind on the old node. Two independent defects,
both introduced in commit `92fd39e` (2026-07-08), caused this, and each hid
the other.

The data was recovered, every app was migrated onto working SeaweedFS, and two
further incidents during the cleanup (a node disk filling up, and mount
clients pinned to a dead IP) were fixed along the way.

## Impact

| What | Effect | Outcome |
|---|---|---|
| Kimai MariaDB | moved node-03 to node-02 at 2026-10-09 19:05 and initialised an empty database; the hourly dump then backed up the empty DB | recovered from node-03's old directory: 2 users, 73 timesheets, 3 customers, 13 projects |
| Paperless | moved node-01 to node-02 on 2026-08-10; document #43 (added 15:32 that day) stayed on node-01, missing for two months | recovered from node-01; all 45 documents pass `document_sanity_checker` |
| Gitea runner | moved nodes on 10-07 and 10-09; registration file left behind ("unregistered runner" crash) | re-registered |
| Loki | moved node-01 to node-02 on 10-09; history split across nodes | started fresh (old logs archived on the nodes) |
| Prometheus | 40 GiB TSDB on node-02 local disk | started fresh (older days remain in B2) |
| Copyparty | only a test file | started fresh |
| Gitea, Alertmanager | never moved | restored from B2, no loss |
| Availability | storage outage 2026-10-10 03:15 to 03:31; reads hung for most apps about 03:27 to 04:25 | resolved |

Backups: VolSync's `copyMethod: Direct` movers ran on the app's node and saw
the same local directory, so the B2 backups held the real live data (Gitea's
backup matched its live volume file for file). The exception was Kimai's
database, whose dump backed up the empty DB after the 19:05 move.

## Root causes

### 1. `WEED_MASTER` disabled SeaweedFS volume growth

`platform/storage/seaweedfs/templates/11-deployment-seaweedfs.yaml` set
`WEED_MASTER=localhost:9333` on `weed server`. SeaweedFS reads configuration
through viper with automatic `WEED_*` environment variables
(`weed/util/config.go`: `AutomaticEnv`, prefix `weed`, `.` to `_`). In viper an
env var for a parent key shadows every nested key, so
`master.volume_growth.copy_1` resolved to 0. Each grow request then looped zero
times and returned success without creating a volume or logging an error. The
master retried about five times a second ("volume grow ... Count:0") and every
write failed with "No writable volumes".

Evidence: `/dir/status` showed the volume server registered with `Max 100,
Free 100, Volumes 0` and `writables: null`; raft state `maxVolumeId: 0`; the
data disk held only master metadata. Reproduced locally with the same 4.32
binary (`78da9572a`): identical flags with `WEED_MASTER` set created 0 volumes,
without it 7.

Fix: `4788cd8` removed `WEED_MASTER` (with a comment never to set a bare
`WEED_*` parent key), set `-master.volumeSizeLimitMB=1024` and
`WEED_MASTER_VOLUME_GROWTH_COPY_1=1` (full-key vars are safe).

### 2. The CSI node plugin could not see the FUSE mounts

The repo's hand-written `19-daemonset-seaweedfs-node.yaml` mounted the host's
`/var/lib/kubelet` with no mount propagation, where upstream v1.4.5 mounts
`/var/lib/kubelet/plugins` with `Bidirectional`. The separate `seaweedfs-mount`
pods create the FUSE mounts in the staging directories under
`plugins/kubernetes.io/csi/`, but the CSI plugin never saw them. On
NodePublish it bind-mounted the empty directory underneath into the pod and
reported success. The pod wrote to node-local ext4.

Evidence: every app pod's `/proc/mounts` showed `ext4` on `/dev/sd*`; on node-01
the mount service had `fuse.seaweedfs` on two staging dirs while the CSI plugin
saw zero.

Fix: `e893b58` mounts `/var/lib/kubelet/plugins` with `Bidirectional`.

### Why each hid the other

Because of 2, pods never wrote through SeaweedFS, so 1 never produced an app
error. Because of 1, a correct mount would have failed loudly, but 2 meant
there never was one.

## Why it went unnoticed for three months

- Apps kept their data as long as they stayed on one node.
- The wave-30 PVC canary only wrote and read back a file, which passes on local
  disk (old `canary` directories proved it ran on node disks).
- SeaweedFS was not scraped by Prometheus and had no alerts.
- The signals were in logs nobody looked at: the master's retry spam and the
  CSI driver's "directory not empty" unstage errors. Loki had not ingested
  anything until 2026-10-09, and log levels were not tagged.
- The manifests were hand-written rather than rendered from the upstream
  chart, and mount propagation is not covered by any lint or schema check.

## Incidents during the recovery

### Node-02 disk filled, SeaweedFS evicted (03:15 to 03:31)

The cleanup script moved leftover staging directories via a bind mount of `/`.
`mv` across mount points copies even on the same disk, so it started copying
40 GB of old Prometheus data onto node-02 (12 GB free). The kubelet hit
DiskPressure and evicted pods, including SeaweedFS, which could not reschedule
elsewhere (its 1 CPU / 1 GiB request only fits node-02). Freed by deleting the
old Prometheus leftovers; SeaweedFS was ready again at 03:27:21. The script was
fixed to move by the real path and to refuse unless source and destination
share a mount point.

### Mount clients pinned to a dead pod IP (about 03:27 to 04:25)

SeaweedFS advertised its pod IP. After the eviction and later restarts the IP
changed, but the long-lived mount clients kept reading chunks from the old one
(`read http://10.42.3.186:8080/... failed`). Writes still worked (new
assignments return a fresh location), so health checks and directory listings
looked fine while every content read hung. Fix: `d409928` adds a headless
Service and `weed server -ip=seaweedfs-headless.seaweedfs.svc.cluster.local`.
Existing clients only recover by remounting, which needs every pod using the
volume on that node to be gone, including VolSync movers; the last three apps
were released by pausing their backups and stopping them briefly (`a293f8d`,
`e7956fd`).

### Smaller ones

- The Loki chart forces `replicas >= 1` on filesystem storage, so
  `replicas: 0` did nothing; a node-selector hold was used instead.
- A Pending pod that still references a PVC makes a VolSync `Direct`
  ReplicationDestination fail with `Node "" not found`.
- A mover killed mid-run left a restic lock that failed every later forget.
  Cleared with the new `backup:*:unlock` mise tasks (`4f0155f`).

## Follow-up incident: node-02 starved by a FUSE client (2026-10-13)

### What happened

Around 18:51 six Renovate PRs merged together (five major bumps: Kimai's
MariaDB 11.8 to 13, Paperless 2 to 3, Redis 8, Homarr 2, the seed Job's
Postgres client). Shortly after, the user saw the `database` sync stuck and
asked whether it was causing wider problems. It was a symptom:

| Time (UTC) | Event |
|---|---|
| 15:14 | the `weed mount` client for Prometheus's volume starts on node-02 and keeps growing |
| 18:08 onwards | kernel OOM killer on node-02 kills `livenessprobe`, `hcloud-csi-driver`, Loki |
| 18:51 | Renovate merges land; the `database` PostSync hook Job pod is pinned to node-03, which has no CPU left, and stays Pending |
| 18:59 | node-02 stops heart-beating (`NotReady`, flapping); its API server hangs in TLS handshakes |
| 19:09 | on node-02: the Prometheus mount client at **4.2 GB RSS of 7.7 GB**, load 30-38, no swap |
| 19:14 | Prometheus stopped (`replicas: 0`); its volume unstages and the mount client exits |
| 19:17 | node-02 `Ready` again |
| 19:14-19:23 | Redis 8 refusing writes (`MISCONF`): no writable `/data` for RDB snapshots under a read-only root. Fixed with `--save ""` |
| ~19:30 | seed Job unpinned; `database` sync completes |
| 19:40-19:55 | node-02's kubelet only reachable about half the time (K3s tunnel `close 1006`, etcd peer `EOF`s) until `systemctl restart k3s` on node-02 |
| 20:40 | monitoring moved off SeaweedFS; a stuck sync (`$values` revision mismatch) left Loki down until a manual terminate and sync |
| ~21:20 | every Argo app moved to a single source; all 26 Synced/Healthy |

### Root cause

The SeaweedFS FUSE client buffers writes in RAM. Its options here
(`-concurrentWriters=128 -cacheCapacityMB=0`) give it no disk write cache, and
its memory is charged to the `seaweedfs-mount` pod, which has no limit, not to
the app. Prometheus writes constantly (WAL and 2-hour block compactions), so
its client grew until the node ran out of memory. Restarting Prometheus did not
help: the client belongs to the mount, which outlives the pod. This is the
"Prometheus on a non-POSIX filesystem" risk accepted in the original plan,
showing up as memory rather than corruption.

### Contributing factors

- **No memory limit** on `seaweedfs-mount` or on VolSync movers, and **no alert**
  on mount-client memory.
- **Six Renovate majors merged at once** into a cluster already degrading. Redis
  8 then broke five apps (Authentik, Gitea, Paperless, Homarr, Gatus) on its own.
- **A node-pinned hook Job** (`seedJob.nodeName`, pinned to where the CNPG
  primary used to run) could not schedule once that node was full.
- **Argo's two-source `$values` wiring** stuck two syncs on a stale revision
  (2026-10-10 and 2026-10-13), the second leaving Loki down.
- **Silent backup failures:** a stale restic lock made Loki's forget fail for
  three days while each retry saved another snapshot (1,073 pruned on
  2026-10-13). VolSync's metrics have been unscrapeable since August, so no
  `out_of_sync` alert could fire.
- **K3s on a node that was OOM-starved** stayed degraded (tunnel, etcd member)
  after memory recovered, until restarted.

### Changes made (2026-10-13)

| Commit | Change |
|---|---|
| `19e3454` | Prometheus stopped to release its mount client |
| `d4ec8d9` | Redis: `--save ""`, `--appendonly no` (cache/broker, no volume) |
| `2751454` | `database` seed Job no longer pinned to a node |
| `519f9c6` | monitoring off SeaweedFS: Loki on a 10 Gi Hetzner volume, Prometheus (7d / 8 GiB, 10 Gi cap) and Alertmanager (1 Gi cap) on `emptyDir`; their backups removed |
| `4d1f01a`, `3061186` | every Argo app on one source; `cluster-values.yaml` by relative path |
| (no commit) | `systemctl restart k3s` on node-02; stale restic lock on `loki-data` cleared |

Data: Kimai (2 users, 73 timesheets) and Paperless (45 documents) verified
intact after their major upgrades.

### Lessons

- Memory used by a FUSE client is not bounded by the app's limits. Heavy
  writers (TSDBs, databases) need a cap on the mount side or a block volume.
- Monitoring must not depend on the storage it monitors.
- Merge Renovate majors one at a time, with app checks between them.
- Do not pin Jobs to a node for locality; use the Service.
- After a node is OOM-starved, restart K3s on it even if it reports `Ready`.

## Follow-up incident: a dangling chunk after a rolling update (2026-10-22)

### What happened

`paperless-data` backups failed every hour for about 20 hours. The user found
the Job retrying in the `paperless` namespace; `VolSyncBackupOutOfSync` was
firing. Each mover still saved a snapshot of everything else, but restic exited
3 on one unreadable file, so VolSync counted every run as failed:

```
error: failed to save celerybeat-schedule.db: read celerybeat-schedule.db: input/output error
```

| Time (UTC) | Event |
|---|---|
| 10-22 17:53 | Renovate's Paperless 3.3.1 to 3.3.3 bump syncs. The Deployment uses the default RollingUpdate: the new pod starts on node-03 while the old one still runs on node-02 |
| 17:54:00 | both pods' celery beat write `celerybeat-schedule.db` through their own node's mount client; the new pod writes chunk `13,04e95056b5917d` (offset 45056), which the other client's writes leave marked deleted while the filer entry still lists it |
| ~17:56 | old pod gone |
| 19:09 | the master vacuums volume 13 and removes the deleted needle for good |
| 19:40 | last good backup (restic skips the file: unchanged since the parent snapshot) |
| 20:40 onwards | beat has rewritten the file; restic reads it, the volume server answers `404` even with `readDeleted=true`, every mover exits 3 |
| 10-23 16:14 | `Recreate` committed for paperless and copyparty (`6943094`); the sync fails (see below) |
| 16:19 | live Deployments patched to match git; both apps sync |
| ~16:21 | file removed and Paperless restarted (beat recreates it); manual backup succeeds at 16:22 |

### Root cause

The PVCs are `ReadWriteOnce`, but the SeaweedFS CSI driver does not enforce
single-node attachment, and a RollingUpdate starts the new pod before the old
one stops. Two `weed mount` clients on two nodes then wrote the same file, each
from its own cached chunk list. The filer kept a reference to a chunk one
client had already deleted, and vacuum later removed it. Celery beat's
`shelve` file, rewritten in 4 KiB pages every few minutes, was the file being
written during the two-minute overlap.

### Contributing factors

- **Default Deployment strategy** on SeaweedFS-backed apps. Kimai, Outline,
  Homarr and the Gitea runner already used `Recreate`; Paperless and Copyparty
  did not. Copyparty rolled across nodes in the same minute, without damage.
- **Restic only re-reads changed files**, so the 19:40 backup succeeded and a
  dangling chunk in a file that never changes would go unnoticed until a
  restore.
- **Argo's server-side apply cannot switch a live Deployment to `Recreate`:**
  nobody owns the API-defaulted `spec.strategy.rollingUpdate`, so the merged
  object fails validation (`rollingUpdate: Forbidden`). `rollingUpdate: null`
  in the manifest does not help. A one-off JSON patch removing it, or the
  per-resource `Replace=true` sync option, does.

### Changes made (2026-10-23)

| Commit | Change |
|---|---|
| `6943094` | paperless and copyparty Deployments use `strategy: Recreate` |
| (no commit) | `kubectl patch --type=json` on both Deployments: remove `/spec/strategy/rollingUpdate`, set type `Recreate` |
| (no commit) | `celerybeat-schedule.db` removed, Paperless restarted, one manual VolSync trigger (then removed) |

Data: every chunk of every file on `paperless-data` (28 files, 3,197 chunks)
and `copyparty-data` (4 files, 31 chunks) checked against the volume server
afterwards: all present. The lost file was a regenerable schedule cache.

### Lessons

- A SeaweedFS volume must never be mounted on two nodes at once. Deployments
  on `seaweedfs-storage` use `strategy: Recreate`; StatefulSets already stop
  the old pod first.
- To check a SeaweedFS volume's integrity, `HEAD` every chunk from the filer's
  metadata (`?metadata=true`) on the volume server; a successful backup only
  proves the files restic re-read.

## Timeline (2026-07-08 to 2026-10-10)

| When | Event |
|---|---|
| 2026-07-08 | `92fd39e` adds SeaweedFS and its CSI driver with both defects |
| 2026-07-10 | SeaweedFS data disk created; it never holds a volume file |
| 2026-08-10 | Paperless moves node-01 to node-02; document #43 stays behind |
| 2026-10-08 ~20:00 | Kimai deployed; MariaDB on node-03 |
| 2026-10-09 ~18:00-19:05 | Loki, copyparty, runner and Kimai MariaDB change nodes; Kimai's DB reinitialises empty |
| 2026-10-09 evening | A health check flags thousands of CSI "directory not empty" errors per hour; investigation finds pods on ext4 and an empty SeaweedFS |
| 2026-10-10 ~00:15 | Root cause 1 reproduced locally; root cause 2 confirmed on node-01 |
| 00:27-00:48 | Kimai DB dumped from node-03 and restored; Paperless #43 restored; Paperless failsafe copy taken off-cluster |
| 00:43 | Every staging directory archived on all nodes (`/root/swfs-rescue-20261010/`) |
| 00:53 | Volume growth fixed (`4788cd8`); first volume created |
| ~01:04 | CSI propagation fixed, canary asserts `fuse.seaweedfs`, backups paused (`e893b58`) |
| 01:10-03:10 | Per-app migration: Alertmanager, Paperless and Gitea restored from B2; Kimai via dump import; Loki, copyparty, runner and Prometheus started fresh |
| 03:15-03:31 | Node-02 disk fill and SeaweedFS eviction |
| ~03:45-04:25 | Stale mount clients found and fixed (`d409928`, then remounts) |
| ~04:30 | Every app passes a content read on `fuse.seaweedfs`; backups running |

## What went well

- Data first: every leftover directory was archived before anything was
  changed, and the most important data (Paperless, Kimai) was copied off the
  cluster before the migration.
- Both root causes were proven, not guessed: one by a local reproduction with
  the exact binary, the other by comparing two pods' views of one mount.
- Each app's migration had verification gates (mover mount type, file counts
  from SeaweedFS's side, app-level checks) before it was brought back.

## Changes made

| Commit | Change |
|---|---|
| `4788cd8` | volume growth fixed, 1 GiB volumes |
| `e893b58` | CSI mount propagation; canary requires `fuse.seaweedfs` |
| `a498085` | SeaweedFS logs to stderr; abandoned Gitea S3 identity and its copy of `Gitea Secrets` removed |
| `d409928` | stable headless-Service name instead of the pod IP |
| `4f0155f` | `backup:*:locks` / `backup:*:unlock` mise tasks |
| `0508f7f` | SeaweedFS metrics, ServiceMonitor and 7 email alerts |

## Lessons

- Never set a bare `WEED_*` parent-key env var on `weed` (`WEED_MASTER`,
  `WEED_FILER`, ...); it silently disables every nested setting.
- A storage canary must prove the backend, not just a write: assert the mount
  type.
- Prefer manifests rendered from the upstream chart; hand-written copies drift
  in ways no linter checks.
- Before relying on `replicas: 0` to stop an app, render it: some charts
  override it.
- On a node, move files by their real path; `mv` across mount points copies.
- Anything clients cache (addresses) must be stable across restarts.
