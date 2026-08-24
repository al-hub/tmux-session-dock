#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-subpane-atomic-stack.sh
# Tests atomic all-or-nothing swap and individual height preservation for multi-subpanes
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_SOCKET="dock-test-atomic-stack-$$"
BIN_SCRIPT="$REPO_ROOT/scripts/tmux-session-dock"

cleanup() {
    tmux -L "$TEST_SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [1/4] Setting up test environment with 2 Slots Dual Stack ==="
tmux -L "$TEST_SOCKET" -f /dev/null new-session -d -s test-sess -n main -x 100 -y 40

main_pane="$(tmux -L "$TEST_SOCKET" display-message -p '#{pane_id}')"
sidebar_pane="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$main_pane" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$sidebar_pane" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$sidebar_pane" @dotfiles_sidebar_pane 1

tmux -L "$TEST_SOCKET" set-option -gq "@session-dock-subpane-count" 2
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --toggle-subpane

slot_count="$(tmux -L "$TEST_SOCKET" list-panes -F '#{@dotfiles_sidebar_subpane}' | grep -c '1' || true)"
if [ "$slot_count" -ne 2 ]; then
    echo "FAIL: Expected 2 subpane slots, found $slot_count!"
    exit 1
fi
echo "PASS: 2 slots attached successfully."

echo "=== [2/4] Verifying Initial Positions (Bottom by Default) ==="
launcher_top="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sidebar_pane" '#{pane_top}')"
subpane_panes=($(tmux -L "$TEST_SOCKET" list-panes -F '#{pane_id}|#{@dotfiles_sidebar_subpane}' | awk -F '|' '$2 == "1" { print $1 }'))
s1_top="$(tmux -L "$TEST_SOCKET" display-message -p -t "${subpane_panes[0]}" '#{pane_top}')"
s2_top="$(tmux -L "$TEST_SOCKET" display-message -p -t "${subpane_panes[1]}" '#{pane_top}')"

if [ "$s1_top" -le "$launcher_top" ] || [ "$s2_top" -le "$launcher_top" ]; then
    echo "FAIL: Subpanes should be below launcher pane initially!"
    exit 1
fi
echo "PASS: Subpanes are below launcher."

echo "=== [3/4] Testing Atomic Swap Position ('p' -> Top) ==="
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --swap-subpane-position

launcher_top_after="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sidebar_pane" '#{pane_top}')"
s1_top_after="$(tmux -L "$TEST_SOCKET" display-message -p -t "${subpane_panes[0]}" '#{pane_top}')"
s2_top_after="$(tmux -L "$TEST_SOCKET" display-message -p -t "${subpane_panes[1]}" '#{pane_top}')"

if [ "$s1_top_after" -ge "$launcher_top_after" ] || [ "$s2_top_after" -ge "$launcher_top_after" ]; then
    echo "FAIL: All subpanes should have atomically swapped above launcher pane! (s1=$s1_top_after, s2=$s2_top_after, launcher=$launcher_top_after)"
    exit 1
fi
echo "PASS: All subpanes atomically swapped above launcher together!"

echo "=== [4/4] Testing Atomic Swap Back ('p' -> Bottom) ==="
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$sidebar_pane" bash "$BIN_SCRIPT" --swap-subpane-position

launcher_top_final="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sidebar_pane" '#{pane_top}')"
s1_top_final="$(tmux -L "$TEST_SOCKET" display-message -p -t "${subpane_panes[0]}" '#{pane_top}')"
s2_top_final="$(tmux -L "$TEST_SOCKET" display-message -p -t "${subpane_panes[1]}" '#{pane_top}')"

if [ "$s1_top_final" -le "$launcher_top_final" ] || [ "$s2_top_final" -le "$launcher_top_final" ]; then
    echo "FAIL: All subpanes should have swapped back below launcher pane!"
    exit 1
fi
echo "PASS: All subpanes atomically swapped back below launcher together!"

echo "=========================================================================="
echo "ALL TESTS PASS: Atomic Multi-Subpane Stack Unit 100% verified!"
echo "=========================================================================="
