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
# Identity reconciliation — figure out the old username, point HOME_MIRROR at
# the right tree, and prepare the cross-user translation maps.
###############################################################################
manifest_field() {
  awk -v k="$1" '$1 == k":" { sub(/^[^:]+:[[:space:]]*/, ""); print; exit }' "$META_DIR/manifest.txt"
}
MFST_USER=$(manifest_field source_user)
MFST_UID=$(manifest_field source_uid)
MFST_GID=$(manifest_field source_gid)
MFST_PRIMARY_GROUP=$(manifest_field source_primary_group)
MFST_GROUPS=$(manifest_field source_groups)

NEW_USER=$(whoami)
NEW_UID=$(id -u)
NEW_PRIMARY_GROUP=$(id -gn)
NEW_GROUPS=$(id -Gn | tr ' ' ',')

# If OLD_USER wasn't set in env, derive it from the manifest, or prompt.
if [[ -z "${OLD_USER:-}" || "$OLD_USER" == "$NEW_USER" ]]; then
  if [[ -d "$BACKUP_ROOT/home/$MFST_USER" ]]; then
    OLD_USER="$MFST_USER"
  else
    log "Manifest user '$MFST_USER' not found at $BACKUP_ROOT/home/. Available:"
    ls -1 "$BACKUP_ROOT/home/" 2>/dev/null | sed 's/^/    /'
    read -r -p "Enter old username (the directory under $BACKUP_ROOT/home/): " OLD_USER
  fi
fi
HOME_MIRROR="$BACKUP_ROOT/home/$OLD_USER"
[[ -d "$HOME_MIRROR" ]] || die "No home mirror at $HOME_MIRROR"

CROSS_USER=0
[[ "$OLD_USER" != "$NEW_USER" ]] && CROSS_USER=1
log "Source user: $OLD_USER  (uid=$MFST_UID gid=$MFST_GID group=$MFST_PRIMARY_GROUP)"
log "Target user: $NEW_USER  (uid=$NEW_UID gid=$(id -g) group=$NEW_PRIMARY_GROUP)"
if [[ "$CROSS_USER" -eq 1 ]]; then
  warn "Cross-user restore. All restored files will be owned by $NEW_USER:$NEW_PRIMARY_GROUP."
  warn "Embedded /Users/$OLD_USER paths will be sed-patched in known config files."
fi

# Group reconciliation — flag any non-system groups the source had that the
# target doesn't, with a copy-paste fix.
missing_groups=()
IFS=',' read -r -a old_groups_arr <<< "$MFST_GROUPS"
for g in "${old_groups_arr[@]}"; do
  [[ -z "$g" ]] && continue
  # Skip groups every macOS user is auto-added to. Keep underscore-prefixed
  # capability groups (_developer, _lpadmin, _appserveradm, etc.) and named
  # groups like com.apple.access_ssh — those matter and may be missing.
  case "$g" in
    everyone|localaccounts|_analyticsusers|_appstore) continue ;;
  esac
  if ! id -Gn | tr ' ' '\n' | grep -qx "$g"; then
    missing_groups+=("$g")
  fi
