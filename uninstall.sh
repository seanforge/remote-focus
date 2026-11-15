#!/bin/bash
# Stop RemoteFocus, remove the login item and the app.
set -uo pipefail
LABEL="com.seanforge.remotefocus"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/RemoteFocus.app"
echo "RemoteFocus removed. (You can also delete its entries under Privacy & Security → Accessibility / Input Monitoring.)"
