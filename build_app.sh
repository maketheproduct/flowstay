#!/bin/bash

set -euo pipefail

# Robust error reporting
trap 'echo "❌ Build failed at line $LINENO"; exit 1' ERR

# Defaults
BUILD_DIR=${BUILD_DIR:-.build}
APP_NAME="Flowstay.app"
APP_DIR="build/$APP_NAME"
NO_SIGN=0
SKIP_INSTALL=0

# Parse args
for arg in "$@"; do
  case "$arg" in
    --no-sign)
      NO_SIGN=1
      shift
      ;;
    --skip-install)
      SKIP_INSTALL=1
      shift
      ;;
    *)
      echo "Unknown option: $arg"
      echo "Usage: $0 [--no-sign] [--skip-install]"
      exit 2
      ;;
  esac
done

# Caches
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$(pwd)/.clang-module-cache}"
export SWIFT_USE_LOCAL_CLANG_MODULE_CACHE="${SWIFT_USE_LOCAL_CLANG_MODULE_CACHE:-1}"
export SWIFTPM_CLANG_MODULE_CACHE_PATH="${SWIFTPM_CLANG_MODULE_CACHE_PATH:-$CLANG_MODULE_CACHE_PATH}"
export SWIFTPM_ENABLE_SANDBOX="${SWIFTPM_ENABLE_SANDBOX:-0}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

# Ensure we are running on Apple Silicon since MLX requires arm64 + Neural Engine
ARCH=$(uname -m)
if [[ "${ARCH}" != "arm64" ]]; then
    echo "❌ Flowstay post-processing requires Apple Silicon (arm64). Detected architecture: ${ARCH}"
    echo "   Please run this build on an Apple Silicon Mac."
    exit 1
fi

# Build the Swift executable in RELEASE mode (required for MLX)
echo "Building Swift executable in RELEASE mode..."
rm -f "$BUILD_DIR/build.db" "$BUILD_DIR/build.db.lock" 2>/dev/null || true
swift --version || true
swift build -c release --disable-sandbox --product Flowstay

# Verify product exists
if [ ! -x ".build/release/Flowstay" ] && [ ! -x ".build/arm64-apple-macosx/release/Flowstay" ]; then
  echo "❌ Built product not found. Expected at .build/release/Flowstay"
  exit 1
fi

echo "Swift build successful!"

# Create app bundle structure
echo "Creating app bundle..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Resolve executable path
EXEC_PATH=".build/release/Flowstay"
if [ ! -f "$EXEC_PATH" ]; then
  EXEC_PATH=".build/arm64-apple-macosx/release/Flowstay"
fi

# Copy executable from release build
cp "$EXEC_PATH" "$APP_DIR/Contents/MacOS/"

