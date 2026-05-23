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

Sections: `brew`, `apps`, `langs`, `vscode`, `defaults`, `services`, `dotfiles`, `rsync`.

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
