#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="${TMUX_SESSION_LAUNCHER_UNDER_TEST:-$REPO_ROOT/scripts/tmux-session-launcher}"
FAKE_CODEX="$TEST_DIR/fake-codex-node.js"
SOCKET="gradient-multi-node-codex-$$"
TMP_DIR="$(mktemp -d)"
DEBUG_FILE="$TMP_DIR/debug.log"
sessions=(idle-a idle-b idle-c node-codex)

cleanup() {
    kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    wait "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
sidebar_for() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'
}
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_title}|#{pane_current_command}|#{pane_pid}' >&2 || true
    [ -f "$DEBUG_FILE" ] && tail -n 100 "$DEBUG_FILE" >&2 || true
    exit 1
}

for session in "${sessions[@]}"; do
    if [ "$session" = node-codex ]; then
        tmuxc new-session -d -s "$session" -x 100 -y 30 "node '$FAKE_CODEX'"
    else
        tmuxc new-session -d -s "$session" -x 100 -y 30 'sleep 2147483647'
    fi
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar" >/dev/null
done

coproc ATTACHED {
    script -qefc "tmux -L '$SOCKET' attach-session -t node-codex" \
        --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1
}
CLIENT_PID="$ATTACHED_PID"

ai_pane="$(tmuxc list-panes -t '=node-codex:' -F '#{pane_id}|#{pane_current_command}' | awk -F'|' '$2 == "node" { print $1; exit }')"
[ -n "$ai_pane" ] || fail_test 'Codex-like pane is not reported as node'

deadline=$(( $(date +%s) + 12 ))
screen_changed=false
previous_screen=""
declare -A gradient_seen=()
while [ "$(date +%s)" -lt "$deadline" ]; do
    screen="$(tmuxc capture-pane -p -J -t "$ai_pane" -S -4 | cksum | awk '{print $1}')"
    [ -n "$previous_screen" ] && [ "$screen" != "$previous_screen" ] && screen_changed=true
    previous_screen="$screen"

    for session in "${sessions[@]}"; do
        sidebar="$(sidebar_for "$session")"
        [ -n "$sidebar" ] || continue
        frame="$(tmuxc capture-pane -e -p -t "$sidebar")"
        node_row="$(printf '%s\n' "$frame" | awk '/node-codex/ { print; exit }')"
        if printf '%s' "$node_row" | grep -Fq '38;5;'; then
            gradient_seen["$session"]=true
        fi
    done

    all_seen=true
    for session in "${sessions[@]}"; do
        [ "${gradient_seen[$session]:-false}" = true ] || all_seen=false
    done
    [ "$all_seen" = true ] && break
    sleep 0.1
done

[ "$screen_changed" = true ] || fail_test 'node-based Codex pane did not redraw'
for session in "${sessions[@]}"; do
    [ "${gradient_seen[$session]:-false}" = true ] ||
        fail_test "node-based Codex gradient was absent from $session presenter"
done

printf 'PASS: every presenter renders the redrawing node-based Codex gradient\n'
printf 'SUMMARY: pass=1 xfail=0 fail=0\n'
