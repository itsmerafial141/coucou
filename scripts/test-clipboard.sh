#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-clip.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library NotchBuddy/Sources/App/ClipboardStore.swift \
    tests/ClipboardKindTests.swift -o "$TEST_DIR/clip-tests"
"$TEST_DIR/clip-tests"
