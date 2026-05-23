#!/usr/bin/env bash
# purge.sh — delete a macmigration backup tree from the external drive.
# MANUAL. Never invoked by restore.sh. Always destructive.
#
# Usage:
#   export BACKUP_ROOT=/Volumes/YourDrive/macbackup   # REQUIRED — no default
#   ./purge.sh                     # delete everything under BACKUP_ROOT
#   ./purge.sh --meta-only         # delete only meta/ (Brewfile, plists, …)
#   ./purge.sh --home-only         # delete only home/<user>/ (the rsync mirror)
#   ./purge.sh --dry-run           # show what would be deleted, do nothing
#   ./purge.sh -y                  # skip the "type PURGE" confirmation

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

WHAT="all"
DRY=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --meta-only) WHAT="meta"; shift ;;
    --home-only) WHAT="home"; shift ;;
    --dry-run)   DRY=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

###############################################################################
# Safety rails — refuse to operate on anything that isn't clearly a backup.
###############################################################################

# 1. BACKUP_ROOT must be a real path under /Volumes (or similar), never a
#    system or home directory. Normalise + check against a blocklist.
canon="$(cd "$BACKUP_ROOT" 2>/dev/null && pwd -P || echo "$BACKUP_ROOT")"
case "$canon" in
  /|/Users|/Volumes|/Applications|/Library|/System|/usr|/etc|/var|/tmp|/bin|/sbin|/opt|/private|/private/tmp|/private/var|/private/etc)
    die "Refusing to purge a bare system or top-level path: $canon"
    ;;
esac
# Path depth: require at least /Volumes/<vol>/<dir> (≥3 components).
depth=$(awk -F/ '{n=0; for (i=1;i<=NF;i++) if ($i!="") n++; print n}' <<<"$canon")
[[ "$depth" -ge 3 ]] || die "Refusing to purge a shallow path (<3 components): $canon"

# 2. The directory has to look like a macmigration backup — i.e., contain
#    meta/manifest.txt OR home/. Otherwise we're being pointed at the wrong dir.
if [[ ! -f "$canon/meta/manifest.txt" && ! -d "$canon/home" ]]; then
  die "$canon doesn't look like a macmigration backup (no meta/manifest.txt or home/)"
fi

# 3. Resolve targets.
case "$WHAT" in
  all)  targets=("$canon") ;;
  meta) targets=("$canon/meta") ;;
  home) targets=("$canon/home") ;;
  *) die "internal: bad WHAT=$WHAT" ;;
esac

###############################################################################
# Show what will be deleted + manifest preview
###############################################################################
log "BACKUP_ROOT: $canon"
if [[ -f "$canon/meta/manifest.txt" ]]; then
  log "Backup manifest:"
  sed 's/^/  /' "$canon/meta/manifest.txt"
fi

log "Will delete:"
total_bytes=0
for p in "${targets[@]}"; do
  if [[ -e "$p" ]]; then
    # `du -sh` for display; `du -sk` (kilobytes) for the running total.
    size_h=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
    size_k=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
    total_bytes=$((total_bytes + size_k))
    printf '  %s  (%s)\n' "$p" "$size_h"
  else
    printf '  %s  (missing — nothing to delete)\n' "$p"
  fi
done
printf '  --------------------------------------------\n'
printf '  total: ~%s MiB\n' "$((total_bytes / 1024))"

###############################################################################
# Dry-run / confirmation / delete
###############################################################################
if [[ "$DRY" -eq 1 ]]; then
  ok "Dry run — nothing deleted."
  exit 0
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  printf '\nType PURGE (in capitals) to confirm deletion: '
  read -r ans
  [[ "$ans" == "PURGE" ]] || die "Aborted — nothing deleted."
fi

for p in "${targets[@]}"; do
  [[ -e "$p" ]] || continue
  log "Deleting $p…"
  rm -rf -- "$p"
  ok "Deleted $p"
done

ok "Purge complete."
