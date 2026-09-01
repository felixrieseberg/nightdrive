#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-dist/Nightdrive.app}"
CONTENTS="$APP_PATH/Contents"
EXECUTABLE="$CONTENTS/MacOS/Nightdrive"
RESOURCES="$CONTENTS/Resources"
PRIVACY_MANIFEST="$RESOURCES/PrivacyInfo.xcprivacy"
APP_INTENTS_METADATA="$RESOURCES/Metadata.appintents"
SPARKLE_LICENSE="$RESOURCES/Nightdrive_Nightdrive.bundle/ThirdPartyNotices/Sparkle.txt"
SOURCE_SPARKLE_LICENSE="$ROOT/Sources/Nightdrive/Resources/ThirdPartyNotices/Sparkle.txt"
EXPECTED_SPARKLE_REVISION="79bc9e872948e47877e76f194cb0c8e0412b0b90"
# The upstream notice has one trailing space; the bundled copy removes it.
EXPECTED_SPARKLE_LICENSE_SHA256="816be66341dd11b22806862dffd8392b240babaced1cdf24da2ff413ef00c3fd"

resolved_sparkle_revision="$(
  node -e '
    const fs = require("node:fs");
    const resolved = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const sparkle = resolved.pins.find((pin) => pin.identity === "sparkle");
    if (!sparkle?.state?.revision) process.exit(1);
    process.stdout.write(sparkle.state.revision);
  ' "$ROOT/Package.resolved"
)" || {
  echo "Package.resolved has no pinned Sparkle revision" >&2
  exit 1
}
if [[ "$resolved_sparkle_revision" != "$EXPECTED_SPARKLE_REVISION" ]]; then
  echo "Sparkle changed; update its bundled license and pinned license digest" >&2
  exit 1
fi

source_sparkle_license_sha256="$(shasum -a 256 "$SOURCE_SPARKLE_LICENSE" | awk '{print $1}')"
if [[ "$source_sparkle_license_sha256" != "$EXPECTED_SPARKLE_LICENSE_SHA256" ]]; then
  echo "Source Sparkle license does not match its pinned digest" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

for required_file in \
  "$CONTENTS/Info.plist" \
  "$EXECUTABLE" \
  "$RESOURCES/AppIcon.icns" \
  "$PRIVACY_MANIFEST" \
  "$APP_INTENTS_METADATA/version.json" \
  "$APP_INTENTS_METADATA/extract.actionsdata" \
  "$SPARKLE_LICENSE"; do
  if [[ ! -f "$required_file" ]]; then
    echo "App bundle is missing runtime file: $required_file" >&2
    exit 1
  fi
done

if ! cmp -s "$SOURCE_SPARKLE_LICENSE" "$SPARKLE_LICENSE"; then
  echo "Bundled Sparkle license does not match the pinned source notice" >&2
  exit 1
fi

intent_identifier="$(
  plutil -extract actions.ToggleNightdrivePlaybackIntent.identifier raw \
    "$APP_INTENTS_METADATA/extract.actionsdata" 2>/dev/null || true
)"
if [[ "$intent_identifier" != "ToggleNightdrivePlaybackIntent" ]]; then
  echo "App Intents metadata does not describe Nightdrive's playback intent" >&2
  exit 1
fi

document_role="$(
  plutil -extract CFBundleDocumentTypes.0.CFBundleTypeRole raw "$CONTENTS/Info.plist" \
    2>/dev/null || true
)"
handler_rank="$(
  plutil -extract CFBundleDocumentTypes.0.LSHandlerRank raw "$CONTENTS/Info.plist" \
    2>/dev/null || true
)"
if [[ "$document_role" != "Viewer" || "$handler_rank" != "Alternate" ]]; then
  echo "App bundle must register audio files as an alternate viewer" >&2
  exit 1
fi

audio_content_types=(
  public.mp3
  com.apple.m4a-audio
  com.apple.protected-mpeg-4-audio-b
  public.aac-audio
  com.microsoft.waveform-audio
  public.aiff-audio
  org.xiph.flac
  com.apple.coreaudio-format
)
for index in "${!audio_content_types[@]}"; do
  actual="$(
    plutil -extract "CFBundleDocumentTypes.0.LSItemContentTypes.$index" raw \
      "$CONTENTS/Info.plist" 2>/dev/null || true
  )"
  if [[ "$actual" != "${audio_content_types[$index]}" ]]; then
    echo "App bundle has an invalid audio content type at index $index: '$actual'" >&2
    exit 1
  fi
done

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "App executable is not executable: $EXECUTABLE" >&2
  exit 1
fi

plutil -lint "$CONTENTS/Info.plist" "$PRIVACY_MANIFEST" >/dev/null