# Copy resource bundles (fonts, assets, localizations) from release build
echo "Copying resource bundles..."
for bundle in .build/release/*.bundle .build/arm64-apple-macosx/release/*.bundle; do
    if [ -d "$bundle" ]; then
        bundle_name=$(basename "$bundle")
        echo "  Copying $bundle_name..."
        # Remove old bundle if it exists to avoid permission issues
        rm -rf "$APP_DIR/Contents/Resources/$bundle_name"
        cp -R "$bundle" "$APP_DIR/Contents/Resources/"
    fi
done

# Copy Info.plist
cp "Sources/Flowstay/Info.plist" "$APP_DIR/Contents/"

# Copy legacy ICNS icon if it exists
if [ -f "Sources/Flowstay/AppIcon.icns" ]; then
    cp "Sources/Flowstay/AppIcon.icns" "$APP_DIR/Contents/Resources/"
fi

# Copy Icon Composer .icon directory for macOS Tahoe
ICON_SRC=""
if [ -d "Sources/Flowstay/Resources/Flowstay.icon" ]; then
    ICON_SRC="Sources/Flowstay/Resources/Flowstay.icon"
elif [ -d ".flowstay.icon" ]; then
    ICON_SRC=".flowstay.icon"
fi
if [ -n "$ICON_SRC" ]; then
    echo "Copying Icon Composer .icon..."
    cp -R "$ICON_SRC" "$APP_DIR/Contents/Resources/"
fi

# Copy Sparkle framework from release build
echo "Copying Sparkle framework..."
mkdir -p "$APP_DIR/Contents/Frameworks"
SPARKLE_FRAMEWORK=".build/arm64-apple-macosx/release/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/"
    echo "  ✓ Sparkle framework copied"

    # Fix rpath to point to Frameworks directory
    echo "  Setting rpath for Sparkle..."
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_DIR/Contents/MacOS/Flowstay" 2>/dev/null || true
else
    echo "  ⚠️  Sparkle framework not found at $SPARKLE_FRAMEWORK"
fi

# Copy ESpeakNG framework from release build
echo "Copying ESpeakNG framework..."
ESPEAK_FRAMEWORK=".build/arm64-apple-macosx/release/ESpeakNG.framework"
if [ -d "$ESPEAK_FRAMEWORK" ]; then
    rm -rf "$APP_DIR/Contents/Frameworks/ESpeakNG.framework"
    cp -R "$ESPEAK_FRAMEWORK" "$APP_DIR/Contents/Frameworks/"
    echo "  ✓ ESpeakNG framework copied"
else
    echo "  ⚠️  ESpeakNG framework not found at $ESPEAK_FRAMEWORK"
fi

# Sign the app bundle with entitlements
if [ "$NO_SIGN" -eq 1 ]; then
  echo "Skipping code signing (--no-sign)"
else
  echo "Signing app bundle..."
  # Try to find a valid developer certificate, fallback to ad-hoc signing
  DEV_CERT=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | cut -d '"' -f 2)
  if [ -n "$DEV_CERT" ]; then
      echo "Signing embedded frameworks with $DEV_CERT..."
      # Sign binaries in Sparkle framework first
      codesign --force --options runtime --timestamp --sign "$DEV_CERT" "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
      codesign --force --options runtime --timestamp --sign "$DEV_CERT" "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
      
      # Sign nested helpers first (apps, XPC services, plug-ins) so framework signature succeeds
      find "$APP_DIR/Contents/Frameworks/Sparkle.framework" \( -name "*.app" -o -name "*.xpc" -o -name "*.plugin" \) -type d | while read NESTED; do
          codesign --force --options runtime --timestamp --sign "$DEV_CERT" "$NESTED"
      done
      
      # Sign the framework itself
      codesign --force --options runtime --timestamp --sign "$DEV_CERT" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
      
      # Sign any other frameworks
      find "$APP_DIR/Contents/Frameworks" -type d -name "*.framework" | while read FRAME; do
          if [ "$FRAME" != "$APP_DIR/Contents/Frameworks/Sparkle.framework" ]; then
              codesign --force --options runtime --timestamp --sign "$DEV_CERT" "$FRAME"
          fi
      done

      echo "Using developer certificate: $DEV_CERT"
      # Sign the main app last (no --deep to avoid re-signing nested items without timestamp)
      codesign --force \
          --sign "$DEV_CERT" \
          --entitlements Flowstay.entitlements \
          --options runtime \
          --timestamp \
          "$APP_DIR"

      echo "Verifying code signatures..."
      codesign --verify --strict --verbose=2 "$APP_DIR"
  else
      echo "No developer certificate found, using ad-hoc signing"
      echo "⚠️  To distribute this app, you need to import your Developer ID certificate"
      echo "    Run: ./import_certificate.sh"
      codesign --force --sign - --entitlements Flowstay.entitlements "$APP_DIR"
  fi
fi

echo "App bundle created successfully at $APP_DIR"

# Optionally install to /Applications
if [ "$SKIP_INSTALL" -eq 1 ]; then
  echo "Skipping install (--skip-install). You can run: open \"$APP_DIR\""
  exit 0
fi

echo "Installing to /Applications..."
if [ -d "/Applications/$APP_NAME" ]; then
    echo "Removing existing app from /Applications..."
    rm -rf "/Applications/$APP_NAME" 2>/dev/null || true
fi

if cp -R "$APP_DIR" "/Applications/" 2>/dev/null; then
    echo "✅ App installed successfully to /Applications/$APP_NAME"
    echo "You can now run it from Spotlight or Applications folder"
    echo "Or run: open /Applications/$APP_NAME"
else
    echo "❌ Could not copy to /Applications (permission denied)."
    echo "   Run this script with elevated privileges or copy manually:"
    echo "   sudo rm -rf /Applications/$APP_NAME"
    echo "   sudo cp -R $APP_DIR /Applications/"
    echo "Fallback: You can run it with: open $APP_DIR"
fi
