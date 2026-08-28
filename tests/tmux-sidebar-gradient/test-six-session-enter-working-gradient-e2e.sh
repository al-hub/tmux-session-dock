#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-heartbeat-lines.sh"
SOCKET="gradient-six-enter-working-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_DIR="$TMP_DIR/control"
HEARTBEAT_DIR="$TMP_DIR/heartbeat"
DEBUG_FILE="$TMP_DIR/debug.log"
mkdir -p "$CONTROL_DIR" "$HEARTBEAT_DIR"
cp "$(command -v bash)" "$TMP_DIR/codex"

# Fake AI processes may still write heartbeats for a moment after kill-server; retry the cleanup.
cleanup() { kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true; tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP_DIR" 2>/dev/null || { sleep 0.5; rm -rf "$TMP_DIR" 2>/dev/null || true; }; }
trap cleanup EXIT INT TERM
tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
client_session() { tmuxc list-clients -F '#{session_name}' | head -n 1; }
sidebar_for() { tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' | awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'; }
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() { printf 'FAIL: %s\n' "$1" >&2; [ -f "$DEBUG_FILE" ] && tail -n 60 "$DEBUG_FILE" >&2 || true; exit 1; }

assert_all_rows_gradient()
{
    local current="$1" pane frame plain line_index session colors
    pane="$(sidebar_for "$current")"
    [ -n "$pane" ] || fail_test "sidebar missing for $current"
    frame="$(tmuxc capture-pane -e -p -t "$pane" 2>/dev/null || true)"
    plain="$(strip_ansi <<< "$frame")"
    mapfile -t raw_lines <<< "$frame"
    mapfile -t plain_lines <<< "$plain"
    for session in "${sessions[@]}"; do
        line_index=-1
        for line_index in "${!plain_lines[@]}"; do
            [[ "${plain_lines[$line_index]}" == *"$session"* ]] && break
        done
        [ "$line_index" -ge 0 ] || fail_test "$session row missing after Enter switch to $current"
        colors="$(grep -o '38;5;' <<< "${raw_lines[$line_index]}" | wc -l | tr -d ' ' || true)"
        [ "$colors" -ge 1 ] || fail_test "$session lost gradient after Enter switch to $current"
    done
}

sessions=(sw1 sw2 sw3 sw4 sw5 sw6)
for session in "${sessions[@]}"; do
    printf 'active\n' > "$CONTROL_DIR/$session"
    tmuxc new-session -d -s "$session" -x 100 -y 30 \
        "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL_DIR/$session' '$HEARTBEAT_DIR/$session'" >/dev/null
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"
done

coproc ATTACHED { script -qefc "tmux -L '$SOCKET' attach-session -t sw1" --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sidebar="$(sidebar_for sw1)"
    [ -n "$sidebar" ] && tmuxc capture-pane -p -t "$sidebar" 2>/dev/null | grep -Fq sessions && break
    sleep 0.1
done
[ -n "$sidebar" ] || fail_test 'sw1 sidebar did not start'
sleep 3.0
assert_all_rows_gradient sw1

for index in 1 2 3 4 5; do
    current="${sessions[$((index - 1))]}"
    target="${sessions[$index]}"
    before_heartbeat="$(cat "$HEARTBEAT_DIR/$current")"
    current_sidebar="$(sidebar_for "$current")"
    tmuxc select-pane -t "$current_sidebar"
    tmuxc send-keys -t "$current_sidebar" Down Enter
    switch_deadline=$(( $(date +%s) + 8 ))
    while [ "$(date +%s)" -lt "$switch_deadline" ] && [ "$(client_session)" != "$target" ]; do sleep 0.1; done
    [ "$(client_session)" = "$target" ] || fail_test "Enter did not switch from $current to $target"
    sleep 2.5
    after_heartbeat="$(cat "$HEARTBEAT_DIR/$current")"
    [ "$before_heartbeat" != "$after_heartbeat" ] || fail_test "$current stopped working after switching to $target"
    assert_all_rows_gradient "$target"
    printf 'PASS: all six working gradients survive Enter switch to %s\n' "$target"
done

printf 'SUMMARY: pass=6 xfail=0 fail=0\n'
