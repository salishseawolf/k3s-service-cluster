# Plan: Outline wiki (`wiki.<domain>`), phase 1

## Overview

A shared, confidential knowledge base for people and AI agents, with
per-agent permissions over MCP. Outline replaces the OpenKnowledge idea:
OpenKnowledge has no accounts or permissions of its own (everyone who reaches
it is the same owner, and every MCP client gets every tool), while Outline
has real users, private collections, per-document access, and scoped API keys
that its MCP server enforces.

Status (2026-10-15): scaffolded in `services/outline/app/` and the
database, identity and gatus charts; not yet deployed.

Phase 1 exposes nothing new to the internet without an Authentik login,
except `/mcp` and `/api/` to two fixed IPs. Phase 2 (cloud connectors over OAuth) is a
separate decision, tracked in `docs/todo.md`.

## Facts this plan relies on (checked 2026-10-15)

- **Version:** `outlinewiki/outline:1.11.0` (2026-10-12), runs as uid 1001,
  health endpoint `/_health` returns `OK`. License BSL 1.1 (internal use
  allowed; changes to Apache 2.0 on 2030-10-12).
- **MCP** (`server/routes/mcp`, `server/mcp`): Streamable HTTP at `/mcp`,
  accepts API keys (`Authorization: Bearer`) and OAuth tokens. Tools are
  registered per token scope (`AuthenticationHelper.canAccess`), so a
  `read`-scoped key never sees `create`/`update`/`delete`/`move`. Every tool
  also checks the user's own document permissions. Rate limit: 1,000
  requests/hour per `/mcp`.
- **OAuth for MCP:** Outline is its own authorization server with open
  dynamic client registration (`/oauth/register`, 5/hour). The client picks
  the scope (`read write` advertised, no downscoping at consent).
  `OAUTH_DISABLE_DCR=true` turns registration off. Not used in phase 1.
- **OIDC sign-in:** with manual endpoints (`OIDC_AUTH_URI`, `OIDC_TOKEN_URI`,
  `OIDC_USERINFO_URI`) Outline does no issuer discovery, so the server-side
  calls can use Authentik's internal Service.
- **Advisories:** none open against 1.11.0. Four of the 2026 advisories hit
  the OAuth-scope and MCP code (CVE-2026-43886, CVE-2026-54573,
  GHSA-pp65-6cc2-4mx9, GHSA-c43v-wwv4-9mcc): the reason phase 1 keeps those
  paths off the internet. Watch https://github.com/outline/outline/security/advisories.

## Architecture

| Concern | Choice |
|---|---|
| Documents | CNPG `main-db`: role `outline_user`, database `outline`; covered by the existing barman backups |
| Attachments | `FILE_STORAGE=local`, PVC `outline-data` on `seaweedfs-storage` (10Gi), VolSync hourly to B2 |
| Redis | Dedicated, in-namespace: the shared Redis is `allkeys-lru` / 200 MB, which would silently evict Outline's queue jobs; changing it affects every app. `noeviction`, no persistence, own password |
| Browser | Authentik forward-auth on the host, then Outline's own OIDC login (Paperless pattern). MFA is enforced in Authentik |
| Agents | `/mcp` and `/api/` only, `ClientIP` allowlist (workstation + Hermes), no forward-auth; Outline API key per agent user |
| Egress | DNS, Postgres, own Redis, Authentik's internal Service. Nothing else |
| Monitoring | Gatus, PrometheusRule (`notify: email`), logs via Alloy to Loki |

## Steps

### 1. 1Password (human)

Create `Outline Secrets` in the `K3s Service Cluster` vault **before** any
`bootstrap/ansible` run: `bootstrap/ansible/mise.toml` now references it, and
`op run` fails on a missing item.

| Field | Value |
|---|---|
| `db_password` | `openssl rand -hex 24` (alphanumeric) |
| `secret_key` | `openssl rand -hex 32` |
| `utils_secret` | `openssl rand -hex 32` |
| `oidc_client` | random client ID (credential inversion: the Authentik blueprint and Outline both read it) |
| `oidc_secret` | `openssl rand -hex 32` |
| `redis_password` | `openssl rand -hex 24` |

