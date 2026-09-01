#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"

xcrun swift \
  -I "$TOOLCHAIN/usr/lib/swift/host" \
  -L "$TOOLCHAIN/usr/lib/swift/host" \
  -lSwiftSyntax \
  -lSwiftParser \
  "$ROOT/scripts/localized-error-policy.swift" \
  "$@"
