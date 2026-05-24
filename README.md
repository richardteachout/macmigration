# macmigration

A two-script toolkit for migrating a macOS user environment to a new Mac via an
external drive. Mirrors `$HOME` with `rsync` and separately captures the things
rsync alone won't bring across cleanly — Homebrew, language globals, VS Code
extensions, `defaults` plists, LaunchAgents, crontab, and login items.

Designed to be **safe to re-run**: the restore script never deletes files,
backs up any overwritten dotfiles to `*.pre-restore`, and prompts before the
destructive-ish steps.

## What's in the box

| File | Purpose |
| --- | --- |
| [`backup.sh`](backup.sh) | Run on the **OLD** Mac. Writes everything to the drive. |
| [`restore.sh`](restore.sh) | Run on the **NEW** Mac. Rehydrates from the drive. |
| [`purge.sh`](purge.sh) | Manually delete a backup tree from the external drive. Never auto-invoked. |
| [`config.sh`](config.sh) | Shared paths & helpers. Sourced by all three scripts. |
| [`rsync-excludes.txt`](rsync-excludes.txt) | Caches, build artifacts, iCloud, Mail/Messages/Photos. |
| [`macos-settings.applescript`](macos-settings.applescript) | GUI-only settings (login items, Dock items, etc.). |

`backup.sh` and `restore.sh` are split into numbered sections. Run all of them
or use `--only <section>` / `--skip <section>` to do one at a time.

Sections: `brew`, `apps`, `langs`, `vscode`, `defaults`, `services`, `system` (sudo, opt-in), `dotfiles`, `rsync`.

`restore.sh` also runs a **preflight** (Xcode CLT + Homebrew + `mas`)
unconditionally — even with `--only`/`--skip` — because every section needs at
least the baseline. The checks are no-ops when those are already installed.

---

## Prerequisites

- An external drive (USB / Thunderbolt). **Use an encrypted format** (APFS
  Encrypted, or FileVault on the volume) — the backup will contain `~/.ssh`,
  `~/.aws`, `~/.gnupg`, browser profiles, and other secrets in plaintext.
- **`BACKUP_ROOT` must be set in your environment.** Both scripts refuse to
  run without it — there is no default, so you can't accidentally write a
  multi-GB backup to the wrong path:
  ```bash
  export BACKUP_ROOT=/Volumes/YourDrive/macbackup
  ```
- On the old Mac: Homebrew **and `mas`** (`brew install mas`). `backup.sh`
  hard-fails if `mas` is missing — otherwise your Mac App Store apps would be
  silently dropped from the Brewfile.
- On the new Mac: nothing. `restore.sh` installs Xcode CLT and Homebrew on
  first run.

---

## Old Mac — back up

```bash
# Clone or copy the scripts somewhere, then:
cd macmigration

# BACKUP_ROOT is required — scripts exit immediately if it's unset.
export BACKUP_ROOT=/Volumes/MyDrive/macbackup
./backup.sh
```

Run sections individually if you want to iterate:

```bash
./backup.sh --only brew      # just regenerate Brewfile
./backup.sh --only defaults  # just re-export macOS settings
./backup.sh --skip rsync     # everything except the slow home mirror
```

When it finishes, the drive layout is:

```
/Volumes/MyDrive/macbackup/
├── home/<username>/          # rsync mirror of $HOME
└── meta/
    ├── manifest.txt          # source host, macOS version, timestamp
    ├── Brewfile              # taps/formulae/casks/MAS apps
    ├── brew-*.txt            # human-readable lists
    ├── applications.txt      # /Applications inventory
    ├── npm-global.json, pipx-list.json, gem-list.txt, ...
    ├── code-extensions.txt, cursor-extensions.txt
    ├── defaults/             # one .plist per domain + reference dumps
    ├── launchagents/         # ~/Library/LaunchAgents copy
    ├── crontab.txt
    ├── login-items.txt
    ├── dotfiles/             # ~25 known dotfiles snapshotted
    └── rsync-<timestamp>.log
```

### Why does the backup size sometimes *shrink* between runs?

The home mirror uses `--delete-excluded`, which **removes files on the
backup that match an exclude pattern** (e.g. `Library/Caches`, `node_modules`).
This is intentional — it keeps the backup from accumulating stale cache
cruft that an interrupted earlier run may have copied before reaching its
exclude rule. There is **no plain `--delete`**, so files you delete from
`$HOME` are still kept on the backup. Only paths matching `rsync-excludes.txt`
get pruned. If you'd rather have a strictly-additive backup, drop
`--delete-excluded` from the rsync line in [`backup.sh`](backup.sh).

