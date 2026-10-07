# Salish Sea Wolf LLC — Cluster Hardening & Restructuring Plan

Context: 3-node K3s HA cluster on Hetzner, inherited from your own hobby project (blackviolet.bid). Snipe-IT and Outline have been removed. Ports 80/443 remain admin-CIDR-only until go-live. Goal: internal tooling plus limited, controlled client-facing services, with per-service CI/CD granularity and without security overkill.

The two plans interleave deliberately. Hardening Phase H1 and Restructuring Phase R1–R2 happen behind the firewall in either order; H2 items ride along with the GitOps restructure (R3) because they become per-service conventions; H3 is the go-live gate.

---

## Part 1 — Hardening Plan

Design principle: enforce at two layers only — the CNI (NetworkPolicies) and the identity layer (Authentik policies). Skip node-level firewalld granularity, WAFs, service meshes, and blanket egress lockdown. At this scale they add fragility faster than they add safety.

### Phase H1 — Now, behind the admin firewall

**H1.1 — Password Redis.**
Set `requirepass` from a 1Password-sourced secret; update consumers (Authentik session store, Gitea cache, Paperless if it uses it). Auth on the shared session store must not depend on the network layer being correct. ~1 hour.

**H1.2 — Verify NetworkPolicy enforcement actually works.**
K3s bundles kube-router as its policy enforcer, but if the Ansible role passes `--disable-network-policy`, every policy you write later is silently inert. Check the k3s server flags in the Ansible role, then verify empirically: apply a deny-all policy to a scratch namespace, exec into a test pod, confirm traffic is dropped, delete the scratch namespace. 30 minutes, and it de-risks all of Phase H2.

**H1.3 — Confirm ProxyProtocol / real client IPs end-to-end.**
Rate limiting and any future IP-based rules at Traefik are useless if Traefik sees the LB's IP instead of the client's. Verify a request's source IP survives LB → Traefik → app while you can still test calmly. Matters before H3.2.

### Phase H2 — Foundation (do inside the restructure, R3)

These become part of each service's manifest directory so new services inherit them by convention, not memory.

**H2.1 — Default-deny NetworkPolicies, datastores first.**
Order of rollout:

1. `database` and `redis` namespaces: default-deny ingress, then allow only from labeled consumer namespaces (identity, gitea, paperless, homarr as applicable). Clearest consumer lists, highest-value targets, easiest policies to reason about.
2. App namespaces: default-deny ingress, allow from Traefik. **Caveat:** Traefik runs as a hostNetwork DaemonSet, so ingress-allow rules must match node/host IPs (ipBlock on the node subnet), not a pod selector. Test the pattern on one namespace before templating it across all of them.
3. Egress: only where it's cheap and high-value. Do not attempt cluster-wide egress deny — DNS, Authentik callbacks, B2 backups, image pulls, and Resend SMTP all need holes and you'll fight it forever.

**H2.2 — Strict egress policy on gitea-actions.**
The CI runner executes semi-arbitrary code in a privileged namespace. Post-Snipe-IT, it's your worst exposure. Allow: DNS, Gitea's service, image registries you actually use, and whatever your workflows genuinely fetch. Deny the rest, including the datastore namespaces. This is the one namespace where egress control pays for itself.

**H2.3 — Standardize the ingress auth pattern to two tiers.**
- **Forward-auth middleware (auth before the app sees a byte):** Traefik dashboard, Homarr, Gatus — and consider Paperless, since document management is internal-only. Existing proxy outposts (Copyparty, SeaweedFS filer) already achieve the same property; leave them.
- **App-handled OIDC:** Gitea only, since it needs app-level permissions and client-scoped access.

This collapses the current three-tier inconsistency and puts an Authentik checkpoint in front of everything internal.

**H2.4 — Authentik group model = the tenancy boundary.**
Create groups now, while empty: `internal`, and a `client-<name>` pattern. Bind Authentik application policies so internal tools require `internal`, and client-facing apps allow specific client groups. This — not network segmentation — is your internal/external separation mechanism, enforced at the forward-auth/OIDC layer. Cheap to set up, expensive to retrofit.

