#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-heartbeat-lines.sh"
SOCKET="gradient-working-idle-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_DIR="$TMP_DIR/control"
HEARTBEAT_DIR="$TMP_DIR/heartbeat"
DEBUG_FILE="$TMP_DIR/debug.log"
mkdir -p "$CONTROL_DIR" "$HEARTBEAT_DIR"
cp "$(command -v bash)" "$TMP_DIR/codex"

cleanup() { kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true; tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
tmuxc() { tmux -L "$SOCKET" "$@"; }
sidebar_for() { tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' | awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'; }
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() { printf 'FAIL: %s\n' "$1" >&2; [ -f "$DEBUG_FILE" ] && tail -n 60 "$DEBUG_FILE" >&2 || true; exit 1; }

set_state() { printf '%s\n' "$2" > "$CONTROL_DIR/$1"; }

row_gradient_count()
{
    local session="$1" pane="$2" frame plain line_index=-1 colors
    frame="$(tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
    plain="$(strip_ansi <<< "$frame")"
    mapfile -t raw_lines <<< "$frame"
    mapfile -t plain_lines <<< "$plain"
    for line_index in "${!plain_lines[@]}"; do
        if [[ "${plain_lines[$line_index]}" == *"$session"* ]]; then
            colors="$(grep -o '38;5;' <<< "${raw_lines[$line_index]}" | wc -l | tr -d ' ' || true)"
            printf '%s\n' "$colors"
            return 0
        fi
    done
    printf '%s\n' '-1'
}

for session in state1 state2 state3; do
    printf 'active\n' > "$CONTROL_DIR/$session"
    tmuxc new-session -d -s "$session" -x 100 -y 30 \
        "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL_DIR/$session' '$HEARTBEAT_DIR/$session'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"
done

coproc ATTACHED { script -qefc "tmux -L '$SOCKET' attach-session -t state1" --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -s "$HEARTBEAT_DIR/state1" ] && [ -s "$HEARTBEAT_DIR/state2" ] && [ -s "$HEARTBEAT_DIR/state3" ] && break
    sleep 0.1
done

sidebar="$(sidebar_for state1)"
deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sidebar="$(sidebar_for state1)"
    [ -n "$sidebar" ] && tmuxc capture-pane -p -t "$sidebar" 2>/dev/null | grep -Fq sessions && break
    sleep 0.1
done
[ -n "$sidebar" ] || fail_test 'state1 sidebar did not start'

set_state state2 waiting
set_state state3 active
sleep 3.0

state2_before="$(cat "$HEARTBEAT_DIR/state2")"
state3_before="$(cat "$HEARTBEAT_DIR/state3")"
sleep 0.4
state2_after="$(cat "$HEARTBEAT_DIR/state2")"
state3_after="$(cat "$HEARTBEAT_DIR/state3")"
[ "$state2_before" = "$state2_after" ] || fail_test 'idle state2 heartbeat continued'
[ "$state3_before" != "$state3_after" ] || fail_test 'working state3 heartbeat stopped'

state2_colors="$(row_gradient_count state2 "$sidebar")"
state3_colors="$(row_gradient_count state3 "$sidebar")"
[ "$state2_colors" -eq 0 ] || fail_test "idle state2 still has gradient ($state2_colors color cells)"
[ "$state3_colors" -ge 1 ] || fail_test 'working state3 has no gradient'

set_state state2 active
set_state state3 waiting
sleep 3.0

state2_before="$(cat "$HEARTBEAT_DIR/state2")"
state3_before="$(cat "$HEARTBEAT_DIR/state3")"
sleep 0.4
state2_after="$(cat "$HEARTBEAT_DIR/state2")"
state3_after="$(cat "$HEARTBEAT_DIR/state3")"
[ "$state2_before" != "$state2_after" ] || fail_test 'state2 heartbeat did not resume'
[ "$state3_before" = "$state3_after" ] || fail_test 'idle state3 heartbeat continued'

state2_colors="$(row_gradient_count state2 "$sidebar")"
state3_colors="$(row_gradient_count state3 "$sidebar")"
[ "$state2_colors" -ge 1 ] || fail_test 'working state2 has no gradient after state transition'
[ "$state3_colors" -eq 0 ] || fail_test "idle state3 still has gradient ($state3_colors color cells)"

printf 'PASS: idle session heartbeat stops while working session heartbeat continues\n'
printf 'PASS: idle session gradient stops while working session gradient continues\n'
printf 'PASS: independent working/idle gradient state transitions remain isolated\n'
printf 'SUMMARY: pass=3 xfail=0 fail=0\n'
