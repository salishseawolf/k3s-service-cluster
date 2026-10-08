# Infrastructure Review — Todo

## Pending Verification (on next fresh deploy)
- [ ] Gitea OIDC resolves with production LE cert
- [ ] Database syncs cleanly with managed roles + quota

## Minor
- [ ] m1: Inconsistent namespace name quoting
- [ ] m6: Poorly named paperless deployment files
- [ ] m7: Share IngressRoute auth bypass undocumented

## Suggestions
- [ ] S2: Add egress NetworkPolicy restrictions where safe
- [ ] S5: Consider cluster monitoring

## Fix linting issues
Temporary kube-linter exceptions, marked `TODO(lint)` in the manifests
(`grep -rn "TODO(lint)" services platform`). Fixing one means removing its
`ignore-check.kube-linter.io/*` annotation; `mise run check` must still pass.
Permanent by-design exceptions (CSI node/mount, node-exporter, gitea-actions
dind, volsync probe ports, monitoring dangling-service) are not listed here.
- [ ] seaweedfs PDB: decide whether `maxUnavailable: 0` stays as a deliberate drain gate (moving seaweedfs is an outage for every PVC) or becomes `1`; add `unhealthyPodEvictionPolicy: AlwaysAllow` either way
- [ ] seaweedfs: map write paths outside `/data` for a read-only root; migrate ownership of root-owned data, then run non-root
- [ ] seaweedfs-csi controller: run the CSI sidecars (provisioner, attacher, resizer, livenessprobe) non-root with a read-only root; the PVC canary gates breakage
- [ ] copyparty: migrate PVC data ownership, then run as uid 1000; map write paths for a read-only root
- [ ] paperless: verify the `/run` emptyDir (`medium: Memory`) is already 0777, then remove the root `fix-perms` init container
- [ ] paperless: map the main container's write paths for a read-only root
- [ ] paperless tika: read-only root plus an emptyDir at `/tmp` (test with `podman run --read-only --tmpfs /tmp`)
- [ ] paperless gotenberg: read-only root plus an emptyDir at `/tmp` (same test)
- [ ] gitea: set `containerSecurityContext.readOnlyRootFilesystem: true` after a podman `--read-only` test (rootless image writes `/data` and `/tmp`)
- [ ] identity: authentik server and worker with a read-only root (SSO for everything, so test separately)
- [ ] monitoring grafana: read-only root (the chart supports it; writes `/var/lib/grafana` and `/tmp`)
- [ ] monitoring alloy: read-only root with an emptyDir for `/tmp/alloy`
- [ ] homarr: `init-nginx` read-only root (low risk, writes only to emptyDirs); main container read-only root and non-root after podman tests (exceptions predate the `TODO(lint)` marker)
- [ ] kimai: read-only root for kimai (apache, writes `var/cache` and `var/log`) and kimai-mariadb (writes `/tmp`); map the paths to emptyDirs, then drop their `TODO(lint)` annotations; test each with `podman run --read-only --tmpfs /tmp`
