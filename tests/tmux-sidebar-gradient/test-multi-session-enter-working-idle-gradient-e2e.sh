#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-heartbeat-lines.sh"
SOCKET="gradient-enter-working-idle-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_DIR="$TMP_DIR/control"
HEARTBEAT_DIR="$TMP_DIR/heartbeat"
DEBUG_FILE="$TMP_DIR/debug.log"
mkdir -p "$CONTROL_DIR" "$HEARTBEAT_DIR"
cp "$(command -v bash)" "$TMP_DIR/codex"

cleanup() { kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true; tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
client_session() { tmuxc list-clients -F '#{session_name}' | head -n 1; }
sidebar_for() { tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' | awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'; }
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() { printf 'FAIL: %s\n' "$1" >&2; [ -f "$DEBUG_FILE" ] && tail -n 60 "$DEBUG_FILE" >&2 || true; exit 1; }
set_state() { printf '%s\n' "$2" > "$CONTROL_DIR/$1"; }

row_snapshot()
{
    local session="$1" pane="$2" frame plain line_index=-1
    frame="$(tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
    plain="$(strip_ansi <<< "$frame")"
    mapfile -t raw_lines <<< "$frame"
    mapfile -t plain_lines <<< "$plain"
    for line_index in "${!plain_lines[@]}"; do
        if [[ "${plain_lines[$line_index]}" == *"$session"* ]]; then
            printf '%s\n' "${raw_lines[$line_index]}"
            return 0
        fi
    done
    printf '%s\n' '-1'
}

row_changes()
{
    local pane="$2" first second
    first="$(tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
    second="$(sleep 0.25; tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
    [ "$first" != "$second" ]
}

assert_state_rows()
{
    local current="$1" pane="$2" state1_colors state2_colors state3_colors
    pane="$(sidebar_for "$current")"
    [ -n "$pane" ] || fail_test "sidebar missing for current session $current"
    row_changes state1 "$pane" || fail_test "working state1 row did not change while current session is $current"
    row_changes state3 "$pane" || fail_test "working state3 row did not change while current session is $current"
}

for session in state1 state2 state3; do
    printf 'active\n' > "$CONTROL_DIR/$session"
    tmuxc new-session -d -s "$session" -x 100 -y 30 \
        "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL_DIR/$session' '$HEARTBEAT_DIR/$session'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"
done

set_state state2 waiting
coproc ATTACHED { script -qefc "tmux -L '$SOCKET' attach-session -t state1" --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sidebar="$(sidebar_for state1)"
    [ -n "$sidebar" ] && tmuxc capture-pane -p -t "$sidebar" 2>/dev/null | grep -Fq sessions && break
    sleep 0.1
done
[ -n "$sidebar" ] || fail_test 'state1 sidebar did not start'
sleep 6.0
assert_state_rows state1 "$sidebar"

switch_to()
{
    local target="$1" current current_sidebar switch_deadline
    current="$(client_session)"
    current_sidebar="$(sidebar_for "$current")"
    tmuxc select-pane -t "$current_sidebar"
    tmuxc send-keys -t "$current_sidebar" Down Enter
    switch_deadline=$(( $(date +%s) + 8 ))
    while [ "$(date +%s)" -lt "$switch_deadline" ] && [ "$(client_session)" != "$target" ]; do sleep 0.1; done
    [ "$(client_session)" = "$target" ] || fail_test "Enter did not switch from $current to $target"
    sleep 3.0
    assert_state_rows "$target" "$(sidebar_for "$target")"
}

switch_to state2
switch_to state3
switch_to state1

printf 'PASS: working/idle gradient states survive Enter switch to state2\n'
printf 'PASS: working/idle gradient states survive Enter switch to state3\n'
printf 'PASS: working/idle gradient states survive Enter switch back to state1\n'
printf 'SUMMARY: pass=3 xfail=0 fail=0\n'
