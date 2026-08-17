#!/bin/bash
# make-dmg.sh — build a drag-to-Applications disk image of Drive Backup.app.
#
# Produces dist/Drive-Backup.dmg containing the (self-contained) app, an
# Applications shortcut, and a short install note. The app is unsigned/un-notarized
# (no Apple Developer ID), so it is ad-hoc signed here — enough to launch on Apple
# Silicon; the first open still needs right-click → Open (Gatekeeper).

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Drive Backup.app"
VOL="Drive Backup"
DIST="$REPO/dist"
DMG="$DIST/Drive-Backup.dmg"

echo "==> Building the app (bundles the engine into Resources)"
"$REPO/build-gui.sh" >/dev/null
echo "    built: $APP"

echo "==> Ad-hoc signing the bundle (so it launches on Apple Silicon)"
codesign --force --deep --sign - "$APP" 2>/dev/null \
  && echo "    signed (ad-hoc)" || echo "    (codesign unavailable — skipped)"

echo "==> Staging disk-image contents"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/How to install.txt" <<'TXT'
Drive Backup — install

1. Drag "Drive Backup.app" onto the Applications folder (shown here).
2. First launch only: in Applications, RIGHT-CLICK the app → Open → Open.
   (It is safe but unsigned, so macOS asks once. After that it opens normally.)
3. It lives in the menu bar (no Dock icon). Then:
     • Install rclone if you don't have it:  brew install rclone
     • Menu → "Set up Google Drive…"  (one-time Google sign-in)
     • Menu → "Settings…"  → pick folders, language, schedule → Save
     • Menu → "Back up now"

Switch the interface language in Settings → Language (English / Estonian).
Project & help: https://github.com/raulo987/iCloudtoGoogleDrive
TXT

echo "==> Creating $DMG"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo
echo "Built: $DMG  ($SIZE)"
echo "Distribute via a GitHub Release. Recipients: right-click → Open on first launch."
