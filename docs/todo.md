# Infrastructure Review — Todo

## Minor
- [ ] **m1: Inconsistent namespace name quoting**
  Some use `'namespace'` (quoted), some use bare `namespace`
- [ ] **m2: Unpinned sidecar images**
  `bitnami/kubectl:latest` (backup cronjob), `python:3.11-slim` (backup-check),
  `busybox` (homarr init)
- [ ] **m3: Empty values.yaml stubs lack domain injection comment**
  copyparty, gitea-actions, homarr, paperless, seaweedfs-csi values.yaml
- [ ] **m4: Gitea values.yaml references disabled valkey-cluster subchart**
- [ ] **m5: Stale identity certificate placeholder template**
  `services/identity/app/templates/certificate.yaml`
- [ ] **m6: Poorly named paperless deployment files**
- [ ] **m7: Share IngressRoute auth bypass undocumented**

## Suggestions
- [ ] **S1: Add PodDisruptionBudget for CNPG database cluster**
- [ ] **S2: Add egress NetworkPolicy restrictions where safe**
- [ ] **S3: Add ResourceQuota + LimitRange to service namespaces**
- [ ] **S4: Standardize or remove certificate.yaml comment file**
- [ ] **S5: Consider cluster monitoring (node-exporter, Prometheus, Grafana)**

## Pending Verification (on next fresh deploy)
- [ ] Argo CD Authentik SSO
- [ ] CNPG B2 backup (ObjectStore CRD + plugin-barman-cloud)
- [ ] Gitea OIDC resolves with production LE cert
- [ ] Database app syncs cleanly with managed roles
