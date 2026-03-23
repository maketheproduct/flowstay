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

build_release_product() {
    swift --version || true
    swift build -c release --disable-sandbox --product Flowstay
}

array_contains() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}

resolve_exec_path() {
    EXEC_PATH="$BUILD_DIR/arm64-apple-macosx/release/Flowstay"
    if [ ! -f "$EXEC_PATH" ]; then
        EXEC_PATH="$BUILD_DIR/release/Flowstay"
    fi

    if [ ! -f "$EXEC_PATH" ]; then
        echo "❌ Built product not found. Expected at $BUILD_DIR/release/Flowstay or $BUILD_DIR/arm64-apple-macosx/release/Flowstay"
        exit 1
    fi
}

collect_release_bundles() {
    RELEASE_BUNDLE_PATHS=()
    RELEASE_BUNDLE_NAMES=()

    local dir bundle_path bundle_name
    for dir in "$BUILD_DIR/release" "$BUILD_DIR/arm64-apple-macosx/release"; do
        [ -d "$dir" ] || continue

        while IFS= read -r bundle_path; do
            [ -n "$bundle_path" ] || continue
            bundle_name=$(basename "$bundle_path")

            if [ "${#RELEASE_BUNDLE_NAMES[@]}" -eq 0 ]; then
                RELEASE_BUNDLE_PATHS+=("$bundle_path")
                RELEASE_BUNDLE_NAMES+=("$bundle_name")
            elif ! array_contains "$bundle_name" "${RELEASE_BUNDLE_NAMES[@]}"; then
                RELEASE_BUNDLE_PATHS+=("$bundle_path")
                RELEASE_BUNDLE_NAMES+=("$bundle_name")
            fi
        done < <(find "$dir" -maxdepth 1 -type d -name '*.bundle' | sort)
    done

    if [ "${#RELEASE_BUNDLE_NAMES[@]}" -eq 0 ]; then
        echo "❌ No release resource bundles found under $BUILD_DIR"
        exit 1
    fi

    echo "Detected release bundles:"
    for bundle_name in "${RELEASE_BUNDLE_NAMES[@]}"; do
        echo "  - $bundle_name"
    done
}

collect_referenced_release_bundles() {
    REFERENCED_RELEASE_BUNDLE_NAMES=()

    local bundle_name
    for bundle_name in "${RELEASE_BUNDLE_NAMES[@]}"; do
        if strings "$EXEC_PATH" | grep -Fq "$bundle_name"; then
            REFERENCED_RELEASE_BUNDLE_NAMES+=("$bundle_name")
        fi
    done

    if [ "${#REFERENCED_RELEASE_BUNDLE_NAMES[@]}" -eq 0 ]; then
        echo "⚠️  No release bundle references detected in $EXEC_PATH before patching"
        return
    fi

    echo "Executable currently references:"
    for bundle_name in "${REFERENCED_RELEASE_BUNDLE_NAMES[@]}"; do
        echo "  - $bundle_name"
    done
}

extract_bundle_name_from_accessor() {
    local accessor="$1"

    perl -ne 'if (/^\s*let mainPath = .*?appendingPathComponent\("([^"]+\.bundle)"\)/) { print "$1\n"; exit }' "$accessor"
}