### Phase H3 — Go-live gate (before opening 80/443 to the world)

**H3.1 — Backup story proven, not just deployed.**
VolSync restic backups landing in B2, CNPG Barman backups landing in B2, and one actual CNPG restore drill into a scratch namespace. A backup that's never been restored is a hypothesis. Add Gatus checks for both backup paths so silent failure is impossible.

**H3.2 — Rate limit the Authentik login route.**
Traefik's rateLimit middleware on `auth.<domain>` endpoints. The single endpoint worth brute-force protection; five lines of YAML.

**H3.3 — Decide on Cloudflare proxying (orange-cloud).**
Optional. You already use Cloudflare DNS; proxying gets you free WAF/DDoS at the cost of Cloudflare terminating TLS and needing origin certs. Reasonable to skip at this scale — just decide deliberately and note the decision.

**H3.4 — Final sweep.**
No IngressRoute without an auth story (grep for routes missing middleware or app auth); no namespace without a NetworkPolicy; Redis auth confirmed; kube-linter clean in CI.

### Explicitly not doing (and why)

- **Granular firewalld inside the private network** — duplicates CNI-layer policy at node level; they will drift; near-zero added safety once NetworkPolicies enforce.
- **Full WAF / mod-security** — overkill for this scale; Cloudflare proxying is the escape hatch if ever needed.
- **Cluster-wide egress deny** — high maintenance, moderate payoff; egress control only on gitea-actions.
- **Tightening privileged PSA namespaces** — seaweedfs-csi and gitea-actions genuinely need privilege; contain them with network policy instead.
- **Service mesh / mTLS** — three nodes, one operator; not the right tax bracket.

---

## Part 2 — Restructuring Plan

Design principle: keep the monorepo; change who deploys. Ansible/mise shrinks to bootstrap; Argo CD reconciles services per-path. Independence is measured as "change and roll Gitea without touching or risking Authentik," not "deploy Gitea with no Authentik existing."

### Phase R1 — Hygiene (unblocks everything else)

**R1.1 — Resolve the 48 staged files.**
Commit real work as logical commits: snipeit removal fallout, Velero, CNPG Barman/B2, Authentik LDAP outpost, outpost host fixes. Move the planning markdowns (BACKUP_PLAN_v2.3_FINAL.md and friends) out of the repo root — with Outline gone, either a `docs/` directory with an explicit convention, or the Gitea wiki once the cluster is stable.

**R1.2 — Fix the deploy-chain syntax bug** (the quoted trailing comma from the snipeit entry — verify it went away cleanly with the service removal). The chain must work until Argo replaces it.

**R1.3 — Normalize inventory.**
Kill the five copied `hcloud.yml` files (database, developer-tooling, identity, seaweedfs, gatus). Either symlink like the newer services or, better, point all service Ansible at the single platform inventory via `ansible.cfg`. Copied inventories are silent drift bombs.

**R1.4 — Remove Snipe-IT/Outline residue.**
Root mise task chains, Authentik blueprints/applications, DNS assumptions, CNPG databases and users, any lingering PVCs.

### Phase R2 — Rebrand (hobby → LLC)

All renames are cheap now and painful later. Decide the new domain for Salish Sea Wolf first; everything keys off it.

1. **Domain:** one variable (`TF_VAR_domain` via 1Password) — but remember the wildcard cert re-issues, OIDC redirect URIs in Authentik change, and Gitea's ROOT_URL and SSH host change. Budget a half-day, not five minutes.
2. **1Password vault:** consider a new vault named for the LLC (or rename), then update `op://` paths across mise.toml files in one sweep. This is also the moment to separate business secrets from personal (`Employee/…`) items.
3. **B2 bucket:** new bucket under an LLC-appropriate name; update the VolSync restic repositories and CNPG Barman config; let old backups age out.
4. **Labels:** `project=k3s-service-cluster` → keep or rename once, consistently across tofu, inventory filtering, and kubeconfig context names.
5. **Hetzner:** server names, LB name, SSH key name if you want them to match the brand. Cosmetic; do it only if it doesn't force reprovisioning you don't want.

