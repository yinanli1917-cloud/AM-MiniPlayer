#!/bin/bash
set -euo pipefail

VERSION="${NANOPOD_MARKETING_VERSION:-0.28}"
DISPLAY_VERSION="${NANOPOD_DISPLAY_VERSION:-0.28 beta}"
UPDATE_SEQUENCE="${NANOPOD_UPDATE_SEQUENCE:-28}"
BUILD_MODE="${1:-local}"
UPDATE_DIR="$HOME/Library/Application Support/nanoPod/updates"

case "$BUILD_MODE" in
    release|--release)
        RELEASE_BUILD=1
        AUTO_UPDATE_STATE="enabled"
        ;;
    local|--local|"")
        RELEASE_BUILD=0
        AUTO_UPDATE_STATE="disabled"
        ;;
    *)
        echo "Usage: ./build_app.sh [local|release]"
        exit 64
        ;;
esac

set_plist_string() {
    local plist="$1"
    local key="$2"
    local value="$3"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
}

set_plist_integer() {
    local plist="$1"
    local key="$2"
    local value="$3"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$key integer $value" "$plist"
}

delete_plist_key_if_present() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
}

cleanup_bundle_metadata() {
    find nanoPod.app -name '._*' -delete 2>/dev/null || true
    xattr -cr nanoPod.app 2>/dev/null || true
}

assert_no_appledouble() {
    local found
    found="$(find nanoPod.app -name '._*' -print 2>/dev/null || true)"
    if [ -n "$found" ]; then
        echo "❌ AppleDouble sidecars found inside signed bundle:"
        echo "$found"
        exit 1
    fi
}

assert_codesign_valid() {
    if ! codesign --verify --verbose nanoPod.app; then
        echo "❌ Code signature verification failed"
        exit 1
    fi
}

assert_bundle_identity() {
    if [ ! -f nanoPod.app/Contents/Resources/BuildInfo.txt ]; then
        echo "❌ BuildInfo.txt missing; refusing to deliver an unverifiable bundle"
        exit 1
    fi

    if ! grep -q "auto_update=$AUTO_UPDATE_STATE" nanoPod.app/Contents/Resources/BuildInfo.txt; then
        echo "❌ BuildInfo.txt auto-update marker does not match $AUTO_UPDATE_STATE"
        exit 1
    fi

    if [ "$(/usr/libexec/PlistBuddy -c 'Print :NPUpdateSequence' nanoPod.app/Contents/Info.plist 2>/dev/null || true)" != "$UPDATE_SEQUENCE" ]; then
        echo "❌ NPUpdateSequence missing or wrong in final bundle"
        exit 1
    fi

    if [ "$(/usr/libexec/PlistBuddy -c 'Print :NPDisplayVersion' nanoPod.app/Contents/Info.plist 2>/dev/null || true)" != "$DISPLAY_VERSION" ]; then
        echo "❌ NPDisplayVersion missing or wrong in final bundle"
        exit 1
    fi

    if [ "$RELEASE_BUILD" = "1" ]; then
        if /usr/libexec/PlistBuddy -c 'Print :NPDisableAutoUpdate' nanoPod.app/Contents/Info.plist >/dev/null 2>&1; then
            echo "❌ Release bundle must not disable auto-update"
            exit 1
        fi

        if /usr/libexec/PlistBuddy -c 'Print :NPLocalDeveloperBuild' nanoPod.app/Contents/Info.plist >/dev/null 2>&1; then
            echo "❌ Release bundle must not be marked as a local developer build"
            exit 1
        fi
    else
        if [ "$(/usr/libexec/PlistBuddy -c 'Print :NPDisableAutoUpdate' nanoPod.app/Contents/Info.plist 2>/dev/null || true)" != "true" ]; then
            echo "❌ NPDisableAutoUpdate missing from local bundle"
            exit 1
        fi

        if [ "$(/usr/libexec/PlistBuddy -c 'Print :NPLocalDeveloperBuild' nanoPod.app/Contents/Info.plist 2>/dev/null || true)" != "true" ]; then
            echo "❌ NPLocalDeveloperBuild missing from local bundle"
            exit 1
        fi
    fi
}

