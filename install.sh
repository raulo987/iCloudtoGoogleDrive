#!/bin/bash
# install.sh — install the backup engine + GUI from this repo onto this Mac.
#   * copies bin/* (engine + rclone setup helper) to ~/bin
#   * builds the menu-bar app into ~/Applications
# Does NOT configure Google Drive, enable scheduling, or run a backup — those
# are done from the GUI ("Seadista Google Drive…" / "Seaded…") or the CLI.

set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"

command -v xcrun >/dev/null || { echo "Need Xcode Command Line Tools: xcode-select --install"; exit 1; }
[ -x /opt/homebrew/bin/rclone ] || echo "NOTE: rclone not found — install with: brew install rclone"

echo "==> Installing engine to ~/bin"
mkdir -p "$HOME/bin"
cp "$REPO/bin/icloud-gdrive-sync.sh" "$HOME/bin/"
cp "$REPO/bin/rclone-setup.command" "$HOME/bin/"
chmod +x "$HOME/bin/icloud-gdrive-sync.sh" "$HOME/bin/rclone-setup.command"

echo "==> Building GUI"
bash "$REPO/build-gui.sh"

echo
echo "Installed. Next:"
echo "  1) open \"\$HOME/Applications/Drive Backup.app\""
echo "  2) menu-bar icon → \"Seadista Google Drive…\" (one-time OAuth)"
echo "  3) menu-bar icon → \"Seaded…\" → pick folders, interval, enable schedule"