done
if [[ ${#missing_groups[@]} -gt 0 ]]; then
  warn "Target user $NEW_USER is missing these source-user groups: ${missing_groups[*]}"
  warn "To add them (admin required):"
  for g in "${missing_groups[@]}"; do
    warn "  sudo dseditgroup -o edit -a $NEW_USER -t user $g"
  done
fi

# Patches embedded /Users/$OLD_USER → /Users/$NEW_USER in the given file.
# Backs up the original as <file>.pre-userpatch. No-op when not cross-user.
patch_user_paths() {
  [[ "$CROSS_USER" -eq 1 ]] || return 0
  local f="$1"
  [[ -f "$f" ]] || return 0
  if grep -q "/Users/$OLD_USER" "$f" 2>/dev/null; then
    cp "$f" "$f.pre-userpatch"
    # macOS sed: -i '' with a backup-suffix arg.
    sed -i '' "s|/Users/$OLD_USER|/Users/$NEW_USER|g" "$f"
    echo "  patched paths in $f"
  fi
}

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
      rsync -rlptD --backup --suffix=".pre-restore" \
        --no-owner --no-group \
        "$META_DIR/dotfiles/" "$HOME/"
      # Cross-user: patch /Users/<old> → /Users/<new> in known config files.
      while IFS= read -r f; do
        patch_user_paths "$f"
      done < <(find "$META_DIR/dotfiles" -type f | sed "s|^$META_DIR/dotfiles|$HOME|")
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
    rsync -rlptD --no-owner --no-group "$META_DIR/launchagents/" "$HOME/Library/LaunchAgents/"
    # Patch user paths BEFORE loading — a LaunchAgent referencing
    # /Users/<old>/scripts/foo.sh will fail silently otherwise.
    for plist in "$HOME/Library/LaunchAgents"/*.plist; do
      [[ -f "$plist" ]] || continue
      patch_user_paths "$plist"
      launchctl load -w "$plist" 2>/dev/null || true
    done
    ok "LaunchAgents restored"
  fi
  if [[ -s "$META_DIR/crontab.txt" ]] && ! grep -q '^# no crontab' "$META_DIR/crontab.txt"; then
    log "Restoring crontab"
    # Patch the crontab file (a copy) before installing it.
    cp "$META_DIR/crontab.txt" "$META_DIR/crontab.staged.txt"
    if [[ "$CROSS_USER" -eq 1 ]]; then
      sed -i '' "s|/Users/$OLD_USER|/Users/$NEW_USER|g" "$META_DIR/crontab.staged.txt"
    fi
    crontab "$META_DIR/crontab.staged.txt" && ok "crontab installed"
  fi
  # User fonts + KeyBindings + Services + Application Scripts captured by
  # backup.sh's services section. Copy them back if present.
  for d in Fonts KeyBindings Services "Application Scripts"; do
    src="$META_DIR/library/$d"
    [[ -d "$src" ]] || { src="$META_DIR/user-fonts"; [[ "$d" == "Fonts" && -d "$src" ]] || continue; }
    ensure_dir "$HOME/Library/$d"
    rsync -rlptD --no-owner --no-group "$src/" "$HOME/Library/$d/" 2>/dev/null \
      && echo "  restored Library/$d"
  done
fi

###############################################################################
# 7. Home directory mirror (LAST — non-destructive by default)
###############################################################################
if run_section rsync; then
  log "Restoring \$HOME from $HOME_MIRROR"
  if [[ ! -d "$HOME_MIRROR" ]]; then
    warn "No home mirror at $HOME_MIRROR — skipping"
  else
    # IMPORTANT:
    #   - No --delete: we add files from the mirror but don't remove anything
    #     the new Mac already has. Safe to re-run; won't nuke files a fresh
    #     ~ created on first login.
    #   - --no-owner --no-group: files end up owned by the running user
    #     (so cross-user restores Just Work without needing sudo or chown).
    #   - -rlptDhHPXA: same as -a minus -o/-g, plus extended attrs + ACLs.
    [[ -n "$DRY" ]] && log "Dry run — showing what WOULD change"
    rsync -rlptDhHPXA --no-owner --no-group --partial $DRY \
      --exclude-from="$SCRIPT_DIR/rsync-excludes.txt" \
      "$HOME_MIRROR/" "$HOME/" \
      | tee "$META_DIR/restore-$TS.log" >/dev/null
    ok "Home restore complete"

    # Cross-user path patching on a curated set of likely-config files.
    # Conservative on purpose — we don't sed every file in $HOME.
    if [[ "$CROSS_USER" -eq 1 && -z "$DRY" ]]; then
      log "Patching embedded /Users/$OLD_USER paths"
      patch_targets=(
        "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.zlogin" "$HOME/.zlogout"
        "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.inputrc"
        "$HOME/.gitconfig" "$HOME/.config/git/config"
        "$HOME/.ssh/config"
        "$HOME/.npmrc" "$HOME/.yarnrc" "$HOME/.yarnrc.yml"
        "$HOME/.config/starship.toml"
        "$HOME/.tmux.conf"
      )
      for f in "${patch_targets[@]}"; do
        patch_user_paths "$f"
      done
      # LaunchAgents that came in via the rsync (vs the services step).
      for plist in "$HOME/Library/LaunchAgents"/*.plist; do
        [[ -f "$plist" ]] && patch_user_paths "$plist"
      done
    fi
  fi
fi

###############################################################################
# 8. System-level restore (sudo). Opt-in; not part of the default run.
# Restore with:  ./restore.sh --only system
###############################################################################
if run_section system; then
  if [[ -d "$META_DIR/system" ]]; then
    log "Restoring system-level files (sudo)"
    if confirm "About to copy back /etc/hosts, /etc/sudoers.d, /Library/LaunchDaemons, /etc/cups. Continue?"; then
      [[ -f "$META_DIR/system/etc/hosts" ]] && \
        sudo cp "$META_DIR/system/etc/hosts" /etc/hosts && echo "  /etc/hosts"
      [[ -d "$META_DIR/system/etc/sudoers.d" ]] && \
        sudo rsync -a "$META_DIR/system/etc/sudoers.d/" /etc/sudoers.d/ && echo "  /etc/sudoers.d"
      [[ -d "$META_DIR/system/etc/ssh_config.d" ]] && \
        sudo rsync -a "$META_DIR/system/etc/ssh_config.d/" /etc/ssh/ssh_config.d/ && echo "  /etc/ssh/ssh_config.d"
      [[ -d "$META_DIR/system/launchdaemons" ]] && \
        sudo rsync -a "$META_DIR/system/launchdaemons/" /Library/LaunchDaemons/ && echo "  /Library/LaunchDaemons"
      [[ -f "$META_DIR/system/cups/printers.conf" ]] && \
        sudo cp "$META_DIR/system/cups/printers.conf" /etc/cups/printers.conf && echo "  CUPS printers.conf"
      [[ -d "$META_DIR/system/cups/ppd" ]] && \
        sudo rsync -a "$META_DIR/system/cups/ppd/" /etc/cups/ppd/ && echo "  CUPS PPDs"
      ok "System-level files restored. You may need to: sudo killall -HUP launchd"
    else
      warn "Skipped system restore"
    fi
  fi
fi

log "Restore done. Recommended next steps:"
cat <<EOF
  1. Sign into Apple ID / iCloud (Messages, Mail, Photos, Mobile Documents resync)
  2. Sign into App Store, then re-run:  ./restore.sh --only brew
     (mas apps will install once you're signed in)
  3. Run the GUI-only settings script:  osascript macos-settings.applescript
  4. Restart Dock/Finder to apply defaults:  killall Dock Finder SystemUIServer
  5. Open Keychain Access and verify SSH key passphrases / app logins
  6. Reauthorize app permissions in System Settings → Privacy & Security
     (the TCC database does NOT migrate — every app re-prompts for camera,
     mic, accessibility, full-disk access, screen recording, etc.)
  7. Re-add Wi-Fi networks if you didn't have iCloud Keychain enabled
  8. Re-pair Bluetooth devices (pairings don't migrate)
  9. Re-add Calendar/Mail/Contacts accounts if not iCloud (passwords were
     in the Keychain, which doesn't import cleanly across machines)
EOF
if [[ "$CROSS_USER" -eq 1 ]]; then
  cat <<EOF

  Cross-user restore notes ($OLD_USER → $NEW_USER):
   - File ownership: all restored files are owned by $NEW_USER:$NEW_PRIMARY_GROUP.
   - Path patching: dotfiles, LaunchAgents, and crontab had /Users/$OLD_USER
     → /Users/$NEW_USER replacements. Originals saved as *.pre-userpatch.
   - Search for any other /Users/$OLD_USER references with:
       grep -rl "/Users/$OLD_USER" "\$HOME" --exclude-dir=Library 2>/dev/null
   - If missing groups (admin, _developer, etc.) were flagged above,
     re-run those \`sudo dseditgroup\` commands.
EOF
fi
