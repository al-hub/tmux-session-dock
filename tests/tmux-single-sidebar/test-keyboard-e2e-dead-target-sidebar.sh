#!/usr/bin/env bash
# Enter on a session whose Sidebar Presenter process died (external SIGTERM):
# the switch must respawn the dead pane and land on the target.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec env TMUX_KEYBOARD_E2E_SCENARIO=dead-target-sidebar \
    bash "$TEST_DIR/test-keyboard-e2e.sh"
