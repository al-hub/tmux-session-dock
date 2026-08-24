#!/usr/bin/env bash
# Unit test for sidebar_ime.sh deep module
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/scripts/lib/sidebar_ime.sh"

echo "=== [1/4] Testing Backend Detection ==="
backend="$(sidebar_ime_detect_backend)"
echo "Detected backend: $backend"

echo "=== [2/4] Testing Fallback Behavior ==="
# Calling switch when no backend or unknown shouldn't error out
sidebar_ime_switch_to_english "test-ctx"
sidebar_ime_restore "test-ctx"
echo "PASS: Fallback executed cleanly with 0 exit code."

echo "=== [3/4] Testing Fast-Path English Detection ==="
# Mocking get_current
sidebar_ime_get_current() { echo "1033"; }
if ! sidebar_ime_is_english; then
    echo "FAIL: expected 1033 to be English"
    exit 1
fi
echo "PASS: Fast-path English detection works."

echo "=== [4/4] Testing Non-English Trigger ==="
sidebar_ime_get_current() { echo "ko-KR"; }
if sidebar_ime_is_english; then
    echo "FAIL: expected ko-KR to NOT be English"
    exit 1
fi
echo "PASS: Non-English condition properly identified."

echo "=================================================="
echo "ALL TESTS PASS: sidebar_ime.sh verified!"
echo "=================================================="
