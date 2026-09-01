#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nightdrive-app-metadata.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

APP="$FIXTURE_ROOT/Nightdrive.app"
CONTENTS="$APP/Contents"
SPARKLE_LICENSE_DIR="$CONTENTS/Resources/Nightdrive_Nightdrive.bundle/ThirdPartyNotices"
SPARKLE_LICENSE="$SPARKLE_LICENSE_DIR/Sparkle.txt"
APP_INTENTS_METADATA="$CONTENTS/Resources/Metadata.appintents"
mkdir -p "$CONTENTS/MacOS" "$APP_INTENTS_METADATA" "$SPARKLE_LICENSE_DIR"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/PrivacyInfo.xcprivacy "$CONTENTS/Resources/PrivacyInfo.xcprivacy"
cp Sources/Nightdrive/Resources/ThirdPartyNotices/Sparkle.txt "$SPARKLE_LICENSE"
touch "$CONTENTS/Resources/AppIcon.icns" "$CONTENTS/MacOS/Nightdrive"
printf '{"version":"3.0"}\n' >"$APP_INTENTS_METADATA/version.json"
printf '%s\n' \
  '{"actions":{"ToggleNightdrivePlaybackIntent":{"identifier":"ToggleNightdrivePlaybackIntent"}}}' \
  >"$APP_INTENTS_METADATA/extract.actionsdata"
chmod +x "$CONTENTS/MacOS/Nightdrive"

reset_info() {
  cp Resources/Info.plist "$CONTENTS/Info.plist"
}

expect_rejected() {
  local description="$1"
  local expected="$2"
  local output
  if output="$(scripts/validate-app-contents.sh "$APP" 2>&1)"; then
    echo "Expected invalid $description metadata to be rejected" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "Invalid $description metadata failed for the wrong reason: $output" >&2
    exit 1
  fi
}

scripts/validate-app-contents.sh "$APP"

mv "$APP_INTENTS_METADATA/extract.actionsdata" "$FIXTURE_ROOT/extract.actionsdata"
expect_rejected app-intents "Metadata.appintents/extract.actionsdata"
mv "$FIXTURE_ROOT/extract.actionsdata" "$APP_INTENTS_METADATA/extract.actionsdata"

printf '\ncorrupt but marker-preserving suffix\n' >>"$SPARKLE_LICENSE"
expect_rejected sparkle-license "does not match the pinned source notice"
cp Sources/Nightdrive/Resources/ThirdPartyNotices/Sparkle.txt "$SPARKLE_LICENSE"

plutil -remove CFBundleURLTypes "$CONTENTS/Info.plist"
expect_rejected url-scheme "invalid CFBundleURLTypes.0.CFBundleURLName"

reset_info
plutil -replace NSHumanReadableCopyright -string "Nostalgic, not stuck in the past" \
  "$CONTENTS/Info.plist"
expect_rejected copyright "invalid NSHumanReadableCopyright"

reset_info
plutil -replace CFBundleShortVersionString -string "1.0" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "1" "$CONTENTS/Info.plist"
expect_rejected version "invalid version metadata"

reset_info
plutil -replace CFBundleShortVersionString -string "1.2.3" "$CONTENTS/Info.plist"
expect_rejected partial-version "invalid version metadata"

plutil -replace CFBundleVersion -string "42" "$CONTENTS/Info.plist"
scripts/validate-app-contents.sh "$APP"

echo "App metadata validation tests passed."
