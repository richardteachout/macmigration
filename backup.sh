#!/usr/bin/env bash
# backup.sh — run on the OLD Mac to snapshot everything to the external drive.
#
# Usage:
#   ./backup.sh                 # full run
#   ./backup.sh --skip-rsync    # everything except the home mirror (fast)
#   ./backup.sh --only rsync    # just the home mirror
#   BACKUP_ROOT=/Volumes/X ./backup.sh
#
# Each section is independent — comment out anything you don't want.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

ONLY=""; SKIP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --skip) SKIP="$2"; shift 2 ;;
    --skip-rsync) SKIP="rsync"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done
run_section() {
  local name="$1"
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 1
  [[ -n "$SKIP" && "$SKIP" == "$name" ]] && return 1
  return 0
}

require_backup_volume
ensure_dir "$META_DIR" "$HOME_MIRROR"
log "Backup root: $BACKUP_ROOT"
log "Source host: $SOURCE_HOST  user: $(whoami)"

# Write a manifest at the top so restore.sh knows what it's reading.
cat > "$META_DIR/manifest.txt" <<EOF
source_host: $SOURCE_HOST
source_user: $(whoami)
source_home: $HOME
backup_time: $TS
macos_version: $(sw_vers -productVersion)
arch: $(uname -m)
EOF

###############################################################################
# 1. Homebrew — taps, formulae, casks, MAS apps
###############################################################################
if run_section brew; then
  log "Exporting Homebrew bundle"
  if command -v brew >/dev/null 2>&1; then
    # Install mas first if missing so the Brewfile picks up App Store apps.
    if ! command -v mas >/dev/null 2>&1; then
      warn "mas not installed — Mac App Store apps will be omitted from Brewfile."
      warn "Install with: brew install mas"
    fi
    brew bundle dump --force --file="$META_DIR/Brewfile"
    brew list --formula --versions > "$META_DIR/brew-formulae.txt"
    brew list --cask     --versions > "$META_DIR/brew-casks.txt"   2>/dev/null || true
    brew tap                        > "$META_DIR/brew-taps.txt"
    brew --version                  > "$META_DIR/brew-version.txt"
    ok "Brewfile written ($(wc -l < "$META_DIR/Brewfile" | tr -d ' ') lines)"
  else
    warn "Homebrew not installed — skipping brew export"
  fi
fi

###############################################################################
# 2. /Applications inventory (for diffing what brew didn't capture)
###############################################################################
if run_section apps; then
  log "Inventorying /Applications"
  ls -1 /Applications      > "$META_DIR/applications.txt"
  ls -1 "$HOME/Applications" 2>/dev/null > "$META_DIR/applications-user.txt" || true
  system_profiler SPApplicationsDataType -json \
    > "$META_DIR/applications-full.json" 2>/dev/null || true
  ok "App inventory saved"
fi

###############################################################################
# 3. Language ecosystems (global packages)
###############################################################################
if run_section langs; then
  log "Exporting language ecosystems"
  # Node
  command -v npm  >/dev/null && npm list -g --depth=0 --json   > "$META_DIR/npm-global.json"   2>/dev/null || true
  command -v yarn >/dev/null && yarn global list --json        > "$META_DIR/yarn-global.json"  2>/dev/null || true
  command -v pnpm >/dev/null && pnpm list -g --depth=0 --json  > "$META_DIR/pnpm-global.json"  2>/dev/null || true
  # Python
  command -v pip  >/dev/null && pip  freeze                    > "$META_DIR/pip-freeze.txt"    2>/dev/null || true
  command -v pip3 >/dev/null && pip3 freeze                    > "$META_DIR/pip3-freeze.txt"   2>/dev/null || true
  command -v pipx >/dev/null && pipx list --json               > "$META_DIR/pipx-list.json"    2>/dev/null || true
  command -v uv   >/dev/null && uv tool list                   > "$META_DIR/uv-tools.txt"      2>/dev/null || true
  # Ruby / Go / Rust
  command -v gem    >/dev/null && gem list                     > "$META_DIR/gem-list.txt"      2>/dev/null || true
  command -v go     >/dev/null && go env GOBIN GOPATH          > "$META_DIR/go-env.txt"        2>/dev/null || true
  command -v cargo  >/dev/null && ls "$HOME/.cargo/bin" 2>/dev/null > "$META_DIR/cargo-bins.txt" || true
  # Version managers
  command -v asdf   >/dev/null && asdf current                 > "$META_DIR/asdf-current.txt"  2>/dev/null || true
  command -v mise   >/dev/null && mise list                    > "$META_DIR/mise-list.txt"     2>/dev/null || true
  command -v nvm    >/dev/null && nvm ls                       > "$META_DIR/nvm-ls.txt"        2>/dev/null || true
  ok "Language inventories saved"
fi

