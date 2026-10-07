#!/usr/bin/env bash
# Render every chart and validate what Argo would actually apply:
#   helm template -> kubeconform (schemas, -strict) -> kube-linter (.kube-linter.yaml)
#
# Exceptions: our own templates carry ignore-check.kube-linter.io/<check>
# annotations (with the reason as the value) on the object. Upstream charts
# can't, so <chart>/.kube-linter-exclude lists checks to skip for that chart,
# one per line, each followed by a "# reason".
#
# Usage: check-rendered-charts.sh [--changed-since REF] [PATH_PREFIX...]
#   PATH_PREFIX      only consider charts under these paths (e.g. services/)
#   --changed-since  only check charts with changes since REF; a change to a
#                    file that affects every chart (lint config, this script,
#                    tool pins) checks them all
#
# Each chart is rendered from a temp copy, so dependency resolution never
# touches the working tree. Dependencies come from Chart.lock (+ vendored
# archives when present), i.e. the versions Argo deploys, not the newest in
# range. All charts are checked; failures are summarised at the end.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Validate schemas against the Kubernetes version the cluster actually runs
# (k3s_version in the Ansible inventory), not kubeconform's "master".
K8S_VERSION="$(sed -n 's/^k3s_version: "v\([0-9.]*\)+k3s.*/\1/p' \
  bootstrap/ansible/inventory/group_vars/all.yml)"
[ -n "$K8S_VERSION" ] || { echo "k3s_version not found in group_vars/all.yml" >&2; exit 1; }

# Charts Argo renders. Services are auto-discovered like the ApplicationSet
# does; platform charts are listed explicitly (platform/monitoring-crd is not
# rendered by Argo: its Application pulls the upstream chart directly).
ALL_CHARTS=(services/*/app
  platform/storage/seaweedfs platform/storage/seaweedfs-csi
  platform/cert-manager/config platform/cert-manager/crd
  platform/step-ca/config platform/step-ca/crd
  platform/volsync platform/argocd/self)

# Files whose change can alter the result for every chart. The validate
# workflows are included so a CI-only change re-checks every chart under
# that workflow's prefix instead of finding "No charts to check".
GLOBAL_FILES='^(\.kube-linter\.yaml|scripts/check-rendered-charts\.sh|mise\.toml|bootstrap/ansible/inventory/group_vars/all\.yml|\.github/workflows/validate-(services|platform)\.yaml)$'

changed_since=""
prefixes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --) ;;
    --changed-since) changed_since="$2"; shift ;;
    *) prefixes+=("${1%/}/") ;;
  esac
  shift
done

charts=()
for c in "${ALL_CHARTS[@]}"; do
  [ -f "$c/Chart.yaml" ] || continue
  if [ ${#prefixes[@]} -gt 0 ]; then
    match=0
    for p in "${prefixes[@]}"; do [[ "$c/" == "$p"* ]] && match=1; done
    [ $match = 1 ] || continue
  fi
  charts+=("$c")
done

if [ -n "$changed_since" ]; then
  changed="$(git diff --name-only "$changed_since" HEAD)"
  if grep -Eq "$GLOBAL_FILES" <<<"$changed"; then
    echo "Global lint input changed since $changed_since: checking all selected charts"
  else
    selected=()
    for c in "${charts[@]}"; do
      grep -q "^$c/" <<<"$changed" && selected+=("$c")
    done
    charts=("${selected[@]+"${selected[@]}"}")
  fi
fi

if [ ${#charts[@]} -eq 0 ]; then
  echo "No charts to check."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Isolated helm repo config so `helm repo add` never touches ~/.config/helm.
export HELM_REPOSITORY_CONFIG="$WORK/helm/repositories.yaml"
export HELM_REPOSITORY_CACHE="$WORK/helm/cache"

# Make Chart.lock's dependencies available to `helm template`. Skips the
# network when every locked archive is already vendored in charts/.
resolve_deps() {
  local dir="$1" deps lock url name version
  grep -q '^dependencies:' "$dir/Chart.yaml" || return 0
  lock="$dir/Chart.lock"
  if [ -f "$lock" ]; then
    deps="$(yq -r '.dependencies[] | .name + " " + .version' "$lock")"
    local vendored=1
    while read -r name version; do
      [ -f "$dir/charts/$name-$version.tgz" ] || vendored=0
    done <<<"$deps"
    [ $vendored = 1 ] && return 0
  fi
  # `helm dependency build` needs every https repo registered first.
  for url in $(yq -r '.dependencies[].repository' "$dir/Chart.yaml" | sort -u); do
    case "$url" in
      http*) helm repo add --force-update "r$(printf '%s' "$url" | md5sum | cut -c1-8)" "$url" >/dev/null ;;
    esac
  done
  # With Chart.lock: exact locked versions. Without: resolves the range.
  helm dependency build "$dir" >/dev/null
}

failed=()
for c in "${charts[@]}"; do
  echo "==> $c"
  tmp="$WORK/$c"
  mkdir -p "$(dirname "$tmp")"
  cp -a "$c" "$tmp"
  rendered="$WORK/rendered.yaml"
  excludes=()
  if [ -f "$c/.kube-linter-exclude" ]; then
    checks="$(sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$c/.kube-linter-exclude" | paste -sd, -)"
    [ -n "$checks" ] && excludes=(--exclude "$checks")
  fi
  ok=1
  # --skip-tests: Argo CD never runs Helm test hooks, so don't lint them.
  if resolve_deps "$tmp" \
     && helm template test "$tmp" --skip-tests --set domain=ci.example.com >"$rendered"; then
    # Run both validators even when the first fails, so one tool's findings
    # never hide the other's. 2>&1 keeps each tool's summary in order.
    kubeconform -kubernetes-version "$K8S_VERSION" -ignore-missing-schemas -strict -summary \
      "$rendered" 2>&1 || ok=0
    kube-linter lint --config "$ROOT/.kube-linter.yaml" ${excludes[@]+"${excludes[@]}"} \
      "$rendered" 2>&1 || ok=0
  else
    ok=0
  fi
  [ $ok = 1 ] || failed+=("$c")
done

echo
if [ ${#failed[@]} -gt 0 ]; then
  echo "FAILED (${#failed[@]}/${#charts[@]}):"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
echo "All ${#charts[@]} chart(s) passed."
