#!/usr/bin/env bash
# restore.sh — run on the NEW Mac to rehydrate from the external drive.
#
# Usage:
#   ./restore.sh                # full run (will prompt before destructive bits)
#   ./restore.sh --only brew    # just one section
#   ./restore.sh --skip rsync   # everything except the home mirror
#   ./restore.sh --dry-run      # show rsync diff without writing
#
# Section order matters: brew/langs first (so tools exist), then dotfiles,
# then defaults, then the home rsync. The home rsync is intentionally LAST
# and non-destructive by default.
#
# Prereqs (Xcode CLT + Homebrew + mas) ALWAYS run before any section, even
# with --only/--skip. They are install-if-missing and fast when present.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

ONLY=""; SKIP=""; DRY=""; ASSUME_YES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --skip) SKIP="$2"; shift 2 ;;
    --dry-run) DRY="--dry-run"; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done
run_section() {
  local name="$1"
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 1
  [[ -n "$SKIP" && "$SKIP" == "$name" ]] && return 1
  return 0
}
confirm() {
  [[ -n "$ASSUME_YES" ]] && return 0
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

[[ -d "$BACKUP_ROOT" ]] || die "Backup not found at $BACKUP_ROOT"
[[ -f "$META_DIR/manifest.txt" ]] || die "Missing manifest in $META_DIR — wrong drive?"
log "Restoring from $BACKUP_ROOT"
log "Manifest:"
sed 's/^/  /' "$META_DIR/manifest.txt"

###############################################################################
# Preflight — ALWAYS runs. Installs Xcode CLT, Homebrew, and mas if missing.
# Not gated by --only/--skip because every meaningful section needs at least
# this baseline (and the checks are no-ops when already installed).
###############################################################################
log "Preflight checks"

# Xcode Command Line Tools — needed by brew, git, and many casks.
if ! xcode-select -p >/dev/null 2>&1; then
  log "Installing Xcode Command Line Tools (a GUI prompt will appear)"
  xcode-select --install || true
  die "Re-run this script after the CLT install finishes."
fi

# Homebrew — needed by the brew/langs/vscode sections.
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for this session.
  if   [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]];    then eval "$(/usr/local/bin/brew shellenv)"
  fi
fi
command -v brew >/dev/null 2>&1 || die "Homebrew install appears to have failed."

# mas — needed for Mac App Store apps in the Brewfile (and used by backup.sh).
if ! command -v mas >/dev/null 2>&1; then
  log "Installing mas (Mac App Store CLI)"
  brew install mas || warn "mas install failed — MAS apps in the Brewfile will be skipped"
fi

ok "Preflight OK ($(brew --version | head -1))"

###############################################################################
# 1. Brewfile (taps, formulae, casks, MAS apps)
###############################################################################
if run_section brew; then
  if [[ -f "$META_DIR/Brewfile" ]]; then
    log "Installing from Brewfile"
    # mas needs you to be signed into the App Store first. We don't sign in for
    # you — if mas can't list, brew bundle will skip those lines with a warning.
    brew bundle --file="$META_DIR/Brewfile" || warn "Brewfile finished with errors (often MAS — sign in to App Store and re-run)"
    ok "Brewfile applied"
  else
    warn "No Brewfile found — skipping"
  fi
fi

###############################################################################
# 2. Dotfiles (small, safe to overlay)
###############################################################################
if run_section dotfiles; then
  if [[ -d "$META_DIR/dotfiles" ]]; then
    log "Restoring dotfiles into \$HOME"
    if confirm "Overwrite matching dotfiles in $HOME?"; then
      rsync -a --backup --suffix=".pre-restore" \
        "$META_DIR/dotfiles/" "$HOME/"
      ok "Dotfiles restored (any overwritten files saved as *.pre-restore)"
    else
      warn "Skipped dotfiles"
    fi
  fi
fi

