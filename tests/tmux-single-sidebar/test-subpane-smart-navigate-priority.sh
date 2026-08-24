#!/usr/bin/env bash
# Validates smart-pane routing with the default bottom Subpane layout:
# work --Left--> Sidebar --Down--> Subpane --Up--> Sidebar.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-dock"
SOCKET="test-subpane-smart-navigate-$$"

tmuxc() { tmux -L "$SOCKET" -f /dev/null "$@"; }

cleanup()
{
    tmuxc kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

active_pane()
{
    tmuxc display-message -p '#{pane_id}'
}

smart_move()
{
    local pane="$1" direction="$2"
    TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET" TMUX_PANE="$pane" \
        bash "$LAUNCHER" --smart-pane "$direction"
}

tmuxc new-session -d -s smart-navigation -n main -x 100 -y 30 'sleep 300'
window_id="$(tmuxc display-message -p '#{window_id}')"
work_pane="$(tmuxc display-message -p '#{pane_id}')"
sidebar_pane="$(tmuxc split-window -h -b -t "$work_pane" -l 34 -P -F '#{pane_id}')"
tmuxc select-pane -t "$sidebar_pane" -T dotfiles-session-sidebar
tmuxc set-option -p -q -t "$sidebar_pane" @dotfiles_sidebar_pane 1
subpane_pane="$(tmuxc split-window -v -t "$sidebar_pane" -l 10 -P -F '#{pane_id}')"
tmuxc select-pane -t "$subpane_pane" -T dotfiles-sidebar-subpane
tmuxc set-option -p -q -t "$subpane_pane" @dotfiles_sidebar_subpane 1

# The only work-pane route toward the dock is Left. It must choose the
# Sidebar, not jump over it to a Subpane sharing the dock edge.
tmuxc select-pane -t "$work_pane"
smart_move "$work_pane" L
[ "$(active_pane)" = "$sidebar_pane" ] || {
    printf 'FAIL: smart Left from Work did not prioritize Sidebar\n' >&2
    exit 1
}

# A Subpane is entered only after the Sidebar is focused. With the default
# bottom placement, Down is the entry direction.
smart_move "$sidebar_pane" D
[ "$(active_pane)" = "$subpane_pane" ] || {
    printf 'FAIL: smart Down from Sidebar did not enter Subpane\n' >&2
    exit 1
}

# Leaving the Subpane toward the dock returns to Sidebar rather than Work.
smart_move "$subpane_pane" U
[ "$(active_pane)" = "$sidebar_pane" ] || {
    printf 'FAIL: smart Up from Subpane did not return to Sidebar\n' >&2
    exit 1
}

printf 'PASS: smart navigation prioritizes Sidebar and gates Subpane entry through it\n'
