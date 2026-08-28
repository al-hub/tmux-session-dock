#!/usr/bin/env bash
set -euo pipefail
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai.sh"
SOCKET="gradient-test-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_FILE="$TMP_DIR/control"
DEBUG_FILE="$TMP_DIR/debug.log"

cleanup()
{
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

wait_for_sidebar_gradient()
{
    expected="$1"
    attempts=0
    while [ "$attempts" -lt 80 ]; do
        frame="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sidebar_pane" 2>/dev/null || true)"
        if [ "$expected" = present ] && grep -Eq '38;5;(255|254|252|250|248|246)m' <<< "$frame"; then
            return 0
        fi
        if [ "$expected" = absent ] && ! grep -Eq '38;5;(255|254|252|250|248|246)m' <<< "$frame"; then
            return 0
        fi
        sleep 0.1
        attempts=$((attempts + 1))
    done
    printf 'sidebar gradient was not %s\n' "$expected" >&2
    tmux -L "$SOCKET" capture-pane -e -p -t "$sidebar_pane" >&2 || true
    return 1
}

printf 'active\n' > "$CONTROL_FILE"
cp "$(command -v bash)" "$TMP_DIR/codex"
fake_command="\"$TMP_DIR/codex\" \"$FAKE_AI\" \"$CONTROL_FILE\""
ai_pane="$(tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" new-session -d -P -F '#{pane_id}' -s gradient -x 100 -y 30 "$fake_command")"

sidebar_command="env TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE=\"$DEBUG_FILE\" TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_ANIMATE_DETACHED=true TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 \"$LAUNCHER\" --sidebar"
sidebar_pane="$(tmux -L "$SOCKET" split-window -d -P -F '#{pane_id}' -t "$ai_pane" -h -b -l 35 "$sidebar_command")"
tmux -L "$SOCKET" select-pane -t "$ai_pane" -T fake-ai
tmux -L "$SOCKET" select-pane -t "$sidebar_pane" -T dotfiles-session-sidebar
tmux -L "$SOCKET" select-pane -t "$sidebar_pane"

wait_for_sidebar_gradient present
printf 'PASS: fake AI output starts gradient\n'

printf 'waiting\n' > "$CONTROL_FILE"
wait_for_sidebar_gradient absent
printf 'PASS: stable fake AI output stops gradient\n'

printf 'active\n' > "$CONTROL_FILE"
wait_for_sidebar_gradient present
printf 'PASS: resumed fake AI output restarts gradient\n'

printf 'exit\n' > "$CONTROL_FILE"
wait_for_sidebar_gradient absent
printf 'PASS: fake AI process exit clears gradient\n'

printf 'SUMMARY: pass=4 xfail=0 fail=0\n'