###############################################################################
# 3. Language ecosystems — global packages
###############################################################################
if run_section langs; then
  log "Reinstalling global language packages"
  # If none of the language CLIs are present, the user likely hasn't applied
  # the Brewfile yet. Tell them clearly instead of silently no-op-ing.
  if ! command -v npm  >/dev/null 2>&1 \
   && ! command -v pipx >/dev/null 2>&1 \
   && ! command -v uv   >/dev/null 2>&1 \
   && ! command -v gem  >/dev/null 2>&1; then
    die "No language CLIs found (npm/pipx/uv/gem). Run \`./restore.sh --only brew\` first to install the Brewfile."
  fi
  # npm globals
  if [[ -f "$META_DIR/npm-global.json" ]] && command -v npm >/dev/null 2>&1; then
    pkgs=$(/usr/bin/python3 - <<'PY' "$META_DIR/npm-global.json"
import json, sys
d = json.load(open(sys.argv[1]))
for n, v in (d.get("dependencies") or {}).items():
    if n == "npm": continue
    print(n)
PY
)
    if [[ -n "$pkgs" ]]; then
      log "  npm install -g $(echo "$pkgs" | wc -l | tr -d ' ') packages"
      echo "$pkgs" | xargs -n1 npm install -g || warn "Some npm globals failed"
    fi
  fi
  # pipx
  if [[ -f "$META_DIR/pipx-list.json" ]] && command -v pipx >/dev/null 2>&1; then
    pkgs=$(/usr/bin/python3 -c '
import json, sys
d=json.load(open("'"$META_DIR/pipx-list.json"'"))
for p in d.get("venvs",{}):
    print(p)
')
    [[ -n "$pkgs" ]] && echo "$pkgs" | xargs -n1 pipx install || true
  fi
  # uv tools
  if [[ -f "$META_DIR/uv-tools.txt" ]] && command -v uv >/dev/null 2>&1; then
    awk '/^[a-zA-Z0-9_-]/ {print $1}' "$META_DIR/uv-tools.txt" \
      | xargs -I{} -n1 uv tool install {} 2>/dev/null || true
  fi
  ok "Language globals attempted (check above for failures)"
fi

###############################################################################
# 4. VS Code / Cursor extensions
###############################################################################
if run_section vscode; then
  # If we have at least one extensions list but no matching CLI, the editor
  # cask probably hasn't been installed yet — point to --only brew.
  has_list=0; has_cli=0
  for cli in code cursor code-insiders; do
    [[ -f "$META_DIR/${cli}-extensions.txt" ]] && has_list=1
    command -v "$cli" >/dev/null 2>&1 && has_cli=1
  done
  if [[ "$has_list" -eq 1 && "$has_cli" -eq 0 ]]; then
    die "Extension lists exist but no editor CLI (code/cursor) found. Run \`./restore.sh --only brew\` first to install the editor cask."
  fi
  for cli in code cursor code-insiders; do
    list="$META_DIR/${cli}-extensions.txt"
    if [[ -f "$list" ]] && command -v "$cli" >/dev/null 2>&1; then
      log "Installing $cli extensions"
      while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue
        "$cli" --install-extension "$ext" --force >/dev/null 2>&1 \
          && echo "  + $ext" \
          || echo "  ! $ext (failed)"
      done < "$list"
    fi
  done
fi

###############################################################################
# 5. macOS defaults
###############################################################################
if run_section defaults; then
  if [[ -d "$META_DIR/defaults" ]]; then
    log "Importing macOS defaults"
    if confirm "Import defaults? (will affect Dock/Finder/keyboard/etc; logout recommended after)"; then
      for f in "$META_DIR/defaults"/*.plist; do
        [[ -f "$f" ]] || continue
        domain="$(basename "$f" .plist)"
        defaults import "$domain" "$f" && echo "  imported $domain" || warn "failed $domain"
      done
      ok "Defaults imported — log out / restart Dock & Finder to see changes:"
      echo "    killall Dock Finder SystemUIServer"
    else
      warn "Skipped defaults"
    fi
  fi
fi

###############################################################################
# 6. LaunchAgents + crontab
###############################################################################
if run_section services; then
  if [[ -d "$META_DIR/launchagents" ]]; then
    log "Restoring LaunchAgents"
    ensure_dir "$HOME/Library/LaunchAgents"
    rsync -a "$META_DIR/launchagents/" "$HOME/Library/LaunchAgents/"
    # Load each plist (ignore already-loaded errors).
    for plist in "$HOME/Library/LaunchAgents"/*.plist; do
      [[ -f "$plist" ]] || continue
      launchctl load -w "$plist" 2>/dev/null || true
    done
    ok "LaunchAgents restored"
  fi
  if [[ -s "$META_DIR/crontab.txt" ]] && ! grep -q '^# no crontab' "$META_DIR/crontab.txt"; then
    log "Restoring crontab"
    crontab "$META_DIR/crontab.txt" && ok "crontab installed"
  fi
fi

###############################################################################
# 7. Home directory mirror (LAST — non-destructive by default)
###############################################################################
if run_section rsync; then
  log "Restoring \$HOME from $HOME_MIRROR"
  if [[ ! -d "$HOME_MIRROR" ]]; then
    warn "No home mirror at $HOME_MIRROR — skipping"
  else
    # IMPORTANT: no --delete here. We add files from the mirror but don't
    # remove anything the new Mac already has. This makes the restore safe
    # to re-run and avoids nuking system-created files in a fresh ~.
    if [[ -n "$DRY" ]]; then
      log "Dry run — showing what WOULD change:"
    fi
    rsync -ahHPXA --numeric-ids --partial $DRY \
      --exclude-from="$SCRIPT_DIR/rsync-excludes.txt" \
      "$HOME_MIRROR/" "$HOME/" \
      | tee "$META_DIR/restore-$TS.log" >/dev/null
    ok "Home restore complete"
  fi
fi

log "Restore done. Recommended next steps:"
cat <<'EOF'
  1. Sign into Apple ID / iCloud (Messages, Mail, Photos, Mobile Documents resync)
  2. Sign into App Store, then re-run:  ./restore.sh --only brew
     (mas apps will install once you're signed in)
  3. Run the GUI-only settings script:  osascript macos-settings.applescript
  4. Restart Dock/Finder to apply defaults:  killall Dock Finder SystemUIServer
  5. Open Keychain Access and verify SSH key passphrases / app logins
EOF