During the home mirror, `backup.sh` runs `rsync` with visible progress and
double-verbose output. Paths skipped by `rsync-excludes.txt` show up as filter
messages in the terminal and in `meta/rsync-<timestamp>.log`.

---

## New Mac — restore

```bash
git clone https://github.com/richardteachout/macmigration.git
cd macmigration

# Plug in the drive, then (BACKUP_ROOT is required):
export BACKUP_ROOT=/Volumes/MyDrive/macbackup
./restore.sh
```

The script will:

1. **prereqs** — Install Xcode Command Line Tools and Homebrew if missing.
   (CLT install pops a GUI prompt — re-run the script after it finishes.)
2. **brew** — `brew bundle` from the captured Brewfile.
3. **dotfiles** — Overlay the snapshotted dotfiles (prompts first; existing
   files saved as `<name>.pre-restore`).
4. **langs** — Re-install npm/pipx/uv globals.
5. **vscode** — Re-install VS Code / Cursor extensions.
6. **defaults** — `defaults import` each domain (prompts first).
7. **services** — Copy LaunchAgents back and `launchctl load` them; restore crontab.
8. **rsync** — Pull the home mirror onto the new Mac. **No `--delete`** — files
   already on the new Mac are kept.

Useful invocations:

```bash
./restore.sh --dry-run --only rsync   # preview home diff before committing
./restore.sh --only brew              # re-run after signing into App Store (for MAS apps)
./restore.sh --skip defaults          # everything except macOS settings
./restore.sh -y                       # assume yes to confirm prompts
```

After it finishes:

```bash
# Apply GUI-only settings (edit the lists at the top of the file first):
osascript macos-settings.applescript

# Pick up defaults changes immediately:
killall Dock Finder SystemUIServer
```

Then sign into Apple ID / iCloud — Messages, Mail, Photos, and iCloud Drive
re-sync on their own (they were deliberately excluded from the rsync to avoid
huge transfer and sync conflicts).

---

## Different usernames between old and new Mac

The kit handles the case where your new Mac uses a different short username
(e.g. `oldjoe` → `joe`).

**On the old Mac:** nothing special — `backup.sh` writes an identity block
into `meta/manifest.txt` (uid, gid, primary group, full group list, etc.)
and stores the home mirror under `home/<oldname>/`.

**On the new Mac:** `restore.sh` reads the manifest:

- If the new user's name matches the manifest, restore proceeds normally.
- Otherwise, it tries `BACKUP_ROOT/home/<manifest user>`. If that exists, it
  uses that path. If not, it lists what's available under `home/` and
  prompts: `Enter old username:`.
- You can also pre-set it: `OLD_USER=oldjoe ./restore.sh`.

**Ownership behaviour** is chosen automatically based on the identity match:

| New Mac vs. backup | rsync flags | Result |
| --- | --- | --- |
| Same username **and** same UID/GID | `--owner --group --numeric-ids` | Ownership preserved verbatim from the backup (matters for `~/.ssh`, postgres data dirs, etc.). |
| Same username, different UID or GID | `--no-owner --no-group` | Files end up owned by the running user. Restore warns you and suggests `sudo ./restore.sh --only rsync` if you really want the old numeric IDs. |
| Different username | `--no-owner --no-group` + path patching | Files owned by the running user, `/Users/<old>` paths sed-patched. No sudo needed. |

What the cross-user path does additionally:
- **Path patching:** known config files have `/Users/<old>` →
  `/Users/<new>` sed-replaced after copy. This covers `.zshrc`, `.zprofile`,
  `.gitconfig`, `.ssh/config`, `.npmrc`, `.tmux.conf`, every LaunchAgent
  plist, and the crontab. Originals are saved as `<name>.pre-userpatch`.
  To catch anything else: `grep -rl /Users/<old> $HOME --exclude-dir=Library`.
- **Group reconciliation:** restore compares the source-user's group list
  to the new user's. For each missing non-trivial group (e.g. `admin`,
  `_developer`, `_lpadmin`, `com.apple.access_ssh`), it prints the exact
  `sudo dseditgroup -o edit -a <newuser> -t user <group>` command to fix it.

---

## What does NOT migrate cleanly

Some things macOS deliberately makes hard to move between machines. The
restore script reminds you of these at the end:

- **Keychain passwords** — `login.keychain-db` is in the rsync but it depends
  on the user's password + per-device secrets and usually won't unlock on a
  new Mac. Use **iCloud Keychain** to bring across Wi-Fi, web, and app
  passwords. Plan to re-enter SSH key passphrases.
