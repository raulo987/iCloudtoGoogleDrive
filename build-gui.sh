#!/bin/bash
# build-gui.sh — compile the Swift menu-bar app and assemble a .app bundle.
# No Xcode required: uses `xcrun swiftc` against the Command Line Tools SDK.
# Safe to run repeatedly; touches no backup data.

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$REPO/gui"
APP="$HOME/Applications/Drive Backup.app"
GUI_AGENT="$HOME/Library/LaunchAgents/eu.itteam.gdrive-backup-gui.plist"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "==> Compiling Swift sources"
xcrun swiftc -O -swift-version 5 \
  -framework AppKit -framework Foundation \
  -o "$BUILD/Drive Backup" "$SRC_DIR"/*.swift

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Drive Backup" "$APP/Contents/MacOS/Drive Backup"

# Bundle the shell engine + setup script inside the app so a dragged-in copy is
# self-contained (the GUI resolves these from Resources; see Paths.bundledOrBin).
cp "$REPO/bin/icloud-gdrive-sync.sh" "$REPO/bin/rclone-setup.command" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/icloud-gdrive-sync.sh" "$APP/Contents/Resources/rclone-setup.command"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Drive Backup</string>
  <key>CFBundleDisplayName</key>     <string>Drive Backup</string>
  <key>CFBundleIdentifier</key>      <string>eu.itteam.gdrivebackup</string>
  <key>CFBundleExecutable</key>      <string>Drive Backup</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSUIElement</key>            <true/>
  <key>LSMinimumSystemVersion</key> <string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null && echo "    Info.plist OK"

echo "==> Writing GUI login LaunchAgent (NOT loaded automatically)"
cat > "$GUI_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>eu.itteam.gdrive-backup-gui</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/Drive Backup</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST
plutil -lint "$GUI_AGENT" >/dev/null && echo "    GUI agent plist OK"

echo
echo "Built:   $APP"
echo "Open it: open \"$APP\""
echo "Start at login (optional): launchctl bootstrap gui/\$(id -u) \"$GUI_AGENT\""
