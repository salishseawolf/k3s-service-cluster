# Runbook — Live-Cluster Steps

Everything in this file requires the running cluster, a 1Password session, or
a human decision. The repo-side work referenced here is already committed;
this is the ordered checklist for landing it. Companion docs: PLAN.md
(rationale), MIGRATION.md (per-service GitOps conversion recipe).

## 0. Prerequisites (1Password items to create)

| Item (vault: K3s Service Cluster) | Fields | Consumed by |
|---|---|---|
| `Admin Allow List` | `IPV4` (e.g. `203.0.113.7/32`) | tofu firewall (no default anymore) |
| `Redis Password` | `password` — **alphanumeric only** (embedded in redis:// URLs) | redis + all consumers |
| `ArgoCD Repo Credentials` | `username`, `password` (Gitea token, read_repository scope) | Argo CD repo access — created later, step 6 |

## 1. Verify NetworkPolicy enforcement (H1.2) — before anything else

K3s args include no `--disable-network-policy`, so the embedded controller
should be active. Trust nothing; verify:

```bash
kubectl create ns netpol-canary
kubectl -n netpol-canary run web --image=nginx --port=80
kubectl -n netpol-canary expose pod web --port=80
kubectl -n netpol-canary run probe --rm -it --image=busybox --restart=Never \
  -- wget -qO- --timeout=3 http://web   # expect: SUCCESS (no policy yet)
kubectl -n netpol-canary apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all, namespace: netpol-canary}
spec: {podSelector: {}, policyTypes: [Ingress]}
EOF
kubectl -n netpol-canary run probe --rm -it --image=busybox --restart=Never \
  -- wget -qO- --timeout=3 http://web   # expect: TIMEOUT (policy enforced)
kubectl delete ns netpol-canary
```

If the second probe succeeds, STOP: policies are inert; investigate the k3s
network policy controller before deploying anything from the H2.1 commit.

Also note how long the policy took to take effect — useful operational
knowledge before touching namespaces that matter.

## 2. Redis auth rollout (H1.1) — one sitting, sessions will drop

1. Create the `Redis` 1P item (alphanumeric password).
2. `mise run //services/redis:deploy` — requirepass lands, pod restarts.
3. Immediately deploy consumers (each re-renders with the password):
   `//services/identity:deploy`, `//services/gitea:deploy`,
   `//services/paperless:deploy`, `//services/homarr:deploy`.
4. Expect one forced re-login everywhere (sessions lived in Redis).
5. Verify: `kubectl -n redis exec deploy/redis -- redis-cli ping` →
   `NOAUTH` error is the success signal; then with `-a` → `PONG`.
6. Authentik now uses shared Redis for the first time (host was empty
   before) — watch `kubectl -n identity logs deploy/authentik-server`
   for Redis connection errors on startup.

## 3. NetworkPolicies rollout (H2.1) — canary first

Roll one namespace, verify, then the rest:

1. `mise run //services/homarr:deploy` (applies homarr policies) — then:
   - browse dashboard.<domain> (Traefik path works — node ipBlock),
   - `kubectl -n homarr get pods` stays Ready (kubelet probes unaffected),
   - from a scratch pod in another non-allowed ns, `wget homarr.homarr.svc:7575`
     times out.
2. If kubelet probes start failing (pods flapping NotReady): the CNI is
   sourcing probes from the cni0 bridge IP inside the pod CIDR. Fix before
   proceeding — add a narrowly scoped ipBlock for the node-local bridge /32s,
   NOT a blanket 10.42.0.0/16 (that would reopen every pod).
3. Deploy the rest: database, redis, identity, gitea, gitea-actions, gatus,
   copyparty, paperless, seaweedfs, seaweedfs-csi.
4. gitea-actions egress check: run a CI job that (a) clones from Gitea — must
   work, (b) curls redis.redis.svc:6379 — must time out.
5. SeaweedFS CSI: confirm existing PVC mounts survive and a new PVC binds
   (FUSE traffic must ride the node ipBlock allow).

## 4. Edge auth + groups (H2.3/H2.4) — after identity redeploy

1. `//services/identity:deploy` pushes the extended blueprint (Gatus + Homarr
   forward-auth providers, `internal` group, policy bindings, rate limit).
2. **Add your user to the `internal` group in Authentik** — the bindings deny
   everyone else, including you, until then.
3. Redeploy gatus + homarr (middleware on their IngressRoutes).
4. Verify: incognito → gatus.<domain> → Authentik login → dashboard.
   A user outside `internal` gets denied by policy.
5. Rate limit sanity: hammer auth.<domain> with ~60 rapid requests → 429s.

Caveat: forward-auth blocks non-browser clients. If you later want Homarr's
mobile app or any API against these services, exempt specific paths via a
second IngressRoute rule or issue Authentik app passwords.

## 5. Declarative DB principals

`//services/database:deploy` now creates the gatus basic-auth secret, the
managed role, and the `gatus-db` Database CR. Verify adoption of the
pre-existing role/database:

```bash
kubectl -n database get database gatus-db -o jsonpath='{.status.applied}'  # true
kubectl -n database get cluster main-db -o jsonpath='{.status.managedRolesStatus}'
```

## 6. GitOps activation (R3)

1. Push this repo to Gitea (`salish/cluster` or adjust
   `argocd_repo_url` in platform/argocd defaults). Set up the GitHub
   push-mirror in Gitea now — the repo that defines the cluster must survive
   the cluster. Decision point: point Argo at Gitea (self-hosted purity) or
   at the mirror (breaks the bootstrap cycle; recommended, see PLAN.md).
2. Create the `ArgoCD Repo Credentials` 1P item.
3. `mise run deploy:gitops`
4. The ApplicationSet discovers `services/gatus/app`. **Cutover** (first and
   only manual one; recipe generalized in MIGRATION.md):
   ```bash
   helm -n gatus uninstall gatus        # remove the bootstrap-deployed release
   # Argo Application 'gatus' syncs the chart version within ~3 min
   kubectl -n gatus get pods -w
   ```
   First sync must reach Synced/Healthy with an empty diff thereafter.
5. Optional: webhook Gitea → argocd-server to collapse the 3-min poll.

## 7. Go-live gate (H3) — before opening 80/443 to the world

- [ ] CNPG restore drill: restore latest Barman backup into a scratch
      namespace, `SELECT count(*)` something real, tear down. A backup that
      has never been restored is a hypothesis.
- [ ] Velero: BSL `Available`, a manual backup + restore of one PVC.
- [ ] Gatus alerts fire (break something small; watch Teams).
- [ ] No IngressRoute without an auth story:
      `kubectl get ingressroute -A -o yaml | grep -B5 -A20 routes:` — every
      route has middleware, an outpost in front, or app-level OIDC.
- [ ] Every service namespace has a default-deny policy:
      `kubectl get netpol -A`.
- [ ] Client tenancy ready: first `client-<name>` group created and bound to
      exactly the applications that client should reach.
- [ ] Then: widen 80/443 in the Hetzner firewall (tofu change) and watch the
      Authentik rate-limit + Gatus dashboards for the first hours.

## Bootstrap from zero (disaster recovery order)

tofu apply → platform/ansible (K3s+CCM/CSI) → cert-manager → step-ca →
velero → database → identity → seaweedfs(+csi) → redis → copyparty → homarr →
gitea → gitea-actions → paperless → gatus → developer-tooling →
push repo to Gitea (skip if Argo points at the GitHub mirror) →
deploy:gitops → Argo reconciles the GitOps tier.
