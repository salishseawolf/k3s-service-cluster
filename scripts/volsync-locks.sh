#!/usr/bin/env bash
# Show or clear restic locks in the VolSync B2 repository whose 1Password item
# is named in $VOLSYNC_ITEM (e.g. "VolSync B2 paperless-data"). Used by the
# backup:*:locks / backup:*:unlock tasks in services/*/mise.toml.
#
# Usage: VOLSYNC_ITEM="VolSync B2 <repo>" volsync-locks.sh show
#        VOLSYNC_ITEM="VolSync B2 <repo>" volsync-locks.sh clear [--all]
#
# A VolSync mover that is killed mid-run (pod deleted, node evicted) leaves its
# lock behind, and the next run's forget/prune then fails with "repository is
# already locked". `clear` runs `restic unlock`, which only removes locks restic
# considers stale (older than 30 min, or a dead PID on this host). `clear --all`
# removes every lock: use it only when `show` lists no live mover, i.e. no
# volsync-src-<repo> pod is Running (kubectl -n <ns> get pods).
#
# The credentials are resolved once by `op run` and never written out.
set -euo pipefail

if [ "${1:-}" != "--inner" ]; then
  : "${VOLSYNC_ITEM:?set VOLSYNC_ITEM to the 1Password item name, e.g. \"VolSync B2 paperless-data\"}"
  case "${1:-}" in
    show) ;;
    clear) [ -z "${2:-}" ] || [ "$2" = "--all" ] || { echo "usage: $0 clear [--all]" >&2; exit 2; } ;;
    *) echo "usage: $0 show | clear [--all]" >&2; exit 2 ;;
  esac
  item="op://K3s Service Cluster/${VOLSYNC_ITEM}"
  export RESTIC_REPOSITORY="${item}/RESTIC_REPOSITORY"
  export RESTIC_PASSWORD="${item}/RESTIC_PASSWORD"
  export AWS_ACCESS_KEY_ID="${item}/AWS_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="${item}/AWS_SECRET_ACCESS_KEY"
  echo "== ${VOLSYNC_ITEM}" >&2
  exec op run -- bash "$0" --inner "$@"
fi

# --inner: runs under `op run` with the restic env resolved.
shift
show() {
  local ids
  ids=$(restic --no-lock list locks --quiet)
  if [ -z "$ids" ]; then echo "no locks"; return; fi
  printf '%-10s %-25s %-9s %-36s %s\n' ID CREATED EXCLUSIVE HOST PID
  for id in $ids; do
    restic --no-lock cat lock "$id" --quiet \
      | yq -p json -o tsv '[.time, .exclusive, .hostname, .pid] | @tsv' \
      | while IFS=$'\t' read -r t ex host pid; do
          printf '%-10s %-25s %-9s %-36s %s\n' "${id:0:8}" "${t:0:19}" "$ex" "$host" "$pid"
        done
  done
}

case "$1" in
  show) show ;;
  clear)
    if [ "${2:-}" = "--all" ]; then restic unlock --remove-all; else restic unlock; fi
    echo "-- remaining:"; show ;;
esac
