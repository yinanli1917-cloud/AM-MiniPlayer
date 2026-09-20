#!/bin/bash
# edge-collapse-spike — build release and launch the standalone prototype.
#
# The app is a menu-bar-less accessory app (no Dock icon): it opens a
# transparent floating panel docked to the RIGHT edge of the main screen
# (starting at the 250x316 card size) plus an ordinary "edge-collapse-spike
# controls" window with the variant/tint/tempo/Reduce-Motion switches and
# Collapse/Expand/Next-track buttons. Quit with Cmd-Q while the controls
# window is focused, or `pkill -x EdgeCollapseSpike`.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "Building release..."
swift build -c release
BUILD_STATUS=$?
if [ $BUILD_STATUS -ne 0 ]; then
    echo "BUILD FAILED"
    exit 1
fi

BIN="$(swift build -c release --show-bin-path)/EdgeCollapseSpike"
echo "Launching $BIN"
exec "$BIN"