assert_build_marker_hash_matches_release_binary() {
    local marker_hash
    local release_hash
    marker_hash="$(tr ' ' '\n' < nanoPod.app/Contents/Resources/BuildInfo.txt | awk -F= '$1 == "release_sha256" { print $2 }')"
    release_hash="$(shasum -a 256 .build/release/MusicMiniPlayer | awk '{print $1}')"

    if [ -z "$marker_hash" ]; then
        echo "❌ BuildInfo.txt does not include release_sha256"
        exit 1
    fi

    if [ "$marker_hash" != "$release_hash" ]; then
        echo "❌ BuildInfo.txt release_sha256 does not match unsigned release binary"
        echo "   marker:  $marker_hash"
        echo "   release: $release_hash"
        exit 1
    fi
}

write_signed_hash_manifest() {
    local bundle_hash
    bundle_hash="$(shasum -a 256 nanoPod.app/Contents/MacOS/nanoPod | awk '{print $1}')"
    echo "$bundle_hash  nanoPod.app/Contents/MacOS/nanoPod" > nanoPod.app.sha256
    echo "🧾 Signed executable SHA256: $bundle_hash"
}

cleanup_local_update_staging() {
    pkill -f "nanoPod/updates/apply.sh" >/dev/null 2>&1 || true
    rm -rf "$UPDATE_DIR/staged.app" \
        "$UPDATE_DIR/tmp-expand" \
        "$UPDATE_DIR/download.zip"
    rm -f "$UPDATE_DIR/apply.sh" \
        "$UPDATE_DIR/apply.log" \
        "$UPDATE_DIR/staged.version"
}

assert_no_local_update_staging() {
    local found
    found="$(find "$UPDATE_DIR" \( -name 'apply.sh' -o -name 'staged.app' -o -name 'staged.version' -o -name 'download.zip' -o -name 'tmp-expand' \) -print 2>/dev/null || true)"
    if [ -n "$found" ]; then
        echo "❌ Local updater staging still exists:"
        echo "$found"
        exit 1
    fi

    if pgrep -f "nanoPod/updates/apply.sh" >/dev/null 2>&1; then
        echo "❌ Local updater applier is still running"
        exit 1
    fi
}

cleanup_local_update_staging
assert_no_local_update_staging

echo "🔨 Building nanoPod..."
set_plist_string Sources/MusicMiniPlayerApp/Info.plist CFBundleVersion "$VERSION"
set_plist_string Sources/MusicMiniPlayerApp/Info.plist CFBundleShortVersionString "$VERSION"
set_plist_string Sources/MusicMiniPlayerApp/Info.plist NPDisplayVersion "$DISPLAY_VERSION"
set_plist_integer Sources/MusicMiniPlayerApp/Info.plist NPUpdateSequence "$UPDATE_SEQUENCE"
delete_plist_key_if_present Sources/MusicMiniPlayerApp/Info.plist NPDisableAutoUpdate
delete_plist_key_if_present Sources/MusicMiniPlayerApp/Info.plist NPLocalDeveloperBuild
if [ "$RELEASE_BUILD" = "1" ]; then
    swift build -c release
else
    swift build -c release -Xswiftc -DLOCAL_DEVELOPER_BUILD
fi

echo "📦 Creating app bundle..."
if pgrep -x nanoPod >/dev/null 2>&1; then
    echo "🛑 Stopping running nanoPod so the bundle can be replaced..."
    osascript -e 'tell application id "com.yinanli.nanoPod" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -x nanoPod >/dev/null 2>&1 || true
    cleanup_local_update_staging
    assert_no_local_update_staging
fi

rm -rf nanoPod.app
mkdir -p nanoPod.app/Contents/MacOS
mkdir -p nanoPod.app/Contents/Resources

# Copy binary (still named MusicMiniPlayer from Swift package)
COPYFILE_DISABLE=1 cp .build/release/MusicMiniPlayer nanoPod.app/Contents/MacOS/nanoPod
chmod +x nanoPod.app/Contents/MacOS/nanoPod

SOURCE_HASH="$(shasum -a 256 .build/release/MusicMiniPlayer | awk '{print $1}')"
BUNDLE_HASH="$(shasum -a 256 nanoPod.app/Contents/MacOS/nanoPod | awk '{print $1}')"
if [ "$SOURCE_HASH" != "$BUNDLE_HASH" ]; then
    echo "❌ Bundle executable hash mismatch"
    echo "   release: $SOURCE_HASH"
    echo "   bundle:  $BUNDLE_HASH"
    exit 1
fi
echo "✅ Bundle executable matches freshly built release binary ($BUNDLE_HASH)"
BUILD_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_REV="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

