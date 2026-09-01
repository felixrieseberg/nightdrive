#!/usr/bin/env bash
# Build, Developer ID-sign, notarize, staple, and zip the direct-download app.
#
# Local structural validation (ad-hoc signature, no notarization):
#   scripts/package-developer-id.sh
#
# Release build (see DISTRIBUTION.md):
#   APP_SIGN_IDENTITY="Developer ID Application: …" \
#   NOTARY_PROFILE=nightdrive-notary \
#   SPARKLE_PUBLIC_ED_KEY="base64 public key from generate_keys" \
#   scripts/package-developer-id.sh
#
# NOTARY_PROFILE names keychain credentials created once with:
#   xcrun notarytool store-credentials nightdrive-notary
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH="${APP_PATH:-dist/Nightdrive.app}"
UPDATES_DIR="${UPDATES_DIR:-dist/updates}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"

# Signed artifacts must derive both bundle versions from the annotated release
# tag at HEAD. Ad-hoc local validation deliberately keeps build-app.sh's
# development defaults.
if [[ "$APP_SIGN_IDENTITY" != "-" ]]; then
  release_metadata="$(scripts/release-version.sh)"
  IFS=$'\t' read -r NIGHTDRIVE_TAG NIGHTDRIVE_VERSION NIGHTDRIVE_BUILD <<<"$release_metadata"
  export NIGHTDRIVE_TAG NIGHTDRIVE_VERSION NIGHTDRIVE_BUILD
else
  NIGHTDRIVE_VERSION="${NIGHTDRIVE_VERSION:-0.0.0}"
fi

MAIN_EXECUTABLE="$APP_PATH/Contents/MacOS/Nightdrive"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
ZIP_PATH="$UPDATES_DIR/Nightdrive-$NIGHTDRIVE_VERSION.zip"

if [[ "$APP_SIGN_IDENTITY" != "-" ]]; then
  if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    cat >&2 <<'EOF'
SPARKLE_PUBLIC_ED_KEY is required for a distribution-signed build. Generate a
Sparkle EdDSA key pair once (the private key stays in your login keychain):

  .build/artifacts/sparkle/Sparkle/bin/generate_keys

then pass the printed public key, e.g. make developerid SPARKLE_PUBLIC_ED_KEY=…
EOF
    exit 1
  fi
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "NOTARY_PROFILE is required for a distribution-signed build" \
      "(create with: xcrun notarytool store-credentials <name>)." >&2
    exit 1
  fi
  SIGN_TIMESTAMP_ARGS=(--timestamp)
else
  SIGN_TIMESTAMP_ARGS=(--timestamp=none)
fi

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  scripts/build-app.sh release
fi

if [[ ! -d "$APP_PATH" || ! -f "$MAIN_EXECUTABLE" ]]; then
  echo "Missing app bundle at $APP_PATH" >&2
  exit 1
fi
scripts/validate-app-contents.sh "$APP_PATH"

if [[ "$APP_SIGN_IDENTITY" != "-" ]]; then
  actual_version="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
  actual_build="$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
  if [[ "$actual_version" != "$NIGHTDRIVE_VERSION" || "$actual_build" != "$NIGHTDRIVE_BUILD" ]]; then
    echo "App bundle version $actual_version ($actual_build) does not match release tag" \
      "$NIGHTDRIVE_TAG: $NIGHTDRIVE_VERSION ($NIGHTDRIVE_BUILD)." >&2
    exit 1
  fi
fi

# A shipping bundle carries neither half of the Develop menu's gate.
if [[ -n "$(plutil -extract NightdriveDevelopmentTitleSuffix raw \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)" ]]; then
  echo "Release bundle carries the development title suffix." >&2
  exit 1
fi
# These names exist only inside NIGHTDRIVE_DEVELOPMENT_TOOLS code — including
# the dev/test CLI subcommands — so an ordinary release binary contains none
# of them. The snapshot harness is deliberately absent from this list: it
# ships in every configuration, as does the user-facing reset-sidecar command.
# `grep -q` exits on first match, which can SIGPIPE `strings` and — under
# pipefail — flip a *match* into a bypassed guard. `grep -c` reads the whole
# stream, so the count is reliable.
DEV_TOOL_MATCHES="$(
  strings "$MAIN_EXECUTABLE" \
    | grep -cE 'DevelopmentCommands|DevelopmentSafety|DemoAutoRun|NIGHTDRIVE_DEMO_TRACK|seed-demo|benchmark-library|--assume-empty-ledger' \
    || true
)"
if [[ "$DEV_TOOL_MATCHES" != "0" ]]; then
  echo "Release executable contains development-tool activation paths." >&2
  exit 1
