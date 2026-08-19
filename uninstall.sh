#!/bin/bash
set -uo pipefail
PLIST="$HOME/Library/LaunchAgents/ru.bugaev.notchusage.plist"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
pkill -x NotchUsage 2>/dev/null || true
echo "удалено (конфиг ~/.config/notch-usage/ и записи доступа в связке ключей остались — можно снести руками)"