Later, per agent: an item holding the agent user's Authentik password and
TOTP, and its Outline API key (Hermes' in the `Hermes Agent` vault).

### 2. Database

- `bootstrap/ansible/roles/secret_zero/defaults/main.yml` and
  `bootstrap/ansible/mise.toml`: `outline-db-user-auth` from
  `Outline Secrets/db_password` (done in this commit, same as the seven other
  CNPG users). Then `mise run //bootstrap/ansible:deploy` (idempotent; it
  creates only the new secret).
- `services/database`: managed role `outline_user` (`passwordSecret:
  outline-db-user-auth`), `Database` `outline`, and the `outline` namespace in
  the 5432 ingress rule.
- Confirm the next barman base backup completes with the new database.

### 3. Image and workload (`services/outline/app/`)

Standard scaffolding (AGENT.md "Service Scaffolding"): namespace (PSA
`restricted`), LimitRange, ResourceQuota, NetworkPolicies, OnePasswordItems
(`outline-secrets`), Deployment, Service, IngressRoutes, PVC with
`Prune=false,Delete=false`.

- **Outline Deployment:** 1 replica, `strategy: Recreate`, image pinned
  (Renovate bumps it). Requests 100m / 512Mi, limit 1.5Gi
  (`WEB_CONCURRENCY=1`; Outline sizes ~512 MiB per process). `runAsNonRoot`
  uid 1001, drop ALL, `RuntimeDefault` seccomp,
  `automountServiceAccountToken: false`, `readOnlyRootFilesystem` with an
  `emptyDir` at `/tmp` (verify). Probes on `/_health`.
- **Redis Deployment:** official image pinned to the same major as the shared
  Redis, 25m / 64Mi, `--maxmemory-policy noeviction --save "" --appendonly no
  --requirepass` from the secret, same hardening.
- **Environment:**

| Variable | Value | Why |
|---|---|---|
| `URL` | `https://wiki.<domain>` | |
| `PORT` | `3000` | |
| `SECRET_KEY`, `UTILS_SECRET` | from `outline-secrets` | |
| `DATABASE_URL` | `postgres://outline_user:$(DB_PASSWORD)@main-db-rw.database.svc.cluster.local:5432/outline` | |
| `PGSSLMODE` | `disable` | same as paperless; in-cluster |
| `DATABASE_CONNECTION_POOL_MAX` | `5` | |
| `REDIS_URL` | `redis://:$(REDIS_PASSWORD)@outline-redis:6379` | |
| `FILE_STORAGE` / `FILE_STORAGE_LOCAL_ROOT_DIR` | `local` / `/var/lib/outline/data` | the PVC |
| `FILE_STORAGE_UPLOAD_MAX_SIZE` | `100000000` | 100 MB per file (default 1 MB); imports inherit it; `/tmp` is 1Gi |
| `FORCE_HTTPS` | `false` | Traefik terminates TLS and redirects; on, it would redirect probes and Gatus |
| `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` | from `outline-secrets` | |
| `OIDC_AUTH_URI` | `https://auth.<domain>/application/o/authorize/` | browser-facing |
| `OIDC_TOKEN_URI` / `OIDC_USERINFO_URI` | `http://identity-authentik-server.identity.svc.cluster.local/application/o/token/` and `.../userinfo/` | server-side, stays in-cluster (verify) |
| `OIDC_LOGOUT_URI` | `https://auth.<domain>/application/o/outline/end-session/` | |
| `OIDC_DISPLAY_NAME` | `Authentik` | |
| `OAUTH_DISABLE_DCR` | `true` | phase 1: no OAuth client registration |
| `ENABLE_UPDATES` | `false` | otherwise sends anonymized stats to the maintainers |
| `DEBUG` | empty | no per-request logs: document URLs carry title slugs |
| `LOG_LEVEL` | `info` | |
| `RATE_LIMITER_ENABLED` | `true` | |

Deliberately unset: SMTP (no email), Sentry, Iframely, Slack, GitHub,
Notion, Linear, Figma, Dropbox, S3.

### 4. Authentik (`services/identity/app/templates/configmap-blueprints.yaml`)

- **OIDC provider + application `outline`** (copy of the Paperless
  blueprint): confidential client, `!Env` client ID/secret from
  `outline-secrets` (add the env vars to `services/identity/app/values.yaml`
  and an `outline-oidc-creds` OnePasswordItem in `identity`), strict redirect
  URI `https://wiki.<domain>/auth/oidc.callback`, scopes openid/profile/email.
  Bind to `internal` and a new `wiki-agents` group.
- **Forward-auth proxy provider + application** for `https://wiki.<domain>`,
  added to the embedded outpost's providers list (restate the whole list: it
  is replaced, not merged). Bind to `internal` and `wiki-agents`.
