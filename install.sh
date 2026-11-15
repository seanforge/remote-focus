#!/bin/bash
# Build RemoteFocus, install it as ~/Applications/RemoteFocus.app, and start it at login (LaunchAgent).
# Re-run any time to update.
set -euo pipefail

cd "$(dirname "$0")"
APP="$HOME/Applications/RemoteFocus.app"
LABEL="com.seanforge.remotefocus"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/RemoteFocus.log"

echo "==> Building"
swift build -c release

echo "==> Stopping any running copy"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x remote-focus 2>/dev/null || true   # 终端里手动跑的那份

echo "==> Installing $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/remote-focus "$APP/Contents/MacOS/RemoteFocus"
cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>RemoteFocus</string>
  <key>CFBundleExecutable</key><string>RemoteFocus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLISTEOF
codesign --force --sign - "$APP"

echo "==> Registering login item ($PLIST)"
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
: > "$LOG"   # start each install with an empty log
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/RemoteFocus</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLISTEOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "Done. RemoteFocus is running and will start at every login."
echo "First run: allow RemoteFocus in System Settings → Privacy & Security → Accessibility and Input Monitoring."
echo "(After each reinstall macOS may ask again: remove the old RemoteFocus entry and turn the new one on.)"
echo "Log: $LOG (startup / permission messages only)"
