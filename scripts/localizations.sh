#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in
  update | verify) ;;
  *)
    echo "usage: $0 <update|verify>" >&2
    exit 2
    ;;
esac

ROOT="$PWD"
CATALOG="$ROOT/Resources/Localizable.xcstrings"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nightdrive-localizations.XXXXXX")"
STRINGS_DATA="$TEMP_ROOT/stringsdata"
CANDIDATE="$TEMP_ROOT/Localizable.xcstrings"
trap 'rm -rf "$TEMP_ROOT"' EXIT
mkdir -p "$STRINGS_DATA"

if [[ ! -f "$CATALOG" ]]; then
  echo "localization catalog not found: $CATALOG" >&2
  exit 1
fi

# Compiler extraction gives interpolations their real printf types. The
# lightweight xcstringstool parser substitutes %arg and cannot safely update
# a catalog that translators depend on.
node scripts/run-swiftpm.mjs build -c debug \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path \
  -Xswiftc "$STRINGS_DATA"

stringsdata_args=()
while IFS= read -r -d '' stringsdata; do
  source_file="$(plutil -extract source raw "$stringsdata" 2>/dev/null || true)"
  case "$source_file" in
    "$ROOT/Sources/Nightdrive/Development/"* | "$ROOT/Sources/Nightdrive/Demo/"*)
      # Development-only controls and scripted demo copy do not ship as
      # production translation work.
      continue
      ;;
    "$ROOT/Sources/Nightdrive/"*)
      stringsdata_args+=(--stringsdata "$stringsdata")
      ;;
  esac
done < <(find "$STRINGS_DATA" -type f -name '*.stringsdata' -print0)

if [[ "${#stringsdata_args[@]}" -eq 0 ]]; then
  echo "compiler produced no Nightdrive localization data" >&2
  exit 1
fi

cp "$CATALOG" "$CANDIDATE"
xcrun xcstringstool sync "$CANDIDATE" "${stringsdata_args[@]}"

if [[ "$MODE" == "update" ]]; then
  cp "$CANDIDATE" "$CATALOG"
  count="$(xcrun xcstringstool print "$CATALOG" | wc -l | tr -d ' ')"
  echo "Updated $CATALOG ($count keys)"
  exit 0
fi

if ! cmp -s "$CATALOG" "$CANDIDATE"; then
  echo "String catalog is out of date. Run: make localizations" >&2
  diff -u "$CATALOG" "$CANDIDATE" || true
  exit 1
fi

echo "String catalog is up to date."
