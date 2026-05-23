-- macos-settings.applescript
-- Run on the NEW Mac after restore.sh, for GUI-only settings that don't
-- live in `defaults`. Edit the lists below to match what you actually want.
--
-- Usage:  osascript macos-settings.applescript

-- ====== EDIT THESE LISTS ======

-- Login items: apps to launch automatically at login.
-- Use full POSIX paths to .app bundles.
property loginItems : {¬
	"/Applications/1Password.app", ¬
	"/Applications/Rectangle.app", ¬
	"/Applications/Slack.app" ¬
}

-- Dock items: apps to add to the Dock (in order). Optional.
-- Leave empty to skip Dock changes (restore via `defaults` is usually enough).
property dockItems : {} -- e.g. {"/Applications/Safari.app", "/Applications/Mail.app"}

-- Finder favorites (sidebar). AppleScript can't directly edit favorites in
-- modern macOS; the most reliable way is `defaults` + a Finder restart, which
-- restore.sh already does. So this script intentionally doesn't touch them.

-- ====== IMPLEMENTATION (edit if you know what you're doing) ======

on addLoginItem(appPath)
	tell application "System Events"
		set appName to do shell script "basename " & quoted form of appPath & " .app"
		if not (exists login item appName) then
			make new login item at end with properties ¬
				{path:appPath, hidden:false, name:appName}
			log "  + login item: " & appName
		else
			log "  = login item already present: " & appName
		end if
	end tell
end addLoginItem

on addDockItem(appPath)
	-- Uses `dockutil` if installed (brew install dockutil). Falls back to nothing.
	try
		do shell script "command -v dockutil >/dev/null 2>&1"
		do shell script "dockutil --add " & quoted form of appPath & " --no-restart"
		log "  + dock: " & appPath
	on error
		log "  ! dockutil not installed; skipping " & appPath & " (brew install dockutil)"
	end try
end addDockItem

-- Apply login items
log "Configuring login items…"
repeat with p in loginItems
	try
		addLoginItem(p as text)
	on error errMsg
		log "  ! failed: " & p & " (" & errMsg & ")"
	end try
end repeat

-- Apply dock items (if any)
if (count of dockItems) > 0 then
	log "Configuring Dock…"
	repeat with p in dockItems
		addDockItem(p as text)
	end repeat
	try
		do shell script "killall Dock"
	end try
end if

-- A handful of toggles that don't have stable `defaults` keys.
log "Misc settings…"

-- Show Bluetooth in menu bar (Big Sur+: Control Center)
try
	do shell script "defaults -currentHost write com.apple.controlcenter Bluetooth -int 18"
end try

-- Enable tap-to-click on the trackpad for login screen + current user
try
	do shell script "defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true"
	do shell script "defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true"
	do shell script "defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1"
end try

-- Show file extensions in Finder
try
	do shell script "defaults write NSGlobalDomain AppleShowAllExtensions -bool true"
end try

log "Done. You may need to log out and back in for some changes to take effect."
