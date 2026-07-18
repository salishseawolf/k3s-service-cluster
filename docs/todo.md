# Infrastructure Review — Todo

## Resolved This Session
- [x] Argo CD Authentik SSO
- [x] Homarr OIDC (seed Job creates infrastructure group with admin perms)
- [x] Homarr init-nginx crash-loop (FOWNER + DAC_OVERRIDE caps)
- [x] CNPG B2 backups (new B2 keys; WAL archiving + manual backup confirmed)
- [x] Velero B2 backups (new keys; backup completed 976/976 items)
- [x] Database quota bumped for 3 CNPG instances (6/12Gi)
- [x] Database PDB (removed custom; CNPG manages own)
- [x] Paperless env var ordering + email verification + local login + OIDC
- [x] SeaweedFS backup infra removed (defunct Hetzner Storage Box)
- [x] vendor charts gitignored

## Pending Verification (on next fresh deploy)
- [ ] Gitea OIDC resolves with production LE cert
- [ ] Database syncs cleanly with managed roles + quota

## Diagnose
- [ ] Gitea SSH connections failing

## Minor
- [ ] m1: Inconsistent namespace name quoting
- [ ] m6: Poorly named paperless deployment files
- [ ] m7: Share IngressRoute auth bypass undocumented

## Suggestions
- [ ] S2: Add egress NetworkPolicy restrictions where safe
- [ ] S5: Consider cluster monitoring
