#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
case "$CONFIG" in
  debug | release) ;;
  *)
    echo "usage: $0 [debug|release]" >&2
    exit 2
    ;;
esac

PRODUCT="Nightdrive"
APP="dist/Nightdrive.app"
APP_INTENTS_CONST="$PWD/.scratch/Nightdrive.swiftconstvalues"
APP_INTENTS_PROTOCOLS="$PWD/scripts/app-intents-protocols.json"
mkdir -p "$PWD/.scratch"
# Whole-module SwiftPM builds leave this intermediate beside Package.swift.
trap 'rm -f Nightdrive.o' EXIT

DEVELOPMENT_TOOLS_FLAGS=()
if [[ "$CONFIG" == "release" && -n "${DEVELOPMENT_TOOLS:-}" ]]; then
  DEVELOPMENT_TOOLS_FLAGS=(-Xswiftc -DNIGHTDRIVE_DEVELOPMENT_TOOLS)
fi

DEV_TITLE_SUFFIX=""
if [[ "$CONFIG" != "release" || -n "${DEVELOPMENT_TOOLS:-}" ]]; then
  if BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" && [[ "$BRANCH" != "HEAD" ]]; then
    DEV_TITLE_SUFFIX="$BRANCH"
  elif SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null)"; then
    DEV_TITLE_SUFFIX="detached-$SHORT_SHA"
  else
    DEV_TITLE_SUFFIX="local"
  fi
fi

node scripts/run-swiftpm.mjs build -c "$CONFIG" --disable-index-store \
  ${DEVELOPMENT_TOOLS_FLAGS[@]+"${DEVELOPMENT_TOOLS_FLAGS[@]}"} \
  -Xswiftc -whole-module-optimization \
  -Xswiftc -emit-const-values \
  -Xswiftc -emit-const-values-path -Xswiftc "$APP_INTENTS_CONST" \
  -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
  -Xswiftc -Xfrontend -Xswiftc "$APP_INTENTS_PROTOCOLS"
BUILD_PRODUCTS_DIR="$(
  node scripts/run-swiftpm.mjs build -c "$CONFIG" \
    ${DEVELOPMENT_TOOLS_FLAGS[@]+"${DEVELOPMENT_TOOLS_FLAGS[@]}"} --show-bin-path
)"
BIN="$BUILD_PRODUCTS_DIR/$PRODUCT"

if [[ ! -x "$BIN" ]]; then
  echo "SwiftPM did not produce an executable at $BIN" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/PrivacyInfo.xcprivacy" \
  "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