write_build_marker() {
    local display_token="${DISPLAY_VERSION// /-}"
    local build_marker="version=$VERSION display_version=$display_token update_sequence=$UPDATE_SEQUENCE build_time=$BUILD_TIME git=$GIT_REV release_sha256=$SOURCE_HASH auto_update=$AUTO_UPDATE_STATE"
    cat > nanoPod.app/Contents/Resources/BuildInfo.txt << BUILDINFO
$build_marker
BUILDINFO
    echo "🧾 Build marker: $build_marker"
}

# Create Info.plist with ALL required permissions and icon configuration
# 🔑 使用新的 Bundle Identifier (com.yinanli.nanoPod) 避免和旧版本冲突
cat > nanoPod.app/Contents/Info.plist << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>nanoPod</string>
    <key>CFBundleIdentifier</key>
    <string>com.yinanli.nanoPod</string>
    <key>CFBundleName</key>
    <string>nanoPod</string>
    <key>CFBundleDisplayName</key>
    <string>nanoPod</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>NPDisplayVersion</key>
    <string>$DISPLAY_VERSION</string>
    <key>NPUpdateSequence</key>
    <integer>$UPDATE_SEQUENCE</integer>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>nanoPod needs permission to control Music.app for playback control and to display track information, album artwork, and lyrics.</string>
    <key>NSAppleMusicUsageDescription</key>
    <string>nanoPod needs access to your Apple Music library to display album artwork, track information, and lyrics.</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.yinanli.nanoPod</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>nanopod</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [ "$RELEASE_BUILD" = "0" ]; then
    /usr/libexec/PlistBuddy \
        -c "Add :NPLocalDeveloperBuild bool true" \
        -c "Add :NPDisableAutoUpdate bool true" \
        nanoPod.app/Contents/Info.plist
fi

write_build_marker

# Create entitlements file for code signing
cat > nanoPod.entitlements << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.temporary-exception.apple-events</key>
    <array>
        <string>com.apple.Music</string>
    </array>
</dict>
</plist>
ENTITLEMENTS

echo "🎨 Copying icon resources..."
# 优先使用 .icon 原生格式（macOS 26 Liquid Glass）
if [ -d "AppIcon.icon" ] && command -v xcrun &> /dev/null && xcrun --find actool &> /dev/null; then
    echo "🎨 Compiling AppIcon.icon using actool..."
    xcrun actool AppIcon.icon --compile nanoPod.app/Contents/Resources --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist partial_info.plist > /dev/null 2>&1
    if [ -f "partial_info.plist" ]; then
        echo "✅ AppIcon compiled successfully"
        rm -f partial_info.plist
    else
        echo "⚠️  actool failed, falling back to icns"
        [ -f "Resources/AppIcon.icns" ] && COPYFILE_DISABLE=1 cp Resources/AppIcon.icns nanoPod.app/Contents/Resources/
    fi
elif [ -f "Resources/AppIcon.icns" ]; then
    echo "🎨 Copying AppIcon.icns..."
    COPYFILE_DISABLE=1 cp Resources/AppIcon.icns nanoPod.app/Contents/Resources/
    echo "✅ AppIcon.icns copied"
elif [ -f "Resources/Assets.car" ]; then
    echo "🎨 Copying Assets.car..."
    COPYFILE_DISABLE=1 cp Resources/Assets.car nanoPod.app/Contents/Resources/
    echo "✅ Assets.car copied"
else
    echo "⚠️  No icon available"
fi

cleanup_bundle_metadata
assert_no_appledouble

# Ad-hoc code sign with entitlements (required for AppleScript automation on modern macOS)
echo "🔏 Code signing with entitlements..."
sign_bundle() {
    codesign --force --deep --sign - --entitlements nanoPod.entitlements nanoPod.app
}

sign_bundle

cleanup_bundle_metadata
assert_no_appledouble
sign_bundle
assert_codesign_valid
assert_bundle_identity
assert_build_marker_hash_matches_release_binary
write_signed_hash_manifest
echo "✅ Code signature verified"

# Clean up entitlements file
rm -f nanoPod.entitlements
cleanup_local_update_staging
assert_no_local_update_staging
echo "🧹 Local updater staging cleaned"

# Fix macOS 26 menu bar database (remove stale MusicMiniPlayer entries)
if python3 scripts/fix_menubar.py 2>/dev/null; then
    killall ControlCenter 2>/dev/null
    killall cfprefsd 2>/dev/null
    echo "🔧 Menu bar database cleaned"
fi

echo "✅ App bundle created at nanoPod.app"
echo "🚀 You can now open it with: open nanoPod.app"
