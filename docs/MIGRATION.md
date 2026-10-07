# Migration Recipe — Ansible Role → GitOps Application

Gatus is the worked example (`services/gatus/app/`); this file generalizes it.
One service per sitting. Order: homarr → copyparty → paperless → seaweedfs →
seaweedfs-csi → gitea-actions. Bootstrap tier (database, redis,
identity, gitea, cert-manager, step-ca, argocd) stays Ansible-delivered but
should converge on the same declarative artifacts (see "gutting", below).

## The audit: three buckets per task

Walk the role's `tasks/main.yml` and classify every task:

1. **Manifests in costume** — `kubernetes.core.k8s` with a `definition:` or a
   templated manifest. Extraction is mechanical: move to a chart template,
   replace `{{ lookup('env', 'TF_VAR_domain') }}` with `{{ .Values.domain }}`
   (injected by the root ApplicationSet), delete the task.
2. **Sequencing and waiting** — `k8s_info` + `until`, preflight checks,
   "wait for X ready". Deleted, not ported: Argo health checks + sync waves +
   controllers-retry-forever replace the one-shot execution model that made
   this scaffolding necessary. If ordering genuinely matters inside one app,
   annotate: `argocd.argoproj.io/sync-wave: "1"`.
3. **Genuine procedure** — psql execs, `ak apply_blueprint`, credential
   extraction, admin CLI calls. Each needs one of:
   - **operator absorption** (preferred): DB users/databases → CNPG managed
     roles + `Database` CRs owned by the database service (gatus shows the
     pattern); Authentik config → blueprint ConfigMaps discovered by
     Authentik, one ConfigMap per app, living in that app's directory —
     never patch the shared `authentik-blueprints` ConfigMap from another
     service's code (cross-app ownership violation; Argo will fight it)
   - **credential inversion**: never extract auto-generated OIDC secrets from
     Authentik's DB. Pre-generate client_id/client_secret as a 1P item;
     reference it from BOTH the blueprint (explicit client_id/client_secret
     attrs) and the app (OnePasswordItem). Rotation = 1P edit + 2 restarts.
   - **edge auth instead**: internal-only tools can drop app-level OIDC
     entirely — forward-auth middleware + `internal` group (gatus did this;
     homarr keeps app OIDC for user identity but is also edge-gated)
   - **Job hooks** (last resort): one-shot commands as a Kubernetes Job with
     `argocd.argoproj.io/hook: PostSync`
   - **stay in bootstrap**: touches systems outside the cluster (Hetzner,
     DNS, 1P vault writes) → remains Ansible

## Per-service checklist

- [ ] `services/<name>/app/Chart.yaml` + `values.yaml` (`domain: ""` — comes
      from the ApplicationSet parameter)
- [ ] Namespace template with PSA labels (Argo does NOT CreateNamespace;
      labels belong in git)
- [ ] Secrets → OnePasswordItem CRs (op:// pointers only)
- [ ] NetworkPolicy in the chart (copy the model from the role's
      `networkpolicy.yaml.j2`; it's the service's traffic contract)
- [ ] IngressRoute with its auth story (middleware / outpost / app OIDC)
- [ ] Config checksum annotation on the Deployment (kills "restart pods after
      config change" procedures)
- [ ] DB principal (if any) → add to database service: managed role in
      cluster.yaml.j2, entry in app-databases.yaml.j2, basic-auth secret task
- [ ] Validate: `helm template test services/<name>/app --set domain=x.test`
      renders; CI (validate-services) runs kubeconform + kube-linter on it
- [ ] Cutover: `helm -n <name> uninstall <release>` (if helm-deployed) or
      leave objects in place (ServerSideApply adopts k8s-applied objects);
      watch the Application reach Synced/Healthy with an EMPTY diff
- [ ] Gut the role: delete migrated tasks; remove the service from the mise
      deploy chain; keep only genuine bootstrap procedure (usually nothing)

## Service-specific notes

- **homarr**: DB provisioning → declarative principals; OIDC creds →
  inversion (currently extracted from Authentik's DB like gatus was);
  blueprint → own ConfigMap in services/homarr/app.
- **copyparty / seaweedfs**: proxy outposts — the outpost deployments are
  Authentik-controller-managed; only the blueprint moves. Mind
  `authentik_host` staying on internal cluster DNS.
- **paperless**: PVCs on seaweedfs-storage — Argo must never prune PVCs; add
  `argocd.argoproj.io/sync-options: Prune=false` on PVC manifests.
- **seaweedfs-csi / gitea-actions**: privileged namespaces; charts
  are mostly upstream Helm — use Argo's native Helm repo source (multi-source
  Application: upstream chart + values from this repo) instead of vendoring;
  these two can be per-Application manifests in platform/argocd if the
  directory generator doesn't fit.
- **identity/gitea (bootstrap tier, gutting only)**: apply the same
  conversions in place — declarative principals, credential inversion,
  per-app blueprint ConfigMaps — so the Ansible role shrinks to "helm upgrade
  + apply this directory". If Argo later points at the GitHub mirror, these
  graduate to the GitOps tier by adding an app/ directory, not by rewriting.
