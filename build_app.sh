#!/bin/bash

echo "🔨 Building MusicMiniPlayer..."
swift build -c release

echo "📦 Creating app bundle..."
rm -rf MusicMiniPlayer.app
mkdir -p MusicMiniPlayer.app/Contents/MacOS
mkdir -p MusicMiniPlayer.app/Contents/Resources

# Copy binary
cp .build/release/MusicMiniPlayer MusicMiniPlayer.app/Contents/MacOS/

# Create Info.plist with all required permissions
cat > MusicMiniPlayer.app/Contents/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MusicMiniPlayer</string>
    <key>CFBundleIdentifier</key>
    <string>com.yinanli.MusicMiniPlayer</string>
    <key>CFBundleName</key>
    <string>Music Mini Player</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>MusicMiniPlayer needs access to control Music.app playback</string>
    <key>NSAppleMusicUsageDescription</key>
    <string>MusicMiniPlayer displays your currently playing music and lyrics</string>
</dict>
</plist>
PLIST

echo "✅ App bundle created at MusicMiniPlayer.app"
echo "🚀 You can now open it with: open MusicMiniPlayer.app"
