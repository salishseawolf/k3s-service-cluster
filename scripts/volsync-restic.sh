#!/usr/bin/env bash
# Run restic against the VolSync B2 repository whose 1Password item is named
# in $VOLSYNC_ITEM (e.g. "VolSync B2 paperless-data"). The item's restic env
# fields are resolved by `op run`, never written out. Used by the backup:*
# tasks in services/*/mise.toml, which set VOLSYNC_ITEM per task.
#
# Usage: VOLSYNC_ITEM="VolSync B2 <repo>" volsync-restic.sh <restic command> [args...]
#
# --no-lock: these are inspection commands, so never take a repository lock.
# A lock left by a long `mount` would otherwise make VolSync's weekly prune
# (which needs an exclusive lock) fail.
set -euo pipefail

: "${VOLSYNC_ITEM:?set VOLSYNC_ITEM to the 1Password item name, e.g. \"VolSync B2 paperless-data\"}"
[ $# -gt 0 ] || { echo "usage: VOLSYNC_ITEM=... volsync-restic.sh <restic command> [args...]" >&2; exit 2; }

item="op://K3s Service Cluster/${VOLSYNC_ITEM}"
export RESTIC_REPOSITORY="${item}/RESTIC_REPOSITORY"
export RESTIC_PASSWORD="${item}/RESTIC_PASSWORD"
export AWS_ACCESS_KEY_ID="${item}/AWS_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="${item}/AWS_SECRET_ACCESS_KEY"

echo "== ${VOLSYNC_ITEM}" >&2
exec op run -- restic --no-lock "$@"
