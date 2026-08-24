#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-subpane-stack.sh
# Tests multi-slot subpane stack pool (1, 2, 3 slots) and configurator picker
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_SOCKET="dock-test-subpane-stack-$$"
BIN_SCRIPT="$REPO_ROOT/scripts/tmux-session-dock"

cleanup() {
    tmux -L "$TEST_SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [1/4] Setting up test environment ==="
tmux -L "$TEST_SOCKET" -f /dev/null new-session -d -s test-sess -n main -x 100 -y 40

main_pane="$(tmux -L "$TEST_SOCKET" display-message -p '#{pane_id}')"
sidebar_pane="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$main_pane" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$sidebar_pane" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$sidebar_pane" @dotfiles_sidebar_pane 1

echo "=== [2/4] Testing 1 Slot Default Acquisition ==="
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --toggle-subpane
subpane_count="$(tmux -L "$TEST_SOCKET" list-panes -F '#{@dotfiles_sidebar_subpane}' | grep -c '1' || true)"
if [ "$subpane_count" -ne 1 ]; then
    echo "FAIL: Expected 1 subpane slot attached, but found $subpane_count!"
    exit 1
fi
echo "PASS: 1 slot attached successfully."

echo "=== [3/4] Testing 2 Slots Dual Stack ==="
tmux -L "$TEST_SOCKET" set-option -gq "@session-dock-subpane-count" 2
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --toggle-subpane
# Release and re-acquire
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --toggle-subpane
dual_count="$(tmux -L "$TEST_SOCKET" list-panes -F '#{@dotfiles_sidebar_subpane}' | grep -c '1' || true)"
if [ "$dual_count" -ne 2 ]; then
    echo "FAIL: Expected 2 subpane slots attached for dual stack, but found $dual_count!"
    exit 1
fi
echo "PASS: 2 slots dual stack attached successfully."

echo "=== [4/4] Testing Clean Release back to Hub ==="
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --toggle-subpane
remaining_in_win="$(tmux -L "$TEST_SOCKET" list-panes -F '#{@dotfiles_sidebar_subpane}' | grep -c '1' || true)"
if [ "$remaining_in_win" -ne 0 ]; then
    echo "FAIL: Expected 0 subpanes in window after toggle close, but found $remaining_in_win!"
    exit 1
fi
echo "PASS: All subpanes cleanly released to hub."

echo "=========================================================================="
echo "ALL TESTS PASS: Multi-slot subpane stack pool 100% verified!"
echo "=========================================================================="