###############################################################################
# 4. VS Code / Cursor — extensions and settings
###############################################################################
if run_section vscode; then
  log "Exporting VS Code / Cursor extensions"
  for cli in code cursor code-insiders; do
    if command -v "$cli" >/dev/null 2>&1; then
      "$cli" --list-extensions > "$META_DIR/${cli}-extensions.txt" 2>/dev/null || true
      ok "$cli extensions: $(wc -l < "$META_DIR/${cli}-extensions.txt" | tr -d ' ')"
    fi
  done
fi

###############################################################################
# 5. macOS defaults — common domains + global
###############################################################################
if run_section defaults; then
  log "Exporting macOS defaults"
  local_defaults_dir="$META_DIR/defaults"
  ensure_dir "$local_defaults_dir"
  domains=(
    NSGlobalDomain
    com.apple.dock
    com.apple.finder
    com.apple.systempreferences
    com.apple.universalaccess
    com.apple.HIToolbox
    com.apple.symbolichotkeys
    com.apple.AppleMultitouchTrackpad
    com.apple.driver.AppleBluetoothMultitouch.trackpad
    com.apple.AppleMultitouchMouse
    com.apple.driver.AppleBluetoothMultitouch.mouse
    com.apple.menuextra.clock
    com.apple.screencapture
    com.apple.screensaver
    com.apple.Terminal
    com.googlecode.iterm2
    com.apple.controlcenter
    com.apple.menuextra.battery
    com.apple.TextEdit
    com.apple.Safari
    com.apple.spotlight
    com.apple.assistant.support
  )
  for d in "${domains[@]}"; do
    defaults export "$d" "$local_defaults_dir/$d.plist" 2>/dev/null \
      && echo "  exported $d" \
      || echo "  (none) $d"
  done
  # Full reference dump (text) for searchability.
  defaults read    > "$local_defaults_dir/_all-defaults.txt"    2>/dev/null || true
  defaults read -g > "$local_defaults_dir/_global-defaults.txt" 2>/dev/null || true
  ok "Defaults exported to $local_defaults_dir"
fi

###############################################################################
# 6. LaunchAgents, crontab, login items
###############################################################################
if run_section services; then
  log "Exporting LaunchAgents and cron"
  ensure_dir "$META_DIR/launchagents"
  if [[ -d "$HOME/Library/LaunchAgents" ]]; then
    rsync -a "$HOME/Library/LaunchAgents/" "$META_DIR/launchagents/"
  fi
  crontab -l > "$META_DIR/crontab.txt" 2>/dev/null || echo "# no crontab" > "$META_DIR/crontab.txt"
  # Login items (the user-visible "Open at Login" list).
  osascript -e 'tell application "System Events" to get the name of every login item' \
    > "$META_DIR/login-items.txt" 2>/dev/null || true
  ok "Services exported"
fi

###############################################################################
# 7. Shell & dotfile snapshot (small copy — separate from the rsync mirror)
###############################################################################
if run_section dotfiles; then
  log "Snapshotting key dotfiles"
  ensure_dir "$META_DIR/dotfiles"
  files=(
    .zshrc .zprofile .zshenv .zlogin .zlogout
    .bashrc .bash_profile .profile .inputrc
    .gitconfig .gitignore_global .gitattributes
    .npmrc .yarnrc .yarnrc.yml
    .vimrc .ideavimrc
    .tmux.conf .screenrc
    .editorconfig
    .ssh/config
    .config/starship.toml
    .config/git/config
    .aws/config
  )
  for f in "${files[@]}"; do
    if [[ -e "$HOME/$f" ]]; then
      target="$META_DIR/dotfiles/$f"
      mkdir -p "$(dirname "$target")"
      cp -a "$HOME/$f" "$target"
    fi
  done
  ok "Dotfile snapshot saved to $META_DIR/dotfiles"
fi

###############################################################################
# 8. Home directory mirror (the big one)
###############################################################################
if run_section rsync; then
  log "rsync-ing \$HOME → $HOME_MIRROR (this is the long step)"
  excludes="$SCRIPT_DIR/rsync-excludes.txt"
  [[ -f "$excludes" ]] || die "Missing $excludes"
  ensure_dir "$HOME_MIRROR"
  # -a archive, -h human, -P partial+progress, -H preserve hardlinks, -X xattrs, -A ACLs
  # --numeric-ids: don't try to map uid/gid (you'll restore as your new user)
  # --delete-excluded: don't keep old cache cruft from prior runs
  rsync -ahHPXA --numeric-ids --partial --delete-excluded \
    --exclude-from="$excludes" \
    "$HOME/" "$HOME_MIRROR/" \
    | tee "$META_DIR/rsync-$TS.log" \
    >/dev/null
  ok "Home mirror complete"
fi

###############################################################################
# Done
###############################################################################
log "Backup finished. Contents:"
du -sh "$BACKUP_ROOT"/* 2>/dev/null || true
ok "Eject the drive safely: diskutil eject \"$(echo "$BACKUP_ROOT" | awk -F/ '{print "/"$2"/"$3}')\""
