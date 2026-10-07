#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-superset.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/SupersetData.swift \
    tests/SupersetTests.swift -o "$TEST_DIR/superset-tests"
"$TEST_DIR/superset-tests"
