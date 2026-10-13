# Monitoring Stack — Baseline Deployment Plan

## Overview

Deploy a unified monitoring stack in the `monitoring` namespace covering metrics
(Prometheus), logs (Loki + Alloy), and visualization (Grafana). All three share
a single namespace with Authentik forward-auth for Grafana.

## Namespace

- **Name:** `monitoring`
- **PSA:** `baseline` (node-exporter and Alloy need host access)
- **NetworkPolicy:** default-deny ingress + egress; allow:
  - Prometheus → kubelet (egress to 192.168.0.0/16 port 10250)
  - Prometheus → intra-namespace scrape targets
  - Alloy → access to node logs (host bind mounts)
  - Grafana → ingress from Traefik (port 3000)
- **ResourceQuota + LimitRange** per existing service convention

## Blockers (resolved)

### Blocker 1: ArgoCD Project Scope
kube-prometheus-stack deploys CRDs, ClusterRoles, and admission webhooks —
the `services` project does not allow cluster-scoped resources. Split into two:

- `platform/monitoring-crd/` — Prometheus operator CRDs under `platform` project
- `services/monitoring/app/` — workloads under `services` project (namespace-scoped only)
  - `prometheusOperator.createCustomResource: false` in Helm values
  - CRDs managed by the platform app, installed first

### Blocker 2: Storage Class
Prometheus TSDB is write-heavy (WAL + compactions). SeaweedFS (network-attached
FUSE) adds latency risk for WAL fsyncs. Mitigations:
- Increase scrape interval to 60s (reduces write pressure)
- Set size-based retention cap (45Gi) as safety valve
- Monitor `prometheus_tsdb_wal_fsync_duration_seconds` after deploy

**Superseded 2026-10-13:** Prometheus's SeaweedFS FUSE client grew to 4.2 GB and
OOM-starved node-02 (`docs/RCA-2026-10-SEAWEEDFS.md`). Monitoring no longer
depends on SeaweedFS: Loki uses a Hetzner volume, Prometheus and Alertmanager a
capped `emptyDir` (history resets on pod restart, by choice).

## Component Breakdown

### 0. Platform CRD App (`platform/monitoring-crd/`)

| Chart | Purpose |
|-------|---------|
| `prometheus-community/kube-prometheus-stack` (CRDs only) | ServiceMonitor, PodMonitor, PrometheusRule, Prometheus, Alertmanager CRDs |

- `prometheusOperator.createCustomResource: true` (default, but only CRDs)
- `prometheusOperator.createValidatingWebhook: false` (optional, reduces RBAC needs)
- No deployments, no services — just CRDs and cluster-scoped RBAC

### 1. kube-prometheus-stack (Prometheus + Grafana + Alertmanager)

| Sub-component | Purpose |
|---------------|---------|
| Prometheus | Metrics collection, 7d / 8 GiB retention, `emptyDir` (10Gi cap), no PVC |
| Grafana | Visualization, datasources + dashboards pre-provisioned via ConfigMap, admin password via 1Password Operator |
| Alertmanager | Alert routing (`notify: email` alerts to email, rest to null), `emptyDir` (1Gi cap), no PVC |
| kube-state-metrics | Cluster resource metrics |
| node-exporter | Node-level metrics (DaemonSet) |

- **Chart:** `prometheus-community/kube-prometheus-stack` (pinned version TBD)
- **CRDs disabled** (managed by platform app): `prometheusOperator.createCustomResource: false`
- **Storage:** no PVCs (2026-10-13)
  - Prometheus: `emptyDir` with `sizeLimit: 10Gi`; metrics history resets when the pod restarts
  - Alertmanager: `emptyDir` with `sizeLimit: 1Gi`; silences and the notification log reset on restart
- **Retention:** 7d + size-based cap 8GiB, well under the emptyDir cap (the
  kubelet evicts the pod, not the node, if it is exceeded)
- **Scrape interval:** 60s (4× Prometheus default; chosen when the TSDB was on SeaweedFS, kept to bound emptyDir growth)
- **External labels:** `cluster: salishseawolf`, `environment: production`
- **PSP/PodMonitor:** enable PodMonitor for CNPG's existing `enablePodMonitor: true`
- **Grafana:**
  - Admin password from 1Password Operator
  - Ingress disabled (use Traefik IngressRoute)
  - Datasources pre-configured: Prometheus + Loki
  - Dashboards provisioned via ConfigMap sidecar (node overview, pod resources, Loki logs)
  - Authentik OIDC for user auth (future: disable admin account)

### 2. Loki (log aggregation)

