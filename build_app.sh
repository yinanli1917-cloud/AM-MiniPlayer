#!/bin/bash

echo "🔨 Building MusicMiniPlayer..."
swift build -c release

echo "📦 Creating app bundle..."
rm -rf MusicMiniPlayer.app
mkdir -p MusicMiniPlayer.app/Contents/MacOS
mkdir -p MusicMiniPlayer.app/Contents/Resources

# Copy binary
cp .build/release/MusicMiniPlayer MusicMiniPlayer.app/Contents/MacOS/

# Create Info.plist with ALL required permissions and icon configuration
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
    <string>MusicMiniPlayer</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>MusicMiniPlayer needs access to control Music.app playback</string>
    <key>NSAppleMusicUsageDescription</key>
    <string>MusicMiniPlayer displays your currently playing music and lyrics</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST


echo "🎨 Copying icon resources..."
# Copy AppIcon.icon to app bundle and convert to .icns
if [ -d "AppIcon.icon" ]; then
    echo "🎨 Compiling AppIcon.icon using actool..."
    xcrun actool AppIcon.icon --compile MusicMiniPlayer.app/Contents/Resources --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist partial_info.plist > /dev/null
    
    if [ -f "partial_info.plist" ]; then
        echo "✅ AppIcon compiled successfully"
        # Merge partial info plist if needed, but we already set CFBundleIconName in Info.plist
        rm partial_info.plist
    else
        echo "⚠️  actool failed to generate partial info plist"
    fi
else
    echo "⚠️  AppIcon.icon not found"
fi


echo "✅ App bundle created at MusicMiniPlayer.app"
echo "🚀 You can now open it with: open MusicMiniPlayer.app"
