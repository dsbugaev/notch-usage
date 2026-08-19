#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

CFG="$HOME/.config/notch-usage/config.json"
if [ ! -f "$CFG" ]; then
  mkdir -p "$(dirname "$CFG")"
  cp config.example.json "$CFG"
  echo "config: $CFG"
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
echo "установлено и запущено (лог: ~/Library/Logs/notchusage.log)"