- **Chart:** `grafana/loki` or `grafana/loki-simple-scalable` (pinned version, matching Alloy's API version)
- **Mode:** Single binary (sufficient for 3 nodes)
- **Storage:** PVC: `10Gi hcloud-volumes` (Hetzner volume; on SeaweedFS until 2026-10-13)
- **Retention:** 180d
  - `limits_config.retention_period: 4320h`
  - `max_entries_limit_per_query: 5000`
- **Sizing note:** 10Gi for 180d of logs on 3 nodes is tight — monitor `loki_pvc_disk_space_used_bytes` after deploy and resize if needed (hcloud-volumes supports online expansion)
- **PVC annotation:** `argocd.argoproj.io/sync-options: Prune=false,Delete=false`

### 3. Alloy (log shipping — replaces promtail)

- **Chart:** `grafana/alloy` (pinned version)
- **Config:** Alloy config via ConfigMap, point at Loki endpoint
- **Mode:** DaemonSet, reads `/var/log/pods/` and `/var/log/containers/` via host bind mounts
- **PSA:** baseline (host path access required)

## Networking

| Service | Port | Protocol | Exposed via |
|---------|------|----------|-------------|
| Grafana | 3000 | HTTP | Traefik IngressRoute (monitor.salishseawolf.com) |
| Prometheus | 9090 | HTTP | ClusterIP only |
| Alertmanager | 9093 | HTTP | ClusterIP only |
| Loki | 3100 | HTTP | ClusterIP only |
| Alloy | 12345 | HTTP (debug/UI) | ClusterIP only |

## IngressRoute

- **Host:** `monitor.salishseawolf.com`
- **Middleware:** Authentik forward-auth (existing pattern)
- **Service:** Grafana on port 3000
- **TLS:** cert-manager wildcard certificate

## 1Password Items

| Item | Fields | Purpose |
|------|--------|---------|
| `Grafana Admin Password` | `password` | Grafana admin login |
| `VolSync B2 loki-data` | `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Loki index + chunks backup (B2 key scoped to `volsync/monitoring/`) |

The `prometheus-main-db` and `alertmanager-db` items, B2 repos and backups were
retired on 2026-10-13 when both moved to `emptyDir`.

## PVC Summary

| PVC | Size | StorageClass | Component | Prune annotation | Backup |
|-----|------|-------------|-----------|-----------------|--------|
| `storage-monitoring-loki-0` (`loki-data`) | 10Gi | hcloud-volumes | Loki index + chunks | ✅ | VolSync hourly |

Prometheus and Alertmanager have no PVC (`emptyDir`, see above).

## Files to Create

| File | Purpose |
|------|---------|
| `platform/monitoring-crd/Chart.yaml` | CRD-only platform chart |
| `platform/monitoring-crd/values.yaml` | CRD install values |
| `services/monitoring/app/Chart.yaml` | Helm chart definition |
| `services/monitoring/app/values.yaml` | All values for kube-prometheus-stack, Loki, Alloy |
| `services/monitoring/app/templates/namespace.yaml` | Namespace + PSA labels + annotations |
| `services/monitoring/app/templates/networkpolicy.yaml` | Default-deny ingress + egress |
| `services/monitoring/app/templates/ingressroute.yaml` | Traefik IngressRoute for Grafana |
| `services/monitoring/app/templates/onepassworditems.yaml` | Grafana admin password secret |
| `services/monitoring/app/templates/resourcequota.yaml` | Resource limits per existing convention |
| `services/monitoring/app/templates/limitrange.yaml` | Pod resource bounds per existing convention |
| `services/monitoring/app/templates/volsync.yaml` | VolSync ReplicationSource + OnePasswordItem per PVC |

## Deployment Order

1. `platform/monitoring-crd/` — Prometheus operator CRDs (Argo wave 0)
2. Namespace + PSA + NetworkPolicy + ResourceQuota + LimitRange (Argo wave 1)
3. kube-prometheus-stack (Prometheus + Grafana + Alertmanager + ksm + node-exporter) (Argo wave 10+)
4. Loki (Argo wave 10+)
5. Alloy — needs Loki endpoint to exist (Argo wave 10+)
6. IngressRoute + 1Password items (Argo wave 10+)

## PVC Backups (VolSync Restic)

Only Loki's PVC is backed up, via VolSync restic to B2, following the same
pattern as app PVCs:

| PVC | Schedule | Repo path |
|-----|----------|-----------|
| `loki-data` | Hourly at :35 | `s3:https://s3.us-west-004.backblazeb2.com/k3s-service-cluster/volsync/monitoring/loki-data` |

The B2 application key is scoped to `volsync/monitoring/`. Retention: daily:30
(matching app PVCs). The mover's restic cache is on `seaweedfs-storage`, so a
SeaweedFS outage delays Loki's backups but not Loki itself. Failures email via
`VolSyncBackupStuck` / `VolSyncBackupOutOfSync` (platform/volsync).

Prometheus and Alertmanager were backed up the same way until 2026-10-13. With
`emptyDir` there is nothing to back up; their repos (Prometheus's had grown to
547.6 GB, as each of 30 daily snapshots of a high-churn TSDB was largely
unique) were deleted.

Grafana dashboards are provisioned via ConfigMap (in git) — no backup needed.
Any UI-created dashboards would be lost on PVC failure.

## Future Integration (out of scope)

- Blackbox exporter for external endpoint monitoring
- Thanos + B2 for long-term metric storage
- Alertmanager receivers (email, Slack, etc.)
- Gatus → Prometheus blackbox migration
- CNPG, VolSync, ArgoCD metrics scraping
- Authentik OIDC for Grafana (disable admin account after)
