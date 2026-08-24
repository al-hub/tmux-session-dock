#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-smart-pane.sh
# Tests smart pane focus navigation prioritizing Sidebar Session Dock over Subpane
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_SOCKET="dock-test-smart-pane-$$"
BIN_SCRIPT="$REPO_ROOT/scripts/tmux-session-dock"

cleanup() {
    tmux -L "$TEST_SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [1/3] Setting up test environment with Sidebar and Subpane ==="
tmux -L "$TEST_SOCKET" -f /dev/null new-session -d -s test-sess -n main -x 100 -y 30

main_pane="$(tmux -L "$TEST_SOCKET" display-message -p '#{pane_id}')"
[ -n "$main_pane" ] || { echo "FAIL: No main pane"; exit 1; }

# Mock sidebar pane
sidebar_pane="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$main_pane" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$sidebar_pane" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$sidebar_pane" @dotfiles_sidebar_pane 1

# Mock subpane at the bottom of sidebar
subpane_pane="$(tmux -L "$TEST_SOCKET" split-window -v -t "$sidebar_pane" -l 10 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$subpane_pane" -T "dotfiles-sidebar-subpane"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$subpane_pane" @dotfiles_sidebar_subpane 1

# Focus back on main pane
tmux -L "$TEST_SOCKET" select-pane -t "$main_pane"

curr_active="$(tmux -L "$TEST_SOCKET" display-message -p '#{pane_id}')"
[ "$curr_active" = "$main_pane" ] || { echo "FAIL: Main pane not active initially"; exit 1; }

echo "=== [2/3] Executing smart_navigate_pane Left from Main Pane ==="
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$main_pane" bash "$BIN_SCRIPT" --smart-pane L

after_active="$(tmux -L "$TEST_SOCKET" display-message -p '#{pane_id}')"
if [ "$after_active" != "$sidebar_pane" ]; then
    echo "FAIL: Expected active pane to be sidebar ($sidebar_pane), but got ($after_active)!"
    exit 1
fi
echo "PASS: Smart Left navigation properly prioritized Sidebar Session Dock!"

echo "=== [3/3] Executing smart_navigate_pane Right to return to Main Pane ==="
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --smart-pane R

return_active="$(tmux -L "$TEST_SOCKET" display-message -p '#{pane_id}')"
if [ "$return_active" != "$main_pane" ]; then
    echo "FAIL: Expected active pane to return to main ($main_pane), but got ($return_active)!"
    exit 1
fi
echo "PASS: Smart Right navigation returned to Main Work Pane!"

echo "=========================================================================="
echo "ALL TESTS PASS: Smart focus routing verified!"
echo "=========================================================================="
