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
| Prometheus | Metrics collection, 30d retention, PVC: `50Gi seaweedfs-storage` |
| Grafana | Visualization, datasources + dashboards pre-provisioned via ConfigMap, admin password via 1Password Operator |
| Alertmanager | Alert routing (default: noop), PVC: `10Gi seaweedfs-storage` for persistence |
| kube-state-metrics | Cluster resource metrics |
| node-exporter | Node-level metrics (DaemonSet) |

- **Chart:** `prometheus-community/kube-prometheus-stack` (pinned version TBD)
- **CRDs disabled** (managed by platform app): `prometheusOperator.createCustomResource: false`
- **Storage:**
  - Prometheus: `50Gi seaweedfs-storage`
  - Alertmanager: `10Gi seaweedfs-storage` (saved silences/state)
- **Retention:** time-based 30d + size-based cap 45Gi
- **Scrape interval:** 60s (4× Prometheus default; gentler on SeaweedFS-backed workloads)
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
- **Storage:** PVC: `10Gi seaweedfs-storage`
- **Retention:** 180d
  - `limits_config.retention_period: 4320h`
  - `max_entries_limit_per_query: 5000`
- **Sizing note:** 10Gi for 180d of logs on 3 nodes is tight — monitor `loki_pvc_disk_space_used_bytes` after deploy and resize if needed (seaweedfs supports online expansion)
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
| `VolSync B2 prometheus-main-db` | `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Prometheus TSDB backup (shares B2 key with other monitoring PVCs) |
| `VolSync B2 alertmanager-db` | `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Alertmanager state backup (shares B2 key) |
| `VolSync B2 loki-data` | `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Loki index + chunks backup (shares B2 key) |

## PVC Summary

| PVC | Size | StorageClass | Component | Prune annotation | Backup |
|-----|------|-------------|-----------|-----------------|--------|
| `prometheus-main-db` | 50Gi | seaweedfs-storage | Prometheus TSDB | ✅ | VolSync hourly |
| `alertmanager-db` | 10Gi | seaweedfs-storage | Alertmanager state | ✅ | VolSync hourly |
| `loki-data` | 10Gi | seaweedfs-storage | Loki index + chunks | ✅ | VolSync hourly |

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

All 3 monitoring PVCs are backed up via VolSync restic to B2, following the
same pattern as app PVCs:

| PVC | Schedule | Repo path |
|-----|----------|-----------|
| `prometheus-main-db` | Hourly at :05 | `s3:https://s3.us-west-004.backblazeb2.com/k3s-service-cluster/volsync/monitoring/prometheus-main-db` |
| `alertmanager-db` | Hourly at :20 | `s3:https://s3.us-west-004.backblazeb2.com/k3s-service-cluster/volsync/monitoring/alertmanager-db` |
| `loki-data` | Hourly at :35 | `s3:https://s3.us-west-004.backblazeb2.com/k3s-service-cluster/volsync/monitoring/loki-data` |

Each PVC gets its own restic repository (separate `RESTIC_REPOSITORY` path, separate
1Password item). The B2 application key is shared — one key scoped to
`volsync/monitoring/` covering all 3 PVCs. Staggered schedules (:05, :20, :35)
so movers don't all hit SeaweedFS/B2 simultaneously. Retention: daily:30
(matching app PVCs).

Grafana dashboards are provisioned via ConfigMap (in git) — no backup needed.
Any UI-created dashboards would be lost on PVC failure.

## Future Integration (out of scope)

- Blackbox exporter for external endpoint monitoring
- Thanos + B2 for long-term metric storage
- Alertmanager receivers (email, Slack, etc.)
- Gatus → Prometheus blackbox migration
- CNPG, VolSync, ArgoCD metrics scraping
- Authentik OIDC for Grafana (disable admin account after)
