#!/bin/bash
# edge-collapse-spike v3 — build release, wrap in a minimal .app bundle
# (bundle id com.nanopod.edgecollapsespike so screenshots/Automation TCC
# work), launch. Two windows: the transparent 320x360 panel pinned to the
# right screen edge, and the "edge-collapse-spike controls" window.
# Quit: close the controls window, or `pkill -x EdgeCollapseSpike`.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release || { echo "BUILD FAILED"; exit 1; }
BIN="$(swift build -c release --show-bin-path)/EdgeCollapseSpike"
BUNDLE_DIR="$(swift build -c release --show-bin-path)/MusicMiniPlayer_MusicMiniPlayerCore.bundle"

APP="$DIR/.build/EdgeCollapseSpike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EdgeCollapseSpike"
[ -d "$BUNDLE_DIR" ] && cp -R "$BUNDLE_DIR" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>EdgeCollapseSpike</string>
<key>CFBundleIdentifier</key><string>com.nanopod.edgecollapsespike</string>
<key>CFBundleName</key><string>EdgeCollapseSpike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><false/>
<key>NSAppleMusicUsageDescription</key><string>Reads the Music library for the edge-collapse prototype.</string>
<key>NSAppleEventsUsageDescription</key><string>Reads Music playback for the edge-collapse prototype.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
pkill -x EdgeCollapseSpike 2>/dev/null
echo "Launching $APP"
# Isolate from the real app's data: the spike links this worktree's
# MusicMiniPlayerCore, whose cache schemas can differ from the installed app,
# and the two would wipe each other's ~/Library/Application Support/nanoPod
# caches (2026-09-22: lyrics_cache.json shrank 149 -> 24 entries). This
# redirects Application Support, Caches and Preferences for the spike only.
SPIKE_HOME="$DIR/.build/spike-home"
mkdir -p "$SPIKE_HOME/Library"
(CFFIXED_USER_HOME="$SPIKE_HOME" nohup "$APP/Contents/MacOS/EdgeCollapseSpike" > /tmp/ecs.log 2>&1 &)