patch_release_bundle_accessors() {
    RELEASE_ACCESSOR_PATHS=()
    PATCHED_ACCESSOR_COUNT=0

    local accessor bundle_name
    while IFS= read -r accessor; do
        [ -n "$accessor" ] || continue

        bundle_name=$(extract_bundle_name_from_accessor "$accessor")
        if [ -z "$bundle_name" ]; then
            echo "  Skipping accessor with no bundle name: $accessor"
            continue
        fi

        if ! array_contains "$bundle_name" "${RELEASE_BUNDLE_NAMES[@]}"; then
            echo "  Skipping accessor not copied into the release app: $bundle_name"
            continue
        fi

        RELEASE_ACCESSOR_PATHS+=("$accessor")

        if grep -Fq "Bundle.main.resourceURL?.appendingPathComponent(\"$bundle_name\").path" "$accessor"; then
            echo "  Accessor already patched for $bundle_name"
            continue
        fi

        if ! grep -Fq "Bundle.main.bundleURL.appendingPathComponent(\"$bundle_name\").path" "$accessor"; then
            echo "❌ Could not find expected bundle lookup for $bundle_name in $accessor"
            exit 1
        fi

        BUNDLE_NAME="$bundle_name" perl -0pi -e 'my $bundle = $ENV{"BUNDLE_NAME"}; my $quoted = quotemeta($bundle); s|let mainPath = Bundle\.main\.bundleURL\.appendingPathComponent\("$quoted"\)\.path|let mainPath = Bundle.main.resourceURL?.appendingPathComponent("$bundle").path ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/$bundle").path|g' "$accessor"

        if ! grep -Fq "Bundle.main.resourceURL?.appendingPathComponent(\"$bundle_name\").path" "$accessor"; then
            echo "❌ Failed to patch resource bundle accessor for $bundle_name at $accessor"
            exit 1
        fi

        echo "  Patched accessor for $bundle_name"
        PATCHED_ACCESSOR_COUNT=$((PATCHED_ACCESSOR_COUNT + 1))
    done < <(find "$BUILD_DIR" -path '*/release/*.build/DerivedSources/resource_bundle_accessor.swift' | sort)

    if [ "${#RELEASE_ACCESSOR_PATHS[@]}" -eq 0 ]; then
        echo "❌ Could not find any release resource bundle accessors under $BUILD_DIR"
        exit 1
    fi
}

verify_patched_release_accessors() {
    local accessor bundle_name

    for accessor in "${RELEASE_ACCESSOR_PATHS[@]}"; do
        bundle_name=$(extract_bundle_name_from_accessor "$accessor")

        if [ -z "$bundle_name" ]; then
            echo "❌ Could not determine bundle name for accessor $accessor"
            exit 1
        fi

        if ! grep -Fq "Bundle.main.resourceURL?.appendingPathComponent(\"$bundle_name\").path" "$accessor"; then
            echo "❌ Accessor still points at Bundle.main.bundleURL for $bundle_name: $accessor"
            exit 1
        fi
    done
}

verify_executable_bundle_paths() {
    local bundle_name

    if [ "${#REFERENCED_RELEASE_BUNDLE_NAMES[@]}" -eq 0 ]; then
        return
    fi

    for bundle_name in "${REFERENCED_RELEASE_BUNDLE_NAMES[@]}"; do
        if ! strings "$EXEC_PATH" | grep -Fq "Contents/Resources/$bundle_name"; then
            echo "❌ Built executable is missing the packaged bundle path for $bundle_name"
            exit 1
        fi
    done
}

verify_copied_release_bundles() {
    local bundle_name

    for bundle_name in "${RELEASE_BUNDLE_NAMES[@]}"; do
        if [ ! -d "$APP_DIR/Contents/Resources/$bundle_name" ]; then
            echo "❌ Expected resource bundle is missing from app bundle: $bundle_name"
            exit 1
        fi
    done
}

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
build_release_product
resolve_exec_path
collect_release_bundles
collect_referenced_release_bundles

echo "Patching SwiftPM resource bundle accessors..."
patch_release_bundle_accessors
verify_patched_release_accessors

if [ "$PATCHED_ACCESSOR_COUNT" -gt 0 ]; then
    echo "Rebuilding Flowstay with patched resource bundle accessors..."
    build_release_product
    resolve_exec_path
    collect_release_bundles
fi

collect_referenced_release_bundles
verify_patched_release_accessors
verify_executable_bundle_paths

echo "Swift build successful!"

# Create app bundle structure
echo "Creating app bundle..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy executable from release build
cp "$EXEC_PATH" "$APP_DIR/Contents/MacOS/"

# Copy resource bundles (fonts, assets, localizations) from release build
echo "Copying resource bundles..."
for bundle in "${RELEASE_BUNDLE_PATHS[@]}"; do
    bundle_name=$(basename "$bundle")
    echo "  Copying $bundle_name..."
    # Remove old bundle if it exists to avoid permission issues
    rm -rf "$APP_DIR/Contents/Resources/$bundle_name"
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

verify_copied_release_bundles

# Copy Info.plist
cp "Sources/Flowstay/Info.plist" "$APP_DIR/Contents/"

# Copy legacy ICNS icon if it exists
if [ -f "Sources/Flowstay/AppIcon.icns" ]; then
    cp "Sources/Flowstay/AppIcon.icns" "$APP_DIR/Contents/Resources/"
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
