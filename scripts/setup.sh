#!/bin/bash
# Installs claude-switch (swaps the Claude Code login for terminal and VS Code between saved accounts),
# its Claude Code hooks (session status, and a notification when Claude asks something or needs permission), and on macOS
# Claude Switch.app (menu bar usage, alerts, account switcher). Run through ./run.sh setup; re-run to reinstall.
# Uses the prebuilt app at the root when there is one (a packaged zip), otherwise builds from source.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq is missing: brew install jq (macOS) or your package manager (Linux)" >&2; exit 1; }

bin=$HOME/.local/bin
mkdir -p "$bin"
install -m 755 "$root/src/claude-switch" "$bin/claude-switch"
case ":$PATH:" in
  *":$bin:"*) ;;
  *) rc=$HOME/.zshrc; [ "$(uname)" = Darwin ] || rc=$HOME/.bashrc
     grep -qs '\.local/bin' "$rc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
     echo "Added ~/.local/bin to PATH in $rc; open a new terminal before using claude-switch." ;;
esac

# Hooks: what each Claude session is doing (shown in the menu bar app), and a notification when Claude asks something
# or needs permission. Added beside any hooks already there; the previous file is kept as settings.json.before-claude-switch.
"$bin/claude-switch" hooks install || echo "Skipped the Claude Code hooks; add them later with: claude-switch hooks install" >&2

if [ "$(uname)" != Darwin ]; then
  cat <<'DONE'
Installed claude-switch and its Claude Code hooks (the menu bar app is macOS only). For each account:
  run: claude-switch add      (or /login in Claude, then run: claude-switch save)
Then: claude-switch (next account) or claude-switch <email>. Restart open Claude sessions after each switch.
DONE
  exit 0
fi

app="$HOME/Applications/Claude Switch.app"
pkill -x ClaudeSwitch 2>/dev/null || true
if [ -d "$root/Claude Switch.app" ]; then
  rm -rf "$app"; mkdir -p "$HOME/Applications"
  cp -R "$root/Claude Switch.app" "$app"
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true  # copies that were downloaded or AirDropped are blocked otherwise
else
  echo "Building Claude Switch.app (about 40 seconds)..."
  bash "$root/scripts/build.sh" "$HOME/Applications"
fi

# Make Finder and Login Items pick up the icon now rather than after a cache refresh.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true
touch "$app"

# Start at login, unless it was turned off in the app's Settings.
if [ "$(defaults read local.claude-switch loginOff 2>/dev/null)" = 1 ]; then
  echo "Open at login is off (set in the app's Settings); leaving it off."
else
  mkdir -p ~/Library/LaunchAgents
  cat > ~/Library/LaunchAgents/local.claude-switch.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.claude-switch</string>
  <key>ProgramArguments</key><array><string>$app/Contents/MacOS/ClaudeSwitch</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
fi
open "$app"

cat <<'DONE'
Installed claude-switch, its Claude Code hooks, and Claude Switch.app (menu bar). For each account:
  run: claude-switch add      (or use "Add account…" in the menu bar)
Then:
  claude-switch            next saved account (after the last comes the first); also Control-Option-Command-S
  claude-switch <email>    that account
Restart open Claude sessions (terminal and VS Code) after each switch.
DONE
