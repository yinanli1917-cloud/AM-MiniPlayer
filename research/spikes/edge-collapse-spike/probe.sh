#!/bin/bash
# edge-collapse-spike probe — code-level (no screen) proof that a collapse
# then an expand are each ONE continuous motion, not a snap/relay.
#
# Top-level task instruction #7: launches the release binary with
# EDGECOLLAPSE_PROBE=1 (EdgeCollapseProbe.swift then walks the SwiftUI
# hosting view's CALayer tree at ~60Hz and logs every layer whose class name
# contains "glass"/"backdrop" — same technique as
# research/spikes/glass-morph-spike/main.swift's walkLayers/recordMorphFrame),
# pokes it to collapse then expand via NSDistributedNotificationCenter
# (public API; triggered here by running a tiny ad-hoc `swift <script>.swift`
# poster — `osascript -l JavaScript`'s ObjC bridge was tried first and its
# `postNotificationNameObjectUserInfoDeliverImmediately` call silently
# no-ops in this environment even though it reports success, confirmed by
# A/B: a compiled/interpreted Swift poster using the exact same
# DistributedNotificationCenter API DOES deliver, so this script uses that
# instead — see SpikeAppDelegate.swift's EdgeCollapseProbeNotification doc
# comment for why a `nanopodspike://` URL scheme was not used at all: this
# is a bare SwiftPM executable, not an app bundle with a registered
# CFBundleURLTypes), waits ~2s, quits, then
# checks the log: each transition's tracked glass layer must show >=12
# distinct consecutive bounds-changing steps with no single step >25% of the
# transition's total (width,height) delta. Prints PASS/FAIL per transition.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "Building release..."
swift build -c release
if [ $? -ne 0 ]; then
    echo "BUILD FAILED"
    exit 1
fi
BIN="$(swift build -c release --show-bin-path)/EdgeCollapseSpike"

LOG="$DIR/probe.log"
rm -f "$LOG"

echo "Launching $BIN with EDGECOLLAPSE_PROBE=1 ..."
EDGECOLLAPSE_PROBE=1 "$BIN" > "$LOG" 2>&1 &
APP_PID=$!
echo "  pid=$APP_PID"

# Give the panel time to appear and the SwiftUI tree to materialize its
# first glass layers before we poke it.
sleep 1.0

POSTER="$DIR/.probe_poster.swift"
cat > "$POSTER" <<'SWIFT'
import Foundation
let name = CommandLine.arguments[1]
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true
)
print("posted \(name)")
SWIFT

post_notification() {
    local name="$1"
    swift "$POSTER" "$name"
}

echo "Posting collapse notification..."
post_notification "com.nanopod.edgeCollapseSpike.collapse"
sleep 1.0

echo "Posting expand notification..."
post_notification "com.nanopod.edgeCollapseSpike.expand"
sleep 1.0

echo "Quitting..."
kill "$APP_PID" 2>/dev/null
sleep 0.3
kill -9 "$APP_PID" 2>/dev/null

rm -f "$POSTER"

echo "Log: $LOG ($(wc -l < "$LOG") lines)"
echo

python3 "$DIR/probe_analyze.py" "$LOG"
exit $?