### Phase R3 — GitOps conversion

**R3.1 — Define the two tiers.**
- *Bootstrap tier (stays Ansible/mise, rarely runs):* OpenTofu infra, K3s install, CCM/CSI, cert-manager, step-ca, 1Password Connect + Operator, CNPG operator, Redis, Authentik, Gitea, and Argo CD itself. This is the chicken-and-egg set: everything Argo needs to exist before it can pull from Gitea.
- *GitOps tier (Argo-reconciled):* copyparty, paperless, gatus, homarr, seaweedfs, seaweedfs-csi, volsync, gitea-actions, and every future service. Over time, migrate parts of the bootstrap tier in too (Authentik and Gitea config-as-manifests can move; their initial installation stays bootstrap), keeping the Ansible path as break-glass.

**R3.2 — Repo layout target.**

```
infrastructure/tofu/            # unchanged
platform/ansible/               # bootstrap-only roles
platform/argocd/                # Argo install values + root ApplicationSet
services/<name>/
  app/                          # manifests / Helm values Argo watches
  networkpolicy.yaml            # H2 convention: every service declares traffic
  bootstrap/                    # only if the service has an Ansible bootstrap step
docs/
```

One ApplicationSet with a directory generator over `services/*/app` gives per-service Applications nearly for free. Sync waves handle ordering where it matters (CSI before PVC consumers).

**R3.3 — Migrate incrementally.**
One service per sitting: gatus first (stateless, low risk), then homarr, copyparty, paperless, then the stateful/privileged ones (seaweedfs, gitea-actions) once the pattern is proven. Each migration: convert Ansible-templated manifests to plain manifests or Helm values, add the NetworkPolicy (H2.1), delete the service from the mise deploy chain.

**R3.4 — Disaster-recovery mirror.**
*(Superseded: GitHub is the repo of record and Argo pulls from it directly; there is no Gitea push-mirror.)* ~~Gitea push-mirror the monorepo to GitHub (or any external host).~~ The repo that defines the cluster must survive the cluster. Also document the bootstrap-from-zero runbook: tofu apply → ansible bootstrap → Argo syncs the rest.

### Phase R4 — CI granularity

Gitea Actions workflows with `paths:` filters, all in the one repo:

- `services/**` → kubeconform + kube-linter on changed service dirs
- `infrastructure/**` → `tofu fmt -check` + `tofu validate`
- `platform/**` → ansible-lint + yamllint
- Everything → gitleaks (already in pre-commit; CI backstops it)

Argo handles CD, so CI stays pure validation — no deploy credentials in the runner, which also keeps H2.2's egress policy simple.

### Deliberately rejected structures

- **Per-service repos (~15):** daily overhead (secret duplication, version discovery, N pipelines) for benefits a solo operator rarely collects. Path-scoped Argo Applications deliver the same deploy independence inside one repo.
- **Two-repo split (infra / services):** the only split that earns its keep, matching change cadence and blast radius. Defensible, but defer — Argo makes the monorepo behave like a polyrepo for CD purposes, and you can split later with `git filter-repo` if the infra/services boundary ever needs different access controls (e.g., a collaborator who should see services but not infra).

---

## Suggested execution order

1. H1.1–H1.3 (an afternoon, behind the firewall)
2. R1 hygiene (a day)
3. R2 rebrand (a day, dominated by the domain swap)
4. R3.1–R3.2 Argo install + first migrated service, with H2.1 datastore policies landing alongside (a weekend)
5. R3.3 remaining migrations + H2.2–H2.4 as each service converts (spread over weeks, one service per sitting)
6. R4 CI (an afternoon, anytime after R3.2)
7. H3 gate → open 80/443 → onboard first client group in Authentik