- `identity` NetworkPolicy: admit the `outline` namespace to the
  authentik-server pods (token/userinfo calls).

### 5. Routes (perimeter change, approved 2026-10-15)

- `Host(wiki.<domain>)`: `authentik-forward-auth` (namespace `identity`),
  Outline Service port 3000. Covers the editor, the realtime WebSocket,
  `/oauth/*`, and `/api/` from anywhere outside the allowlist.
- `Host(wiki.<domain>) && (PathPrefix(/mcp) || PathPrefix(/api/))`, higher
  priority: `ClientIP`
  allowlist, no forward-auth; Outline checks the `Authorization` header
  itself. Allowlist:
  - `73.97.54.81/32` (workstation, already in `adminSourceRanges`)
  - `46.62.156.134/32` (Hermes on Hetzner): `/mcp` and `/api/` only, **not** added to
    `adminSourceRanges`
  Kept in `services/outline/app/values.yaml` as `mcpSourceRanges`.
- `/api/` added 2026-10-16 (approved): MCP tools carry text only, so binary
  uploads (PDFs) need the REST API (`attachments.create`, then
  `files.create`). The same API key and scope apply; `files.create` accepts
  only a signed upload or an attachment key owned by the caller.
- No other path bypasses forward-auth. `/.well-known/oauth-*`,
  `/oauth/token`, `/oauth/register`, `/oauth/revoke` stay gated (phase 2).

### 6. NetworkPolicies

- **Ingress, Outline pod:** `traefikSources` (private net + each node's
  flannel `/31`, the copyparty pattern, so other pods cannot skip auth) and
  the `gatus` namespace, port 3000.
- **Ingress, Redis pod:** only the Outline pod, 6379.
- **Egress, namespace-wide:** kube-system DNS (53/UDP+TCP); `database` 5432;
  `identity` authentik-server; in-namespace Redis 6379. Everything else
  denied: blocks the update ping, server-side fetches of external images and
  URLs, and exfiltration from a compromised pod.

### 7. Backups and recovery

- `ReplicationSource` for `outline-data`, copied from
  `services/paperless/app/templates/09-volsync.yaml` (hourly at :20,
  same retention, cache on `seaweedfs-storage`, `moverSecurityContext` with
  `runAsNonRoot` + `RuntimeDefault`).
- **Human step:** scoped B2 key `VolSync-outline-data` with
  `--name-prefix volsync/outline/` and the `VolSync B2 outline-data` item,
  per AGENT.md "VolSync B2 credentials".
- `docs/RECOVERY-RUNBOOK.md`: Outline section. Restore the database (barman)
  and `outline-data` (VolSync) to matching points in time, then start
  Outline; the Redis is disposable.

### 8. Monitoring and alerting

- **Gatus:** `http://outline.outline.svc.cluster.local:3000/_health` with
  `Host: wiki.<domain>`, `[BODY] == OK`; TCP check on `outline-redis:6379`.
