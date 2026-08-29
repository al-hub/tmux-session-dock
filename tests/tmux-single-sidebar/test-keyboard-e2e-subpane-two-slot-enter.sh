#!/usr/bin/env bash
# Two-slot variant of the multi-slot Enter reproduction: distinct heights,
# real p swaps and a real Enter roundtrip, slot order asserted at every step.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec env TMUX_KEYBOARD_E2E_SCENARIO=subpane-multi-slot-enter TMUX_KEYBOARD_E2E_SUBPANE_COUNT=2 PTY_BRIDGE_ROWS=40 \
    bash "$TEST_DIR/test-keyboard-e2e.sh"
