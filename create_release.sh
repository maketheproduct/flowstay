#!/bin/bash

# Create a release-ready DMG for Flowstay
# This script builds, signs, and packages the app for distribution

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
INFO_PLIST="Sources/Flowstay/Info.plist"

read_info_plist() {
    plutil -extract "$1" raw -o - "$INFO_PLIST"
}

detach_conflicting_volume_if_needed() {
    local volume_name="$1"
    local mount_path="/Volumes/$volume_name"

    if [ ! -d "$mount_path" ]; then
        return
    fi

    echo -e "${YELLOW}⚠️  Detaching existing mounted volume at $mount_path before packaging${NC}"
    if hdiutil detach "$mount_path" -force >/dev/null 2>&1; then
        echo "   ✓ Detached $mount_path"
    else
        echo -e "${RED}❌ Failed to detach existing volume at $mount_path${NC}"
        echo "   Close any Finder windows using that volume and try again."
        exit 1
    fi
}

run_finder_layout() {
    local volume_name="$1"
    local background_image="$2"

    osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume_name"
    open
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set the bounds to {200, 120, 800, 520}
    end tell

    set opts to the icon view options of container window
    tell opts
      set icon size to 80
      set text size to 14
      set arrangement to not arranged
$(if [ -n "$background_image" ]; then
    printf '      set background picture to POSIX file "%s" as alias\n' "$background_image"
fi)
    end tell

    set position of item "Flowstay.app" to {150, 240}
    set the extension hidden of item "Flowstay.app" to true
    set position of item "Applications" to {440, 240}

    close
    open
  end tell

  delay 5
end tell
APPLESCRIPT
}

build_styled_dmg() {
    local app_path="$1"
    local dmg_name="$2"
    local volume_name="$3"
    local developer_id="$4"
    local background_image="$5"
    local temp_dmg
    local mounted_device
    local app_size_mb
    local dmg_size_mb

    app_size_mb=$(du -sm "$app_path" | awk '{print $1}')
    dmg_size_mb=$((app_size_mb + 80))
    temp_dmg=$(mktemp -u "/tmp/flowstay-release.XXXXXX.dmg")

    hdiutil create \
        -srcfolder "$app_path" \
        -volname "$volume_name" \
        -fs HFS+ \
        -size "${dmg_size_mb}m" \
        -format UDRW \
        "$temp_dmg" >/dev/null

    detach_conflicting_volume_if_needed "$volume_name"

    mounted_device=$(hdiutil attach \
        -mountpoint "/Volumes/$volume_name" \
        -readwrite \
        -noverify \
        -noautoopen \
        -nobrowse \
        "$temp_dmg" | awk '/^\/dev\// { print $1; exit }')

    if [ -z "$mounted_device" ]; then
        echo -e "${RED}❌ Failed to mount temporary DMG${NC}"
        exit 1
    fi

    if [ -n "$background_image" ]; then
        mkdir -p "/Volumes/$volume_name/.background"
        cp "$background_image" "/Volumes/$volume_name/.background/"
        background_image="/Volumes/$volume_name/.background/$(basename "$background_image")"
    fi

    ln -s /Applications "/Volumes/$volume_name/Applications"
    run_finder_layout "$volume_name" "$background_image"

    sync
    hdiutil detach "$mounted_device" -force >/dev/null

    hdiutil convert "$temp_dmg" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$dmg_name" >/dev/null

    rm -f "$temp_dmg"

    codesign --force --sign "$developer_id" "$dmg_name" >/dev/null
}

echo "🚀 Flowstay Release Builder"
echo "=========================="
echo ""

# Get version from Info.plist
VERSION=$(read_info_plist CFBundleShortVersionString)
BUILD=$(read_info_plist CFBundleVersion)

echo "📦 Version: $VERSION (Build $BUILD)"
echo ""

# Check for Developer ID certificate
DEV_CERT=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | cut -d '"' -f 2)
if [ -z "$DEV_CERT" ]; then
    echo -e "${RED}❌ No Developer ID certificate found!${NC}"
    echo "Please run: ./import_certificate.sh first"
    exit 1
fi

echo -e "${GREEN}✅ Developer ID found:${NC} $DEV_CERT"
echo ""

# Build the app
echo "🔨 Building Flowstay..."
./build_app.sh

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Build failed${NC}"
    exit 1
fi

echo ""
echo "📦 Creating DMG with custom installer background..."

APP_NAME="Flowstay.app"
DMG_NAME="Flowstay-${VERSION}.dmg"
VOLUME_NAME="Flowstay"

# Remove old DMG
rm -f "$DMG_NAME"

# create-dmg's Finder AppleScript expects the mounted path basename to match the
# intended volume name. If an old DMG is already mounted at /Volumes/Flowstay,
# macOS will assign a random mount path and the layout step will fail or hang.
detach_conflicting_volume_if_needed "$VOLUME_NAME"

# Copy background image to accessible location (use standard resolution, not @2x)
BACKGROUND_IMAGE="Sources/FlowstayUI/Assets/dmg-background.png"
if [ ! -f "$BACKGROUND_IMAGE" ]; then
    echo -e "${YELLOW}⚠️  Background image not found, using default layout${NC}"
    BACKGROUND_IMAGE=""
fi

echo "Building installer DMG..."
build_styled_dmg "build/$APP_NAME" "$DMG_NAME" "$VOLUME_NAME" "$DEV_CERT" "$BACKGROUND_IMAGE"

# Verify signature
echo ""
echo "🔍 Verifying signatures..."
codesign -dv --verbose=4 "$DMG_NAME" 2>&1 | grep "Authority"

echo ""
echo -e "${GREEN}✅ Release DMG created successfully!${NC}"
echo ""
echo "📦 File: $DMG_NAME"
echo "📊 Size: $(du -h "$DMG_NAME" | cut -f1)"
echo ""

# Show next steps
echo "📋 Next Step:"
echo ""
echo "Run: ./notarize.sh"
echo ""
echo "This will:"
echo "  • Submit $DMG_NAME to Apple for notarization"
echo "  • Staple the notarization ticket"
echo "  • Verify it's ready for distribution"
echo "  • Generate Sparkle signature for updates"
echo ""

# Optional: Open the folder
open .