- **PrometheusRule `outline`** (`release: monitoring`, `notify: email`,
  kimai pattern): `OutlineDown` (no available replicas 5m),
  `OutlineCrashLooping` (>3 restarts in 15m), `OutlineRedisDown`. No
  volume-filling alert: `kubelet_volume_stats` has no SeaweedFS volumes
  (checked 2026-10-15), so the SeaweedFS alerts cover disk space.
  Backups are already covered by `VolSyncBackupStuck` /
  `VolSyncBackupOutOfSync`; the database by the CNPG rules.
- **Logs:** Alloy already ships pod logs to Loki.
- Outline exposes no Prometheus metrics endpoint.
- Homarr tile: added in Homarr's UI (its config lives in its database).

### 9. Workspace setup after first login (human)

1. Sign in first (first user becomes admin).
2. Settings: disable public document sharing; default role for new users
   **Viewer**; OIDC the only sign-in method; enable MCP (Workspace → AI).
3. Create confidential collections as **private**.

### 10. Agents

1. Authentik user per agent (e.g. `agent-hermes`) in `wiki-agents`, password
   and TOTP in 1Password.
2. Sign in once as the agent (private window) to create its Outline user
   (Viewer).
3. Grant access per collection or document: Hermes **View and edit** on its
   collections; read-only agents **View**, or **Guest** for explicit shares
   only.
4. Signed in as the agent, create its API key: Hermes `read write`,
   read-only agents `read`; set an expiry; store it in 1Password.
5. Disable the agent's Authentik password. Its API key keeps working; nobody
   can sign in as it.
6. Revoke in Outline (delete the key or suspend the user); Authentik does not
   see API keys.

Client config (Claude Code example):

```bash
claude mcp add --transport http outline \
  https://wiki.<domain>/mcp \
  --header "Authorization: Bearer <key>"
```

### 11. Docs

- AGENT.md: repository structure; Perimeter table (`/mcp` with
  `mcpSourceRanges`, Outline API keys).
- `docs/RUNBOOK-GITOPS.md`: vault items (`Outline Secrets`,
  `VolSync B2 outline-data`), agent onboarding (step 10).

## Verification (before any confidential content)

| # | Test | Expected |
|---|---|---|
| 1 | `curl -I https://wiki.<domain>/` without a session | 302 to `auth.` |
| 2 | First login via Authentik (MFA) | Outline user created, admin |
| 3 | `curl -I https://wiki.<domain>/oauth/token` and `/.well-known/oauth-authorization-server` | 302 to `auth.` (gated) |
| 4 | `/mcp` from an IP outside `mcpSourceRanges` | 302 to `auth.` (falls through to the forward-auth route) |
| 5 | `/mcp` from the workstation with no key / a wrong key | 401 from Outline |
| 5a | `/api/` from outside `mcpSourceRanges`; from the workstation with no key | 302 to `auth.`; 401 from Outline |
| 6 | Read-only key: `tools/list` | no create/update/delete/move tools |
| 7 | Read-only agent: search for a document in a collection it isn't in | not returned |
| 8 | Hermes key: edit inside its collection, then outside | allowed / refused |
| 9 | Can a Viewer/Guest agent create its own API key? | decides step 10.4 |
| 10 | From the Outline pod, `wget` an external site | fails |
| 11 | From another namespace, connect to `outline:3000` and `outline-redis:6379` | times out |
| 12 | OIDC login works with internal token/userinfo URIs | yes (else switch to the public URIs plus LB egress) |
| 13 | VolSync first sync; restore to a scratch PVC | data matches |
| 14 | Barman base backup after creation | includes `outline` |

Tests 6-8 prove the reason for choosing Outline. If any fails, stop before
importing content.

## Capacity

Outline 100m / 512Mi request (1.5Gi limit) plus Redis 25m / 64Mi. Every node
had at least ~1.3 CPU and ~1.9 GiB unreserved after the 2026-10-15
capacity changes.