- **TCC privacy permissions** (camera, mic, screen recording, accessibility,
  full-disk access) — the TCC database is not migratable. Every app will
  re-prompt on first use; reauthorize them in System Settings → Privacy &
  Security.
- **Bluetooth pairings** — re-pair each device.
- **Wi-Fi networks** — restored via iCloud Keychain if enabled, otherwise
  re-enter.
- **FileVault recovery keys** — per-device, not transferable.
- **Mail / Calendar / Contacts accounts** — the account *definitions* are in
  `~/Library/Mail`, `~/Library/Calendars`, `~/Library/Application Support/AddressBook`
  (excluded from rsync — they re-sync from iCloud / will re-prompt for IMAP
  passwords). For non-iCloud (CalDAV / CardDAV / Exchange) accounts you'll
  re-add the server + credentials.
- **App-specific licenses / activations** — 1Password unlock, JetBrains
  toolbox, Adobe CC, MS Office, Setapp, etc. expect to re-sign-in.
- **Touch ID enrollments + passkey hardware** — per-device.
- **Notification permissions and Focus modes** — re-grant on first run.
- **System printers + drivers** — `backup.sh --only system` (sudo) captures
  `/etc/cups/printers.conf` and PPDs; `restore.sh --only system` puts them
  back. You may still need to re-install vendor driver bundles for some
  printers.
- **LaunchDaemons** (`/Library/LaunchDaemons`) — captured/restored by the
  `system` section (sudo). User-level LaunchAgents are covered by the normal
  `services` section.
- **/etc/hosts, /etc/sudoers.d, /etc/ssh/ssh_config.d** — captured by
  `--only system`. Skipped silently if `sudo` isn't cached when `backup.sh`
  runs; cache it with `sudo -v` first, then `./backup.sh --only system`.

---

## Purging the backup

Once you've finished the migration and verified the new Mac works, free up the
drive with [`purge.sh`](purge.sh). It's **manual only** — `restore.sh` will
never call it for you.

```bash
export BACKUP_ROOT=/Volumes/MyDrive/macbackup
./purge.sh --dry-run            # preview what would be deleted
./purge.sh                      # delete everything (prompts for "PURGE")
./purge.sh --meta-only          # keep the home mirror, delete only meta/
./purge.sh --home-only          # keep meta/, delete only the home mirror
./purge.sh -y                   # skip the typed confirmation
```

Safety rails (any one of these aborts the run):

1. `BACKUP_ROOT` must be set (no default).
2. The canonical path is checked against a blocklist of bare system / top-level
   paths (`/`, `/Users`, `/Volumes`, `/System`, `/tmp`, etc.).
3. Path must be at least 3 components deep (so `/Volumes/X` is rejected,
   `/Volumes/X/macbackup` is OK).
4. The directory must contain `meta/manifest.txt` or `home/` — otherwise
   it doesn't look like a macmigration backup and the script refuses.
5. You must type `PURGE` (in capitals) unless you pass `-y`.

---

## Customizing

- **Backup destination:** export `BACKUP_ROOT` before running any script.
  There is no default — see [Prerequisites](#prerequisites).
- **What rsync copies:** edit [`rsync-excludes.txt`](rsync-excludes.txt).
  Patterns are relative to `$HOME`. If you want Mail, Messages, Photos, or
  iCloud Drive in the mirror, delete the matching lines.
- **Which dotfiles get snapshotted:** edit the `files=( ... )` array in the
  `dotfiles` section of [`backup.sh`](backup.sh).
- **Which `defaults` domains get exported:** edit the `domains=( ... )` array
  in the `defaults` section of [`backup.sh`](backup.sh).
- **Login items / Dock:** edit the `loginItems` and `dockItems` properties at
  the top of [`macos-settings.applescript`](macos-settings.applescript).
  Dock changes use `dockutil` (`brew install dockutil`).

---

## Safety notes

- **Secrets ride along plaintext.** `~/.ssh`, `~/.aws`, `~/.gnupg`,
  `.env` files, browser cookies, and similar are all in the rsync mirror.
  Use an encrypted drive.
- **The Keychain is NOT exported.** macOS deliberately makes that hard.
  You'll re-enter app/website passwords on the new Mac, or use iCloud Keychain
  to bring them across.
- **MAS apps need App Store login.** They'll be listed in the Brewfile but
  won't install until you've signed in. After signing in, run
  `./restore.sh --only brew`.
- **Restore is non-destructive.** The home rsync has no `--delete`, so re-runs
  add files but never remove. Safe to run partial sections repeatedly.
