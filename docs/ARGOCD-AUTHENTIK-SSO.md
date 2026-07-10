# Plan: Authentik SSO for Argo CD

## Overview
Swap Argo CD's admin-password login for Authentik OIDC. Uses the
credential-inversion pattern: pre-generate client_id/client_secret in
1Password, reference from both the Authentik blueprint and the Argo CD config.

## Limitation: CLI login not supported with direct OIDC
Direct OIDC (`oidc.config`) does not support `argocd login --sso`. Only
Dex-based SSO supports CLI login. CLI users must use:
```bash
argocd login --auth-token <api-token>
```
Generate an API token from the Argo CD UI or the admin CLI. Dex is already
disabled on this cluster, so direct OIDC is the right call — just document
the CLI limitation.

## Steps

### 1. 1Password vault item created
Item: `ArgoCD Secrets` (PASSWORD category)
- `oidc_client` → the client ID
- `password` → the client secret

### 2. Add Argo CD blueprint to identity chart
In `services/identity/app/templates/configmap-blueprints.yaml`, add:
```yaml
  blueprint-argocd.yaml: |
    ---
    version: 1
    metadata:
      name: Argo CD
      labels:
        blueprints.goauthentik.io/instantiate: "true"
    entries:
      - model: authentik_providers_oauth2.oauth2provider
        state: present
        id: provider-argocd
        identifiers:
          name: Argo CD OIDC Provider
        attrs:
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          client_type: confidential
          client_id: !Env AUTHENTIK_ARGOCD_CLIENT_ID
          client_secret: !Env AUTHENTIK_ARGOCD_CLIENT_SECRET
          redirect_uris:
            - matching_mode: strict
              url: "https://argocd.{{ .Values.domain }}/auth/callback"
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
          sub_mode: hashed_user_id
          grant_types:
            - authorization_code
            - refresh_token
          include_claims_in_id_token: true
          access_code_validity: minutes=1
          access_token_validity: hours=24
          property_mappings:
            - !Find [authentik_core.propertymapping, [name, "authentik default OAuth Mapping: OpenID 'openid'"]]
            - !Find [authentik_core.propertymapping, [name, "authentik default OAuth Mapping: OpenID 'profile'"]]
            - !Find [authentik_core.propertymapping, [name, "authentik default OAuth Mapping: OpenID 'email'"]]
          scope_set:
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, profile]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, email]]

      - model: authentik_core.application
        state: present
        id: app-argocd
        identifiers:
          name: Argo CD
          slug: argocd
        attrs:
          name: Argo CD
          provider: !KeyOf provider-argocd
          meta_launch_url: "https://argocd.{{ .Values.domain }}"
          meta_description: "GitOps continuous delivery"
          meta_icon: ""
          policy_engine_mode: any
          group: "Infrastructure"
```
Add env var references in `services/identity/app/values.yaml`:
```yaml
      - name: AUTHENTIK_ARGOCD_CLIENT_ID
        valueFrom: {secretKeyRef: {name: argocd-oidc, key: oidc_client}}
      - name: AUTHENTIK_ARGOCD_CLIENT_SECRET
        valueFrom: {secretKeyRef: {name: argocd-oidc, key: password}}
```

### 3. Add OnePasswordItem to Argo CD chart
In `platform/argocd/self/templates/onepassworditems.yaml`:
```yaml
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: argocd-oidc
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: argocd    # required for Argo to discover secret
spec:
  itemPath: "vaults/K3s Service Cluster/items/ArgoCD Secrets"
```

### 4. Configure Argo CD OIDC + RBAC
In `platform/argocd/self/values.yaml`, update `configs`:
```yaml
configs:
  cm:
    url: https://argocd.salishseawolf.com
    oidc.config: |
      name: Authentik
      issuer: https://auth.salishseawolf.com/application/o/argocd/
      clientID: $argocd-oidc:oidc_client
      clientSecret: $argocd-oidc:password
      requestedScopes: ["openid", "profile", "email"]
      requestedIDTokenClaims: {"groups": {"essential": true}}
      logoutURL: https://auth.salishseawolf.com/application/o/argocd/end-session/
  rbac:
    policy.default: role:readonly
    policy.csv: |
      g, infrastructure, role:admin
```
Keep `admin.enabled: "true"` during rollout. Flip to `"false"` after OIDC is
verified and at least one infrastructure-group user has tested admin access.

### 5. Verify
1. Sync identity app (applies blueprint → creates OIDC provider + app)
2. Sync argocd app (applies OIDC config + RBAC)
3. Visit `https://argocd.salishseawolf.com` — should redirect to Authentik login
4. Login with an `infrastructure` group member — should see full admin access
5. Login with a non-member — should see read-only access

## Rollback
If OIDC breaks Argo access:
1. `kubectl -n argocd edit configmap argocd-cm` — remove `oidc.config` line
2. `kubectl -n argocd rollout restart deployment argocd-server`
3. Admin login works as long as `admin.enabled: "true"` — keep it until verified

## Key design decisions
- **Credential inversion**: pre-generated keys in 1P, not auto-generated by
  Authentik — consistent with MIGRATION.md pattern
- **No offline_access scope**: Argo CD doesn't need long-lived sessions
  without user presence. Tokens expire after 24h (access_token_validity).
- **Groups via ID token**: `include_claims_in_id_token: true` ensures groups
  claim is available in the ID token, not just the UserInfo endpoint
- **Infrastructure → admin mapping**: leverages the existing superuser group
  from blueprint-infrastructure-group.yaml
