# Shared MariaDB in the database namespace

Plan (2026-10-19). Step 1 scaffolded in `services/mariadb/app` (not yet
deployed); steps 2-5 not started.

Move Kimai's MariaDB out of the `kimai` namespace into `database`, as a
shared service next to CNPG, on `hcloud-volumes` instead of
`seaweedfs-storage`. Kimai becomes its first tenant.

## Why

- **Incident 2026-10-18/19:** InnoDB rewrites `ib_logfile0` in place on
  every commit. On SeaweedFS each flush rewrites the file's chunk list, and
  the filer appends the whole entry (~0.6 MB) to its never-pruned metadata
  log (`/topics/.system/log`). About 10 GiB/day from 2026-10-10 until all
  100 volume slots were used; SeaweedFS stopped writing, Kimai crash-looped
  and every new VolSync mount timed out. AGENT.md already says busy
  databases don't belong on SeaweedFS.
- **Tuning doesn't fix it:** MariaDB can't disable its redo log, and
  `innodb_flush_log_at_trx_commit` / a smaller log file reduce the volume
  only partly; the data files and doublewrite buffer behave the same way.
- **Shared, not per-app:** one MariaDB for every app that needs MySQL
  (Kimai only supports MySQL/MariaDB, so it can't use CNPG), with users,
  databases, backups, alerts and network policy owned by `database`, the
  way CNPG serves the Postgres apps.

## Current state (services/kimai/app)

| Piece | Today |
|---|---|
| Server | `kimai-mariadb` StatefulSet, `mariadb:13.0.2`, uid 999, 100m/256Mi (1/1Gi) |
| Data | PVC `kimai-mariadb-data`, 4Gi, `seaweedfs-storage` (not backed up: crash-consistent only) |
| Backup | CronJob `kimai-mariadb-dump` at :15 into PVC `kimai-db-dump` (seaweedfs), VolSync at :45 (`VolSync B2 kimai-db-dump`) |
| Alerts | `KimaiDbDumpFailed`, `KimaiDbDumpStale`, `KimaiDbDumpNeverSucceeded` (email) |
| Secrets | `Kimai Secrets`: `mariadb-password`, `mariadb-root-password` |
| Client | `DATABASE_URL=mysql://kimai:$(DB_PASSWORD)@kimai-mariadb:3306/kimai?...serverVersion=<tag>-MariaDB` |
| Network | MariaDB reachable only inside `kimai` (allow-intra-namespace) |

## Target

Layout: its own chart, `services/mariadb/app`, which the services
ApplicationSet syncs in wave 40, with every manifest in the `database`
namespace. Not inside the `database` chart (wave 10): seaweedfs-storage and
VolSync's CRDs only exist from wave 30, so the dump PVC would stay Pending
and the ReplicationSource would fail the dry run, and a fresh deploy would
never get past wave 10. Only the data volume is on hcloud; the dump PVC and
the VolSync cache stay on SeaweedFS. The `database` chart only gets the
quota bump.

| Piece | Target |
|---|---|
| Server | StatefulSet `mariadb` in `database`, same image and uid, Service `mariadb.database.svc.cluster.local:3306` |
| Data | PVC `mariadb-data`, **10Gi** (hcloud minimum), `hcloud-volumes`, `Prune=false,Delete=false` |
| Tenants | idempotent provisioning Job (PostSync hook, like `20-job-seed-group.yaml`): per tenant `CREATE DATABASE IF NOT EXISTS`, `CREATE USER IF NOT EXISTS`, `ALTER USER ... IDENTIFIED BY` (keeps the password in sync with 1Password), `GRANT ALL ON <db>.*` |
| Backup | CronJob `mariadb-dump` at :15, as a read-only `dump` user: one file per tenant database (`<db>.sql`, same `--single-transaction --skip-dump-date --hex-blob` and trailer check) into PVC `mariadb-dump` (seaweedfs: written once an hour as a whole file, so no chunk-list churn), VolSync at :30 to `volsync/database/mariadb-dump`, cache on seaweedfs-storage |
| Alerts | `MariaDBDown`, `MariaDBDumpFailed`, `MariaDBDumpStale`, `MariaDBDumpNeverSucceeded` in `database` (email); the Kimai dump alerts go away |
| Secrets | new `MariaDB Secrets` item: `root_password`, `dump_password`; tenant passwords stay in each app's item, projected into `database` by a OnePasswordItem (precedent: `homarr-db-password`) |
| Network | `allow-mariadb-consumers`: pods `app.kubernetes.io/name=mariadb` admit tenant namespaces (`kimai`) and Gatus (TCP check) on 3306 only |

Values (`services/mariadb/app/values.yaml`, abridged):

```yaml
mariadb:
  image: {repository: docker.io/library/mariadb, tag: "13.0.2"}
  storage: {size: 10Gi, storageClass: hcloud-volumes}
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {cpu: "1", memory: 1Gi}
  dump: {schedule: "15 * * * *", size: 1Gi}
  # One entry per app; consumers also go into allow-mariadb-consumers.
  tenants:
    - name: kimai            # database and user
      namespace: kimai       # admitted on 3306
      secret: kimai-db-password
      itemPath: "vaults/K3s Service Cluster/items/Kimai Secrets"
      key: mariadb-password
```

### Decision: plain StatefulSet or mariadb-operator

| | StatefulSet + provisioning Job (recommended) | mariadb-operator |
|---|---|---|
| Moving parts | what Kimai runs today, moved | operator, webhook, cert controller (wave 0) |
| Tenants | Job with SQL | `Database`/`User`/`Grant` CRs, like CNPG managed roles |
| Backups | dump CronJob + VolSync (proven here) | native logical backups to S3/B2 |
| HA | single instance (as today) | Galera/replication possible |
| Capacity | +0 (moves existing requests) | operator pods on an already overcommitted cluster |

Recommended: the StatefulSet now. It fixes the incident with known parts;
the operator can come later if a second tenant or HA justifies it.

### Quota (database namespace)

Used today: requests 1800m/3840Mi, limits 4500m/9Gi, 3 PVCs, 60Gi.
Adding the server (1 CPU limit), the dump Job (500m) and the VolSync mover
reaches or passes `limits.cpu: 6` and `persistentvolumeclaims: 5`
(data + dump + mover cache = 6). Raised to `limits.cpu: 8`,
`limits.memory: 14Gi`, `persistentvolumeclaims: 8`, `secrets: 30`; storage
stays under 100Gi (60 + 10 + 1 + 2).

### Kimai's `serverVersion`

`DATABASE_URL` derives it from the MariaDB tag in kimai's values, which
moves to the database chart. Kimai gets `db.serverVersion: "13.0.2-MariaDB"`
with a comment; Doctrine only uses it to pick the SQL platform, so a stale
patch level is harmless, but a major bump needs both charts.

## Steps

Every step is a git change Argo applies, except where marked **(human)**.

### 0. Preconditions

- SeaweedFS cleanup done: free volume slots, Kimai's MariaDB healthy, and
  the latest `kimai-mariadb-dump` succeeded (that file is the fallback).
- **(human)** Create `MariaDB Secrets` (Login) with `root_password` and
  `dump_password` (`openssl rand -hex 24` each; the provisioning Job
  rejects anything but `[A-Za-z0-9_]`).
- **(human)** New B2 key and `VolSync B2 mariadb-dump` item (AGENT.md
  procedure, prefix `volsync/database/`, repository
  `.../volsync/database/mariadb-dump`). Never reuse `kimai-db-dump`'s.

### 1. Stand up the shared server (no traffic)

`services/mariadb/app`: StatefulSet, Service, PVCs, provisioning Job
(PostSync hook), dump CronJob, VolSync, OnePasswordItems, NetworkPolicy,
PrometheusRule. Plus the quota bump in `services/database/app` and a Gatus
TCP check. Kimai still uses its own MariaDB.

Check: pod Ready on an hcloud volume (`/proc/mounts` shows ext4 from
`/dev/disk/by-id/scsi-0HC_Volume_*`, not `fuse.seaweedfs`); the Job created
`kimai` and user `kimai` (empty database); the first dump and VolSync run
succeed; from a kimai pod, `mariadb-admin ping -h mariadb.database` works
and from another namespace it times out.

### 2. Cutover (Kimai down for minutes)

1. Git: `kimai.replicas: 0` (new value, default 1). Sync; Kimai stops
   writing.
2. **(human)** Copy the database straight from the old server to the new
   one, then compare row counts per table:

   ```bash
   kubectl -n kimai exec kimai-mariadb-0 -- sh -c \
     'MYSQL_PWD=$MARIADB_PASSWORD mariadb-dump -u kimai \
      --single-transaction --hex-blob kimai' \
   | kubectl -n database exec -i mariadb-0 -- sh -c \
     'MYSQL_PWD=$MARIADB_ROOT_PASSWORD mariadb -u root kimai'
   ```

   Exact row-count commands go in a gitignored script at the time.
3. Git: point `DATABASE_URL` at `mariadb.database.svc.cluster.local`, set
   `serverVersion`, `kimai.replicas: 1`. Sync; log in and check recent
   timesheets.

Rollback until step 3 of the next section: revert the commit. The old
MariaDB and its data are untouched.

### 3. Remove the old server from the kimai chart

Delete `mariadb-statefulset.yaml`, `mariadb-dump-cronjob.yaml`, the
`kimai-mariadb` Service, the two MariaDB PVC manifests, the
`kimai-db-dump` VolSync entry and the dump alerts. `kimai-data` and its
backup stay. The PVCs carry `Delete=false`, so Argo leaves them behind.

### 4. Cleanup (destructive, separate confirmation)

After a week of clean dumps from the new server:

- **(human)** `kubectl -n kimai delete pvc kimai-mariadb-data kimai-db-dump`
  (frees their SeaweedFS collections).
- Decide on the old `volsync/kimai/kimai-db-dump` restic repo: keep until
  its retention expires (2 monthly, 1 yearly) or delete with its B2 key.
- Remove `mariadb-password`/`mariadb-root-password` duplicates: Kimai keeps
  `mariadb-password` (its tenant password); `mariadb-root-password` goes.

### 5. Docs

AGENT.md (structure, Storage: MariaDB joins CNPG on `hcloud-volumes`),
`docs/RUNBOOK-GITOPS.md` (vault table: `MariaDB Secrets`,
`VolSync B2 mariadb-dump`), `docs/RECOVERY-RUNBOOK.md` (restore MariaDB
from the per-tenant dump), `docs/todo.md`.

## Verification

| # | Test | Expected |
|---|---|---|
| 1 | MariaDB data mount | ext4 on a Hetzner volume |
| 2 | From `kimai`: `mariadb-admin ping -h mariadb.database` | alive |
| 3 | From any other namespace, connect to 3306 | times out |
| 4 | Row counts per table, old vs new | equal |
| 5 | Kimai login, recent timesheets, SAML | work |
| 6 | Dump Job | `kimai.sql` with trailer; VolSync uploads it |
| 7 | Restore the dump into a scratch database | loads cleanly |
| 8 | SeaweedFS metadata log over 24h | no MariaDB entries; growth is a small fraction of 10 GiB |

## Also needed (separate from this move)

- SeaweedFS metadata-log retention, and an alert on its size, so the next
  app that writes this way can't fill the store silently.
- Node-01 CPU: the Outline and Kimai VolSync movers are pinned there and
  don't fit (`Insufficient cpu`).
