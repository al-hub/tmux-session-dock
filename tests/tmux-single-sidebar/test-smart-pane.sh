#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-smart-pane.sh
# Smart pane navigation (Alt+arrows):
#   - Left is geometric: from w2 in "sidebar | w1 | w2" it lands on w1
#   - Left from the pane next to the dock column enters the SIDEBAR, never the
#     subpane below it
#   - the subpane is reached from the sidebar with Down
#   - Right from the sidebar returns to the work pane
#   - with the dock hidden, Left from the leftmost work pane stays put
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
t() { tmux -L "$TEST_SOCKET" "$@"; }
active() { t display-message -p -t test-sess:main '#{pane_id}'; }
nav() {   # nav <dir> <from-pane>
    TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$2" bash "$BIN_SCRIPT" --smart-pane "$1"
}
expect() {   # expect <pane> <what>
    local got; got="$(active)"
    [ "$got" = "$1" ] || { echo "FAIL: $2: expected $1, got $got"; t list-panes -t test-sess:main -F '#{pane_id} #{pane_left}-#{pane_right} #{pane_top}-#{pane_bottom} #{pane_title}'; exit 1; }
    echo "PASS: $2"
}

echo "=== [1/6] layout: sidebar(+subpane) | w1 | w2 ==="
t -f /dev/null new-session -d -s test-sess -n main -x 140 -y 30
w1="$(active)"
sidebar="$(t split-window -h -b -t "$w1" -l 34 -P -F '#{pane_id}')"
t select-pane -t "$sidebar" -T "dotfiles-session-sidebar"
t set-option -p -q -t "$sidebar" @dotfiles_sidebar_pane 1
subpane="$(t split-window -v -t "$sidebar" -l 10 -P -F '#{pane_id}')"
t select-pane -t "$subpane" -T "dotfiles-sidebar-subpane"
t set-option -p -q -t "$subpane" @dotfiles_sidebar_subpane 1
w2="$(t split-window -h -t "$w1" -P -F '#{pane_id}')"
t select-pane -t "$w2"
expect "$w2" "w2 active initially"

echo "=== [2/6] Left from w2 lands on w1 (not the sidebar) ==="
nav L "$w2"; expect "$w1" "Left from w2 -> w1"

echo "=== [3/6] Left from w1 enters the sidebar, never the subpane ==="
# Put the cursor row of w1 level with the subpane so plain select-pane -L would pick the subpane.
nav L "$w1"; expect "$sidebar" "Left from w1 -> sidebar"

echo "=== [4/6] Down from the sidebar enters the subpane; Right returns to w1 ==="
nav D "$sidebar"; expect "$subpane" "Down from sidebar -> subpane"
nav R "$subpane"; expect "$w1" "Right from subpane -> w1"
nav L "$w1"; expect "$sidebar" "Left from w1 -> sidebar again"
nav R "$sidebar"; expect "$w1" "Right from sidebar -> w1"

echo "=== [5/6] Left from the sidebar itself stays (leftmost) ==="
t select-pane -t "$sidebar"; nav L "$sidebar"; expect "$sidebar" "Left from sidebar stays"

echo "=== [6/6] dock hidden: Left from the leftmost work pane stays put ==="
t kill-pane -t "$subpane"; t kill-pane -t "$sidebar"
t select-pane -t "$w2"; nav L "$w2"; expect "$w1" "hidden dock: Left from w2 -> w1"
nav L "$w1"; expect "$w1" "hidden dock: Left from w1 stays"

echo "=========================================================================="
echo "ALL TESTS PASS: Smart focus routing verified!"
echo "=========================================================================="
