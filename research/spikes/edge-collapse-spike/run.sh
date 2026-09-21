#!/bin/bash
# edge-collapse-spike — build release and launch the standalone prototype.
#
# The app is a menu-bar-less accessory app (no Dock icon): it opens a
# transparent floating panel, FIXED at 320x360 for its whole lifetime, right
# edge flush with the main screen's right edge and vertically centered (the
# card/tucked/floating layouts are all positioned within this one fixed
# canvas — the window itself never resizes), plus an ordinary
# "edge-collapse-spike controls" window with the variant/tint/bounce/tempo/
# Reduce-Motion switches and Collapse/Expand/Next-track buttons. Quit with
# Cmd-Q while the controls window is focused, or `pkill -x EdgeCollapseSpike`.
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
