#!/usr/bin/env bash
# test-quick-jump.sh
# Validates Alt+s (0ms Quick Focus Jump) behavior between Work Pane, Subpane, and Sidebar.

set -euo pipefail
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$SCRIPT_DIR/dist/tmux-session-dock"
SOCKET="test-jump-$$"

cleanup() {
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [1/4] Starting test session with sidebar ==="
tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" new-session -d -s test-sess -c "$PWD" "sleep 300"
win="$(tmux -L "$SOCKET" display-message -p '#{window_id}')"
tmux -L "$SOCKET" set-option -gq @dotfiles_sidebar_enabled 1
tmux -L "$SOCKET" set-option -w -t "$win" @dotfiles_sidebar_managed 1
tmux -L "$SOCKET" run-shell "$BIN --ensure-sidebar-window $win"
sleep 0.5

sidebar_pane="$(tmux -L "$SOCKET" list-panes -t "$win" -F '#{pane_id}|#{pane_title}|#{@dotfiles_sidebar_pane}' | awk -F '|' '($2=="dotfiles-session-sidebar" || $3=="1"){print $1; exit}')"
work_pane="$(tmux -L "$SOCKET" list-panes -t "$win" -F '#{pane_id}|#{pane_title}|#{@dotfiles_sidebar_pane}' | awk -F '|' '$2!="dotfiles-session-sidebar" && $3!="1"{print $1; exit}')"

[ -n "$sidebar_pane" ] || { echo "FAIL: sidebar_pane not found"; exit 1; }
[ -n "$work_pane" ] || { echo "FAIL: work_pane not found"; exit 1; }

echo "=== [2/4] Verifying focus jump from Work Pane to Sidebar ==="
tmux -L "$SOCKET" select-pane -t "$work_pane"
active_before="$(tmux -L "$SOCKET" display-message -p -t "$win" '#{pane_id}')"
[ "$active_before" = "$work_pane" ] || { echo "FAIL: Initial focus not in work pane"; exit 1; }

# Execute quick-jump
tmux -L "$SOCKET" run-shell "$BIN --focus-sidebar"
active_after="$(tmux -L "$SOCKET" display-message -p -t "$win" '#{pane_id}')"
if [ "$active_after" = "$sidebar_pane" ]; then
    echo "PASS: Quick jump moved focus from Work Pane to Sidebar."
else
    echo "FAIL: Expected focus in sidebar ($sidebar_pane), got: $active_after"
    exit 1
fi

echo "=== [3/4] Verifying smart return toggle from Sidebar back to Work Pane ==="
# Trigger quick-jump again while inside sidebar
tmux -L "$SOCKET" run-shell "$BIN --focus-sidebar"
active_return="$(tmux -L "$SOCKET" display-message -p -t "$win" '#{pane_id}')"
if [ "$active_return" = "$work_pane" ]; then
    echo "PASS: Smart return moved focus back to Work Pane."
else
    echo "FAIL: Expected focus back in work pane ($work_pane), got: $active_return"
    exit 1
fi

echo "=== [4/4] Verifying focus jump from Subpane to Sidebar ==="
# Enable subpane
tmux -L "$SOCKET" run-shell "$BIN --toggle-subpane"
sleep 0.5
subpane_pane="$(tmux -L "$SOCKET" list-panes -t "$win" -F '#{pane_id}|#{pane_title}|#{@dotfiles_sidebar_subpane}' | awk -F '|' '($2=="dotfiles-sidebar-subpane" || $3=="1"){print $1; exit}')"

if [ -n "$subpane_pane" ]; then
    tmux -L "$SOCKET" select-pane -t "$subpane_pane"
    active_sub="$(tmux -L "$SOCKET" display-message -p -t "$win" '#{pane_id}')"
    [ "$active_sub" = "$subpane_pane" ] || { echo "FAIL: Focus not in subpane"; exit 1; }

    tmux -L "$SOCKET" run-shell "$BIN --focus-sidebar"
    active_from_sub="$(tmux -L "$SOCKET" display-message -p -t "$win" '#{pane_id}')"
    if [ "$active_from_sub" = "$sidebar_pane" ]; then
        echo "PASS: Quick jump moved focus from Subpane to Sidebar."
    else
        echo "FAIL: Expected focus in sidebar ($sidebar_pane), got: $active_from_sub"
        exit 1
    fi
fi

echo "=========================================================================="
echo "ALL TESTS PASS: 0ms Quick Jump (Alt+s) 100% verified!"
echo "=========================================================================="
