# Infrastructure Review — Todo

## Critical

- [ ] **C1: Paperless uses wrong invalidation flow slug**
  `services/identity/app/templates/configmap-blueprints.yaml:733`
  References `default-invalidation-flow` — should be `default-provider-invalidation-flow`

- [ ] **C2: Gatus DB connection string uses literal `***`**
  `services/gatus/app/templates/configmap.yaml:13`
  Password env var (`DATABASE_PASSWORD`) is injected but never read by storage config

- [ ] **C3: cert-manager namespace has no PSA labels**
  `platform/cert-manager/crd/templates/helmchart.yaml`
  HelmChart `createNamespace: true` creates namespace without labels

- [ ] **C4: cnpg-system namespace has no PSA labels**
  `platform/argocd/root/apps/cnpg-operator.yaml`
  `CreateNamespace=true` with no way to label the ns

## Major

- [ ] **M1: Paperless uses `:latest` image tags**
  `services/paperless/app/templates/50-deployment.yaml` (paperless),
  `50-deployment-2.yaml` (tika), `50-deployment-3.yaml` (gotenberg)

- [ ] **M2: CNPG ScheduledBackup references disabled plugin**
  `services/database/app/templates/scheduledbackup.yaml`
  Plugin config is commented out in cluster.yaml but ScheduledBackup still references it

- [ ] **M3: copyparty namespace missing PSA audit/warn labels**
  `services/copyparty/app/templates/01-namespace-copyparty_namespace.yaml`

- [ ] **M4: Stale completion message in Ansible main playbook**
  `bootstrap/ansible/playbooks/main.yml:80-81`
  Still references old `cert-manager:apply` step

- [ ] **M5: Multiple namespaces missing `managed-by: argocd` label**
  copyparty, homarr, paperless, gitea-actions, seaweedfs, seaweedfs-csi

- [ ] **M6: cert-manager config chart has no Namespace template**
  `platform/cert-manager/config/` — relies on CRD chart's HelmChart for ns creation

## Minor

- [ ] **m1: Inconsistent namespace name quoting**
  Some use `'namespace'` (quoted), some use bare `namespace`

- [ ] **m2: Unpinned sidecar images**
  `bitnami/kubectl:latest` (backup cronjob), `python:3.11-slim` (backup-check),
  `busybox` (homarr init)

- [ ] **m3: Empty values.yaml stubs lack domain injection comment**
  copyparty, gitea-actions, homarr, paperless, seaweedfs-csi values.yaml

- [ ] **m4: Gitea values.yaml references disabled valkey-cluster subchart**
  `services/gitea/app/values.yaml:31` — dead config

- [ ] **m5: Stale identity certificate placeholder template**
  `services/identity/app/templates/certificate.yaml` — empty comment file

- [ ] **m6: Poorly named paperless deployment files**
  `50-deployment.yaml`, `50-deployment-2.yaml`, `50-deployment-3.yaml`

- [ ] **m7: Share IngressRoute auth bypass undocumented**
  `services/copyparty/app/templates/12-ingressroute-copyparty-share.yaml`

## Suggestions

- [ ] **S1: Add PodDisruptionBudget for CNPG database cluster**
- [ ] **S2: Add egress NetworkPolicy restrictions where safe**
- [ ] **S3: Add ResourceQuota + LimitRange to service namespaces**
- [ ] **S4: Standardize or remove certificate.yaml comment file**
- [ ] **S5: Consider cluster monitoring (node-exporter, Prometheus, Grafana)**

## Previously Tracked

- [ ] Debug Gitea deployment issue (staging cert / LE production switch)
- [ ] Switch to production LE issuer + remove insecureSkipVerify
- [ ] Gatus: Slack notification integration
- [ ] SeaweedFS backup-check (expected 503 until first backup)
