# RCA: SeaweedFS never stored app data (2026-07-08 to 2026-10-10)

All times UTC. Status: resolved 2026-10-10 04:25; follow-ups in `docs/todo.md`
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

## Timeline

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
