#!/usr/bin/env bash
# Locks the installed Alt+arrow route to smart_navigate_pane.  Native tmux
# geometry chooses the bottom Subpane from Work+Left, so this must not be a
# raw `select-pane -L` binding.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
PLUGIN_ENTRY="$REPO_ROOT/session-dock.tmux"
LAUNCHER="$REPO_ROOT/dist/tmux-session-dock"
SOCKET="test-subpane-alt-navigation-$$"

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

tmuxc new-session -d -s alt-navigation -n main -x 100 -y 30 'sleep 300'
tmuxc run-shell "bash '$PLUGIN_ENTRY'"

binding="$(tmuxc list-keys -T root M-Left)"
case "$binding" in
    *'run-shell'*'--smart-pane L'*) ;;
    *)
        printf 'FAIL: M-Left must delegate to smart_navigate_pane; binding was: %s\n' "$binding" >&2
        exit 1
        ;;
esac

work_pane="$(active_pane)"
sidebar_pane="$(tmuxc split-window -h -b -t "$work_pane" -l 34 -P -F '#{pane_id}')"
tmuxc select-pane -t "$sidebar_pane" -T dotfiles-session-sidebar
tmuxc set-option -p -q -t "$sidebar_pane" @dotfiles_sidebar_pane 1
subpane_pane="$(tmuxc split-window -v -t "$sidebar_pane" -l 10 -P -F '#{pane_id}')"
tmuxc select-pane -t "$subpane_pane" -T dotfiles-sidebar-subpane
tmuxc set-option -p -q -t "$subpane_pane" @dotfiles_sidebar_subpane 1

tmuxc select-pane -t "$work_pane"
TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET" TMUX_PANE="$work_pane" \
    bash "$LAUNCHER" --smart-pane L
[ "$(active_pane)" = "$sidebar_pane" ] || {
    printf 'FAIL: M-Left smart route did not prioritize Sidebar over Subpane\n' >&2
    exit 1
}

printf 'PASS: M-Left delegates to smart navigation and prioritizes Sidebar\n'