fi

# The direct-download channel is the one that must update itself.
if ! otool -L "$MAIN_EXECUTABLE" | grep -q "Sparkle.framework"; then
  echo "Release executable does not link Sparkle." >&2
  exit 1
fi
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Missing $SPARKLE_FRAMEWORK in the app bundle." >&2
  exit 1
fi

# Stamp the Sparkle public key. Its presence is also the runtime switch that
# activates the updater (see UpdaterService.swift), so builds without the stamp
# never check for updates. The feed URL itself lives in AppLinks.swift.
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null \
    || plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" \
      "$APP_PATH/Contents/Info.plist"
fi
if ! plutil -extract SUEnableAutomaticChecks raw "$APP_PATH/Contents/Info.plist" \
  | grep -qx true; then
  echo "Direct-download build must enable automatic update checks by default." >&2
  exit 1
fi

# Staging can attach Finder metadata or provenance xattrs. Strip those before
# signing, and normalize read/traverse permissions for SKIP_BUILD callers and
# multi-user installations.
chmod -R u+w,a+rX "$APP_PATH"
xattr -cr "$APP_PATH"

# Sign inside-out with the hardened runtime (required for notarization).
# Sparkle ships helpers signed by the Sparkle project; library validation under
# the hardened runtime requires everything to carry *our* identity, so re-sign
# them in the order Sparkle's distribution docs prescribe. Downloader.xpc keeps
# its own (sandbox) entitlements.
codesign --force --sign "$APP_SIGN_IDENTITY" "${SIGN_TIMESTAMP_ARGS[@]}" \
  --options runtime --preserve-metadata=entitlements \
  "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign "$APP_SIGN_IDENTITY" "${SIGN_TIMESTAMP_ARGS[@]}" \
  --options runtime \
  "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign "$APP_SIGN_IDENTITY" "${SIGN_TIMESTAMP_ARGS[@]}" \
  --options runtime \
  "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
codesign --force --sign "$APP_SIGN_IDENTITY" "${SIGN_TIMESTAMP_ARGS[@]}" \
  --options runtime \
  "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
codesign --force --sign "$APP_SIGN_IDENTITY" "${SIGN_TIMESTAMP_ARGS[@]}" \
  --options runtime \
  "$SPARKLE_FRAMEWORK"

# Any remaining nested Mach-O files (outside the already-sealed framework).
find "$APP_PATH/Contents" -type f -print0 | while IFS= read -r -d '' candidate; do
  [[ "$candidate" == "$MAIN_EXECUTABLE" ]] && continue
  [[ "$candidate" == "$SPARKLE_FRAMEWORK/"* ]] && continue
  file -b "$candidate" | grep -q "Mach-O" || continue
  codesign --force --sign "$APP_SIGN_IDENTITY" "${SIGN_TIMESTAMP_ARGS[@]}" \
    --options runtime "$candidate"
done

codesign --force --sign "$APP_SIGN_IDENTITY" "${SIGN_TIMESTAMP_ARGS[@]}" \
  --options runtime "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
scripts/validate-app-contents.sh "$APP_PATH"
scripts/validate-app-permissions.sh "$APP_PATH"

mkdir -p "$UPDATES_DIR"
scripts/create-app-archive.sh "$APP_PATH" "$ZIP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  # Staple the ticket to the app, then rebuild the zip so offline first
  # launches pass Gatekeeper without a round-trip to Apple.
  xcrun stapler staple "$APP_PATH"
  scripts/create-app-archive.sh "$APP_PATH" "$ZIP_PATH"
  spctl --assess --type execute --verbose "$APP_PATH"
  echo "Built, notarized, and stapled: $ZIP_PATH"
else
  echo "Built an ad-hoc-signed archive for local validation: $ZIP_PATH"
  echo "(Set APP_SIGN_IDENTITY and NOTARY_PROFILE for a distributable build.)"
fi