development_suffix="$(
  plutil -extract NightdriveDevelopmentTitleSuffix raw "$CONTENTS/Info.plist" 2>/dev/null || true
)"
expected_app_name="Nightdrive"
if [[ -n "$development_suffix" ]]; then
  expected_app_name="Nightdrive ($development_suffix)"
fi

for key_and_value in \
  "CFBundleDevelopmentRegion:en" \
  "CFBundleExecutable:Nightdrive" \
  "CFBundleIdentifier:dev.nightdrive.Nightdrive" \
  "CFBundleURLTypes.0.CFBundleURLName:dev.nightdrive.library" \
  "CFBundleURLTypes.0.CFBundleURLSchemes.0:nightdrive" \
  "CFBundleInfoDictionaryVersion:6.0" \
  "CFBundleName:$expected_app_name" \
  "CFBundleDisplayName:$expected_app_name" \
  "CFBundlePackageType:APPL" \
  "CFBundleIconFile:AppIcon" \
  "LSMinimumSystemVersion:15.0" \
  "LSApplicationCategoryType:public.app-category.music" \
  "NSHighResolutionCapable:true" \
  "NSHumanReadableCopyright:Copyright © 2026 Felix Rieseberg" \
  "NSPrincipalClass:NSApplication"; do
  key="${key_and_value%%:*}"
  expected="${key_and_value#*:}"
  actual="$(plutil -extract "$key" raw "$CONTENTS/Info.plist" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "App bundle has invalid $key: expected '$expected', got '$actual'" >&2
    exit 1
  fi
done

marketing_version="$(
  plutil -extract CFBundleShortVersionString raw "$CONTENTS/Info.plist" 2>/dev/null || true
)"
build_number="$(
  plutil -extract CFBundleVersion raw "$CONTENTS/Info.plist" 2>/dev/null || true
)"
if [[ "$marketing_version" == "0.0.0" && "$build_number" == "0" ]]; then
  : # Development build: both values are deliberate placeholders.
elif [[ "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
  && "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  : # Release build: both values came from a v<version>+<build> tag.
else
  echo "App bundle has invalid version metadata: '$marketing_version' ('$build_number')" >&2
  exit 1
fi

tracking="$(plutil -extract NSPrivacyTracking raw "$PRIVACY_MANIFEST" 2>/dev/null || true)"
if [[ "$tracking" != "false" ]]; then
  echo "Privacy manifest must declare NSPrivacyTracking=false" >&2
  exit 1
fi

unexpected_contents="$(
  find "$CONTENTS" -mindepth 1 -maxdepth 1 \
    ! -name Info.plist ! -name MacOS ! -name Resources \
    ! -name Frameworks ! -name _CodeSignature -print
)"
unexpected_executables="$(
  find "$CONTENTS/MacOS" -mindepth 1 ! -path "$EXECUTABLE" -print
)"
unexpected_resources="$(
  find "$RESOURCES" -mindepth 1 -maxdepth 1 \
    ! -name AppIcon.icns \
    ! -name PrivacyInfo.xcprivacy \
    ! -name Metadata.appintents \
    ! -name '*.bundle' \
    ! -name '*.lproj' \
    -print
)"

if [[ -n "$unexpected_contents$unexpected_executables$unexpected_resources" ]]; then
  echo "App bundle contains unexpected top-level runtime entries:" >&2
  printf '%s\n' \
    "$unexpected_contents" "$unexpected_executables" "$unexpected_resources" \
    | sed '/^$/d' >&2
  exit 1
fi

invalid_entries="$(
  find "$APP_PATH" \
    ! -path '*.bundle/VisualizerExamples/*' \
    \( \
    -path '*Tests.bundle*' -o \
    \( -type d \( \
      -name '.git' -o -name 'Sources' -o -name 'Tests' -o \
      -name 'scripts' -o -name 'Scripts' -o -name 'Plugins' \
    \) \) -o \
    -name 'Package.swift' -o \
    -name '*.xcstrings' -o \
    -name '*.swift' -o \
    -name '*.py' -o -name '*.pyc' -o -name '*.pyo' -o \
    -name '*.m' -o -name '*.mm' -o \
    -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o \
    -name '*.h' -o -name '*.hh' -o -name '*.hpp' -o \
    -name '*.metal' -o -name '*.modulemap' -o \
    -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o \
    -name '*.ts' -o -name '*.tsx' -o \
    -name '*.rs' -o -name '*.go' -o -name '*.java' -o \
    -name '*.rb' -o -name '*.pl' -o -name '*.php' -o \
    -name '*.sh' -o -name '*.bash' -o -name '*.zsh' \
  \) -print
)"

if [[ -n "$invalid_entries" ]]; then
  echo "App bundle contains source, test, or build-only artifacts:" >&2
  printf '%s\n' "$invalid_entries" >&2
  exit 1
fi
