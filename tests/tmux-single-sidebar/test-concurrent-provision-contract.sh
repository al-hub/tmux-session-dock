#!/usr/bin/env bash
# Two provisioners can target the same window at once: an explicit
# --ensure-sidebar-window and the after-new-session hook.  Each used to pick
# its own "canonical" sidebar pane while reconciling duplicates and kill the
# other's, leaving the window with no sidebar at all (ghost-row test:
# "timeout waiting for sess-epsilon Presenter ready").  Every window must end
# with exactly one sidebar pane that becomes ready.
set -euo pipefail
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAUNCHER="$SCRIPT_DIR/scripts/tmux-session-launcher"
SOCKET="test-concurrent-provision-$$"
export TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET"

cleanup() { tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; tmuxc list-panes -a -F '#{session_name}|#{window_id}|#{pane_id}|#{pane_title}|#{pane_dead}' >&2 || true; exit 1; }
sidebar_count() { tmuxc list-panes -t "$1" -F '#{pane_title}' 2>/dev/null | grep -Fxc dotfiles-session-sidebar || true; }

tmuxc new-session -d -s anchor -x 120 -y 40 'sleep 300'
for round in 1 2 3 4 5; do
    session="race-$round"
    tmuxc new-session -d -s "$session" -x 120 -y 40 'sleep 300'
    window="$(tmuxc display-message -p -t "=$session:" '#{window_id}')"
    tmuxc set-option -wq -t "$window" @dotfiles_sidebar_managed 1
    # Three provisioners at once: two explicit ensures plus the session ensure
    # the hook would run.
    TMUX="$SOCKET" bash "$LAUNCHER" --ensure-sidebar-window "$window" 35 >/dev/null 2>&1 &
    TMUX="$SOCKET" bash "$LAUNCHER" --ensure-sidebar-window "$window" 35 >/dev/null 2>&1 &
    TMUX="$SOCKET" bash "$LAUNCHER" --ensure-sidebar-session "$session" >/dev/null 2>&1 &
    wait
    deadline=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ "$(tmuxc show-options -wqv -t "$window" @dotfiles_sidebar_ready 2>/dev/null || true)" = 1 ] && break
        sleep 0.1
    done
    count="$(sidebar_count "$window")"
    [ "$count" -eq 1 ] || fail "round $round: window $window has $count sidebar panes after concurrent provisioning"
    [ "$(tmuxc show-options -wqv -t "$window" @dotfiles_sidebar_ready 2>/dev/null || true)" = 1 ] || fail "round $round: sidebar in $window never became ready"
    pane="$(tmuxc list-panes -t "$window" -F '#{pane_id}|#{pane_title}' | awk -F'|' '!done && $2 == "dotfiles-session-sidebar" { print $1; done = 1 }')"
    [ "$(tmuxc show-options -wqv -t "$window" @dotfiles_sidebar_pane_id)" = "$pane" ] || fail "round $round: window option points to $(tmuxc show-options -wqv -t "$window" @dotfiles_sidebar_pane_id), live sidebar is $pane"
done
echo "PASS: concurrent provisioners converge on one ready sidebar pane per window"