# Release identity. Signed releases export both values from the annotated
# v<version>+<build> tag (scripts/release-version.sh); every other build keeps
# the placeholder values in Resources/Info.plist. Sparkle compares
# CFBundleVersion, so the tag's build component must increase every release.
if [[ -n "${NIGHTDRIVE_VERSION:-}" || -n "${NIGHTDRIVE_BUILD:-}" ]]; then
  if [[ -z "${NIGHTDRIVE_VERSION:-}" || -z "${NIGHTDRIVE_BUILD:-}" ]]; then
    echo "NIGHTDRIVE_VERSION and NIGHTDRIVE_BUILD must be set together" >&2
    exit 1
  fi
  if [[ ! "$NIGHTDRIVE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "NIGHTDRIVE_VERSION must be a three-component version such as 1.0.0" >&2
    exit 1
  fi
  if [[ ! "$NIGHTDRIVE_BUILD" =~ ^[1-9][0-9]*$ ]]; then
    echo "NIGHTDRIVE_BUILD must be a positive integer" >&2
    exit 1
  fi
  plutil -replace CFBundleShortVersionString -string "$NIGHTDRIVE_VERSION" \
    "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$NIGHTDRIVE_BUILD" "$APP/Contents/Info.plist"
fi

# Sparkle (the direct-download update channel): bundle the framework and point
# an rpath at it. install_name_tool invalidates the linker's ad-hoc signature;
# the signing at the end of this script restores it, and the distribution
# script re-signs everything with a real identity afterwards.
if otool -L "$BIN" | grep -q "Sparkle.framework"; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$BUILD_PRODUCTS_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/$PRODUCT"
  # Sparkle's binary framework ships its compile-time SDK surface. Only the
  # framework binary, its localized resources, the updater, and the XPC
  # services are needed at runtime.
  rm -rf \
    "$APP/Contents/Frameworks/Sparkle.framework/Headers" \
    "$APP/Contents/Frameworks/Sparkle.framework/PrivateHeaders" \
    "$APP/Contents/Frameworks/Sparkle.framework/Modules" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Headers" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/PrivateHeaders" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Modules"
  # Check for updates by default without Sparkle's second-launch permission
  # prompt. Sparkle persists any later change the user makes in Settings. The
  # updater still stays inert until packaging stamps SUPublicEDKey, so builds
  # made from source never check for updates.
  plutil -insert SUEnableAutomaticChecks -bool true "$APP/Contents/Info.plist"
fi

if [[ -n "$DEV_TITLE_SUFFIX" ]]; then
  plutil -insert NightdriveDevelopmentTitleSuffix -string "$DEV_TITLE_SUFFIX" \
    "$APP/Contents/Info.plist"
  plutil -replace CFBundleName -string "Nightdrive ($DEV_TITLE_SUFFIX)" \
    "$APP/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string "Nightdrive ($DEV_TITLE_SUFFIX)" \
    "$APP/Contents/Info.plist"
fi

while IFS= read -r -d '' resource_bundle; do
  case "$(basename "$resource_bundle")" in
    *Tests.bundle) continue ;;
  esac
  cp -R "$resource_bundle" "$APP/Contents/Resources/"
done < <(find "$BUILD_PRODUCTS_DIR" -maxdepth 1 -type d -name '*.bundle' -print0)

# A prior SwiftPM build may have copied the catalog into its generated bundle.
# Only compiled .lproj resources belong in the shipped app.
rm -f "$APP/Contents/Resources/Nightdrive_Nightdrive.bundle/Localizable.xcstrings"

# Compile catalog translations into the app's main resource directory, where
# SwiftUI's localized string literals look them up at runtime.
xcrun xcstringstool compile \
  "Resources/Localizable.xcstrings" \
  --output-directory "$APP/Contents/Resources"

# App Intents are registered from compiler-extracted metadata. SwiftPM builds
# the executable but does not run Xcode's metadata processor for our hand-made
# app bundle, so package the metadata explicitly.
APP_INTENTS_SOURCES="$PWD/.scratch/Nightdrive.appintents.sources"
APP_INTENTS_CONST_LIST="$PWD/.scratch/Nightdrive.appintents.constvalues"
find "$PWD/Sources/Nightdrive" -type f -name '*.swift' -print | sort >"$APP_INTENTS_SOURCES"
printf '%s\n' "$APP_INTENTS_CONST" >"$APP_INTENTS_CONST_LIST"
DEVELOPER_DIR="$(xcode-select -p)"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD_VERSION="$(xcodebuild -version | awk '/Build version/ { print $3 }')"
xcrun appintentsmetadataprocessor \
  --output "$APP/Contents/Resources" \
  --toolchain-dir "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain" \
  --module-name "$PRODUCT" \
  --sdk-root "$SDK_ROOT" \
  --xcode-version "$XCODE_BUILD_VERSION" \
  --platform-family macOS \
  --deployment-target 15.0 \
  --target-triple "$(uname -m)-apple-macosx15.0" \
  --source-file-list "$APP_INTENTS_SOURCES" \
  --swift-const-vals-list "$APP_INTENTS_CONST_LIST" \
  --bundle-identifier dev.nightdrive.Nightdrive \
  --binary-file "$BIN" \
  --compile-time-extraction \
  --deployment-aware-processing \
  --no-app-shortcuts-localization \
  --force

if [[ ! -f .scratch/AppIcon.icns || Resources/AppIcon-1024.png -nt .scratch/AppIcon.icns ]]; then
  rm -rf .scratch/AppIcon.iconset
  mkdir -p .scratch/AppIcon.iconset
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon-1024.png \
      --out ".scratch/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" Resources/AppIcon-1024.png \
      --out ".scratch/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns .scratch/AppIcon.iconset -o .scratch/AppIcon.icns
fi
cp .scratch/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

scripts/validate-app-contents.sh "$APP"

chmod -R a+rX "$APP"

# Nested code must carry a valid signature before the bundle seal.
if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
  codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
scripts/validate-app-permissions.sh "$APP"

echo "Built $APP"
