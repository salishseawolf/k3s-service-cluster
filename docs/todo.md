# Infrastructure Review — Todo

## Active Issues
- [ ] **B2: CNPG database backups failing (AccessDenied)**
  Barman-cloud WAL archive and scheduled backups fail with
  `AccessDenied` on `ListObjectsV2`. The B2 API key in
  `BackBlaze CNPG B2 Bucket` vault item lacks bucket read permission.
  Fix: update B2 key permissions, or create a new application key
  with read+write access to the `k3s-service-cluster` bucket.

- [ ] **Homarr OIDC: Policy binding still failing**
  `!Find [authentik_core.group, [name, infrastructure]]` fix applied
  but user still sees "Policy binding 'None'". May be Authentik
  upstream race condition (self-heals within 60 min) or deeper issue.

- [ ] **Paperless OIDC: Still showing setup wizard**
  Env var ordering fixed (PAPERLESS_OIDC_CLIENT/SECRET before
  SOCIALACCOUNT_PROVIDERS) but user still sees setup wizard.

## Minor
- [ ] **m1: Inconsistent namespace name quoting**
- [ ] **m6: Poorly named paperless deployment files**
- [ ] **m7: Share IngressRoute auth bypass undocumented**

## Suggestions
- [ ] **S1: Add PodDisruptionBudget for CNPG database cluster**
- [ ] **S2: Add egress NetworkPolicy restrictions where safe**
- [ ] **S3: Add ResourceQuota + LimitRange to service namespaces**
- [ ] **S5: Consider cluster monitoring**

## Pending Verification (on next fresh deploy)
- [ ] Gitea OIDC resolves with production LE cert
