#!/usr/bin/env bash
# backup.sh — run on the OLD Mac to snapshot everything to the external drive.
#
# Usage:
#   export BACKUP_ROOT=/Volumes/YourDrive/macbackup   # REQUIRED — no default
#   ./backup.sh                 # full run
#   ./backup.sh --skip-rsync    # everything except the home mirror (fast)
#   ./backup.sh --only rsync    # just the home mirror
#
# Requirements: Homebrew + mas. The script exits if mas is missing (otherwise
# Mac App Store apps would be silently dropped from the Brewfile).
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
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
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
# Identity fields (uid/gid/groups/full name) are critical for the cross-user
# restore path — restore.sh translates ownership and patches embedded
# /Users/<old> paths based on these values.
cat > "$META_DIR/manifest.txt" <<EOF
source_host: $SOURCE_HOST
source_user: $(whoami)
source_uid: $(id -u)
source_gid: $(id -g)
source_primary_group: $(id -gn)
source_groups: $(id -Gn | tr ' ' ',')
source_full_name: $(id -F 2>/dev/null || echo "")
source_home: $HOME
source_shell: $SHELL
source_local_hostname: $(scutil --get LocalHostName 2>/dev/null || echo "")
source_hostname: $(scutil --get HostName 2>/dev/null || echo "")
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
    # mas is required so the Brewfile picks up Mac App Store apps.
    # Skip the check with: ./backup.sh --skip brew  (or run without mas at
    # your own risk by editing this block).
    if ! command -v mas >/dev/null 2>&1; then
      die "mas not installed — Mac App Store apps would be silently omitted. Install with: brew install mas"
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
  log "Exporting VS Code / Cursor extensions + user settings"
  for cli in code cursor code-insiders; do
    if command -v "$cli" >/dev/null 2>&1; then
      "$cli" --list-extensions > "$META_DIR/${cli}-extensions.txt" 2>/dev/null || true
      ok "$cli extensions: $(wc -l < "$META_DIR/${cli}-extensions.txt" | tr -d ' ')"
    fi
  done
  # User settings.json, keybindings.json, snippets/ — these are NOT covered by
  # --list-extensions but are usually what makes the editor feel like yours.
  declare -A vsdirs=(
    [code]="$HOME/Library/Application Support/Code/User"
    [cursor]="$HOME/Library/Application Support/Cursor/User"
    [code-insiders]="$HOME/Library/Application Support/Code - Insiders/User"
  )
  for key in "${!vsdirs[@]}"; do
    src="${vsdirs[$key]}"
    if [[ -d "$src" ]]; then
      dest="$META_DIR/editor-settings/$key"
      ensure_dir "$dest"
      for item in settings.json keybindings.json snippets globalStorage/state.vscdb; do
        [[ -e "$src/$item" ]] && rsync -a --relative "$src/./$item" "$dest/" 2>/dev/null || true
      done
      ok "$key user settings exported"
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
  log "Exporting user-level services and misc helpers"
  ensure_dir "$META_DIR/launchagents"
  if [[ -d "$HOME/Library/LaunchAgents" ]]; then
    rsync -a "$HOME/Library/LaunchAgents/" "$META_DIR/launchagents/"
  fi
  crontab -l > "$META_DIR/crontab.txt" 2>/dev/null || echo "# no crontab" > "$META_DIR/crontab.txt"
  # Login items (the user-visible "Open at Login" list).
  osascript -e 'tell application "System Events" to get the name of every login item' \
    > "$META_DIR/login-items.txt" 2>/dev/null || true
  # Time Machine exclusions — easy to miss, painful to recreate.
  tmutil listexclusions > "$META_DIR/timemachine-exclusions.txt" 2>/dev/null || true
  # User-installed fonts (separate from system fonts).
  if [[ -d "$HOME/Library/Fonts" ]]; then
    ensure_dir "$META_DIR/user-fonts"
    rsync -a "$HOME/Library/Fonts/" "$META_DIR/user-fonts/" 2>/dev/null || true
  fi
  # Custom keyboard bindings (e.g. DefaultKeyBinding.dict) + Quick Actions.
  for d in KeyBindings Services "Application Scripts"; do
    if [[ -d "$HOME/Library/$d" ]]; then
      ensure_dir "$META_DIR/library/$d"
      rsync -a "$HOME/Library/$d/" "$META_DIR/library/$d/" 2>/dev/null || true
    fi
  done
  ok "Services exported"
fi

###############################################################################
# 6b. System-level (sudo) — /etc/hosts, sudoers.d, LaunchDaemons, CUPS, etc.
# Requires sudo. Skips silently if sudo isn't already cached.
###############################################################################
if run_section system; then
  log "Exporting system-level files (sudo)"
  if sudo -n true 2>/dev/null; then
    ensure_dir "$META_DIR/system/etc" "$META_DIR/system/launchdaemons" "$META_DIR/system/cups"
    # /etc/hosts — almost always has manual edits worth preserving.
    sudo cp /etc/hosts "$META_DIR/system/etc/hosts" 2>/dev/null || true
    # /etc/sudoers.d — custom sudo rules (excluding the default empty).
    if [[ -d /etc/sudoers.d ]]; then
      sudo rsync -a /etc/sudoers.d/ "$META_DIR/system/etc/sudoers.d/" 2>/dev/null || true
    fi
    # /etc/ssh/ssh_config.d — per-machine ssh client tweaks.
    [[ -d /etc/ssh/ssh_config.d ]] && \
      sudo rsync -a /etc/ssh/ssh_config.d/ "$META_DIR/system/etc/ssh_config.d/" 2>/dev/null || true
    # /Library/LaunchDaemons — system-wide background services.
    if [[ -d /Library/LaunchDaemons ]]; then
      sudo rsync -a /Library/LaunchDaemons/ "$META_DIR/system/launchdaemons/" 2>/dev/null || true
    fi
    # CUPS printers (system-wide).
    for f in /etc/cups/printers.conf /etc/cups/ppd; do
      [[ -e "$f" ]] && sudo cp -a "$f" "$META_DIR/system/cups/" 2>/dev/null || true
    done
    # Make the copies readable by your user for the rsync to the drive.
    sudo chown -R "$(whoami):staff" "$META_DIR/system" 2>/dev/null || true
    ok "System-level files exported"
  else
    warn "sudo not cached — run \`sudo -v\` then re-run with --only system to capture /etc/hosts, sudoers.d, LaunchDaemons, CUPS"
  fi
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
  rsync -ahHP --numeric-ids --partial --delete-excluded \
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
