#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="${TMUX_SESSION_LAUNCHER_UNDER_TEST:-$REPO_ROOT/scripts/tmux-session-launcher}"
FAKE_CODEX="$TEST_DIR/fake-codex-node.js"
SOCKET="gradient-node-codex-$$"
TMP_DIR="$(mktemp -d)"
DEBUG_FILE="$TMP_DIR/debug.log"

cleanup() {
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_current_command}|#{pane_pid}' >&2 || true
    [ -f "$DEBUG_FILE" ] && tail -n 60 "$DEBUG_FILE" >&2 || true
    exit 1
}

tmuxc new-session -d -s node-codex -x 100 -y 30 "node '$FAKE_CODEX'"
tmuxc set-option -q -t '=node-codex:' @dotfiles_sidebar_managed 1
sidebar="$(tmuxc split-window -d -P -F '#{pane_id}' -t '=node-codex:' -h -b -l 35 \
    "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_ANIMATE_DETACHED=true TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar")"

ai_pane="$(tmuxc list-panes -t '=node-codex:' -F '#{pane_id}|#{pane_current_command}' | awk -F'|' '$2 == "node" { print $1; exit }')"
[ -n "$ai_pane" ] || fail_test 'Codex-like pane is not reported as node'

deadline=$(( $(date +%s) + 8 ))
screen_changed=false
gradient_seen=false
previous_screen=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    screen="$(tmuxc capture-pane -p -J -t "$ai_pane" -S -4 | cksum | awk '{print $1}')"
    [ -n "$previous_screen" ] && [ "$screen" != "$previous_screen" ] && screen_changed=true
    previous_screen="$screen"

    frame="$(tmuxc capture-pane -e -p -t "$sidebar")"
    node_line="$(printf '%s\n' "$frame" | awk '/node-codex/ { print; exit }')"
    if printf '%s' "$node_line" | grep -Fq '38;5;'; then
        gradient_seen=true
        break
    fi
    sleep 0.1
done

[ "$screen_changed" = true ] || fail_test 'node-based Codex pane did not redraw'
[ "$gradient_seen" = true ] || fail_test 'redrawing node-based Codex pane never received gradient ANSI output'

printf 'PASS: redrawing node-based Codex pane receives gradient ANSI output\n'
printf 'SUMMARY: pass=1 xfail=0 fail=0\n'
