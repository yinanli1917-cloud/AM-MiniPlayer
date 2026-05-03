#!/bin/bash

VERSION="2.5"

echo "🔨 Building nanoPod..."
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleVersion $VERSION" \
    -c "Set :CFBundleShortVersionString $VERSION" \
    Sources/MusicMiniPlayerApp/Info.plist
swift build -c release

echo "📦 Creating app bundle..."
rm -rf nanoPod.app
mkdir -p nanoPod.app/Contents/MacOS
mkdir -p nanoPod.app/Contents/Resources

# Copy binary (still named MusicMiniPlayer from Swift package)
cp .build/release/MusicMiniPlayer nanoPod.app/Contents/MacOS/nanoPod

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
        rm partial_info.plist
    else
        echo "⚠️  actool failed, falling back to icns"
        [ -f "Resources/AppIcon.icns" ] && cp Resources/AppIcon.icns nanoPod.app/Contents/Resources/
    fi
elif [ -f "Resources/AppIcon.icns" ]; then
    echo "🎨 Copying AppIcon.icns..."
    cp Resources/AppIcon.icns nanoPod.app/Contents/Resources/
    echo "✅ AppIcon.icns copied"
elif [ -f "Resources/Assets.car" ]; then
    echo "🎨 Copying Assets.car..."
    cp Resources/Assets.car nanoPod.app/Contents/Resources/
    echo "✅ Assets.car copied"
else
    echo "⚠️  No icon available"
fi

# Ad-hoc code sign with entitlements (required for AppleScript automation on modern macOS)
echo "🔏 Code signing with entitlements..."
codesign --force --deep --sign - --entitlements nanoPod.entitlements nanoPod.app

# Verify signature
if codesign --verify --verbose nanoPod.app 2>/dev/null; then
    echo "✅ Code signature verified"
else
    echo "⚠️  Code signature verification failed (app may still work)"
fi

# Clean up entitlements file
rm -f nanoPod.entitlements

# Fix macOS 26 menu bar database (remove stale MusicMiniPlayer entries)
if python3 scripts/fix_menubar.py 2>/dev/null; then
    killall ControlCenter 2>/dev/null
    killall cfprefsd 2>/dev/null
    echo "🔧 Menu bar database cleaned"
fi

echo "✅ App bundle created at nanoPod.app"
echo "🚀 You can now open it with: open nanoPod.app"
