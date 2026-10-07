#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-phonevps.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/PhoneVPSParsing.swift \
    tests/PhoneVPSParsingTests.swift -o "$TEST_DIR/phonevps-tests"
"$TEST_DIR/phonevps-tests"
