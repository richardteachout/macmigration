#!/usr/bin/env bash
# Shared config — sourced by backup.sh and restore.sh.
# Override any of these by exporting them before running, e.g.:
#   BACKUP_ROOT=/Volumes/MyDrive/macbackup ./backup.sh

set -u

# ---- Where the backup lives on the external drive ----
# BACKUP_ROOT MUST be set in the environment — no default. This is intentional
# so you can't accidentally write a multi-GB backup to the wrong path.
#   export BACKUP_ROOT=/Volumes/YourDrive/macbackup
if [[ -z "${BACKUP_ROOT:-}" ]]; then
  printf '\033[1;31m[err ]\033[0m BACKUP_ROOT is not set.\n' >&2
  printf '  Export it before running, e.g.:\n' >&2
  printf '    export BACKUP_ROOT=/Volumes/YourDrive/macbackup\n' >&2
  printf '    %s\n' "$(basename "${BASH_SOURCE[1]:-script}")" >&2
  exit 1
fi

# Per-user home rsync target (mirrors the home tree).
: "${HOME_MIRROR:=$BACKUP_ROOT/home/$(whoami)}"

# Where exported manifests / plists / dotfiles snapshots go.
: "${META_DIR:=$BACKUP_ROOT/meta}"

# Hostname snapshot at backup time, for the restore log.
: "${SOURCE_HOST:=$(scutil --get ComputerName 2>/dev/null || hostname)}"

# Timestamp for run logs.
TS="$(date +%Y%m%d-%H%M%S)"

# Where this script lives — used to find sibling files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Helpers ----
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; exit 1; }

ensure_dir() { mkdir -p "$1"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# Confirm backup volume is mounted and writable (used by backup.sh).
require_backup_volume() {
  local vol_root
  vol_root="$(echo "$BACKUP_ROOT" | awk -F/ '{print "/"$2"/"$3}')"
  [[ -d "$vol_root" ]] || die "Backup volume not mounted at $vol_root"
  mkdir -p "$BACKUP_ROOT" || die "Cannot create $BACKUP_ROOT"
  [[ -w "$BACKUP_ROOT" ]] || die "$BACKUP_ROOT is not writable"
}
