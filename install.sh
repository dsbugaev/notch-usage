#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

CFG="$HOME/.config/notch-usage/config.json"
if [ ! -f "$CFG" ]; then
  mkdir -p "$(dirname "$CFG")"
  # Generate the initial config from Claude Code profile dirs that actually
  # exist: ~/.claude plus any ~/.claude-* holding a profile marker file.
  # config.example.json stays as documentation of the full format.
  ACCOUNTS=""
  add_account() {
    local entry="    { \"name\": \"$1\", \"configDir\": \"$2\" }"
    if [ -z "$ACCOUNTS" ]; then
      ACCOUNTS="$entry"
    else
      ACCOUNTS="$ACCOUNTS,
$entry"
    fi
  }
  [ -d "$HOME/.claude" ] && add_account "Claude" "~/.claude"
  for d in "$HOME"/.claude-*/; do
    [ -e "${d}.claude.json" ] || [ -e "${d}settings.json" ] || continue
    base=$(basename "$d")
    add_account "Claude (${base#.claude-})" "~/$base"
  done
  [ -z "$ACCOUNTS" ] && add_account "Claude" "~/.claude"
  cat > "$CFG" <<EOF
{
  "accounts": [
$ACCOUNTS
  ],
  "refreshSeconds": 300
}
EOF
  echo "config generated from existing profiles: $CFG"
fi

PLIST="$HOME/Library/LaunchAgents/ru.bugaev.notchusage.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
sed -e "s|__BIN__|$PWD/build/NotchUsage.app/Contents/MacOS/NotchUsage|" \
    -e "s|__HOME__|$HOME|" \
    launchagent.plist.template > "$PLIST"

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
pkill -x NotchUsage 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed and started (log: ~/Library/Logs/notchusage.log)"
if ! security dump-trust-settings 2>/dev/null | grep -q "NotchUsage Signing"; then
  echo "tip: to stop keychain dialogs from reappearing after rebuilds, trust the"
  echo "     signing certificate once (see README, Install section)"
fi
