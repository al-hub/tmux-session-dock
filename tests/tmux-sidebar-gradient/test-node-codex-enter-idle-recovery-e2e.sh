#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="${TMUX_SESSION_LAUNCHER_UNDER_TEST:-$REPO_ROOT/scripts/tmux-session-launcher}"
FAKE_CODEX="$TEST_DIR/fake-codex-node.js"
FAKE_AI="$TEST_DIR/fake-ai.sh"
SOCKET="gradient-node-enter-idle-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_FILE="$TMP_DIR/other-ai.control"
DEBUG_FILE="$TMP_DIR/debug.log"

cleanup() {
    kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    wait "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
client_session() { tmuxc list-clients -F '#{session_name}' | head -n 1; }
sidebar_for() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }'
}
strip_ansi() { sed -E $'s/\x1B\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc list-clients -F '#{client_tty}|#{session_name}' >&2 || true
    tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_title}|#{pane_current_command}' >&2 || true
    for debug_file in "$TMP_DIR"/*.debug; do
        [ -f "$debug_file" ] || continue
        printf '%s\n' "== $(basename "$debug_file") ==" >&2
        tail -n 40 "$debug_file" >&2
    done
    exit 1
}
row_gradient_count() {
    local session="$1" pane="$2" frame plain line_index colors
    frame="$(tmuxc capture-pane -e -p -t "$pane")"
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
wait_for_gradient() {
    local session="$1" presenter="$2" deadline colors
    deadline=$(( $(date +%s) + 8 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        colors="$(row_gradient_count "$session" "$(sidebar_for "$presenter")")"
        [ "$colors" -ge 1 ] && return 0
        sleep 0.1
    done
    fail_test "$session did not receive gradient in $presenter presenter"
}

printf 'active\n' > "$CONTROL_FILE"
cp "$(command -v bash)" "$TMP_DIR/opencode"
tmuxc new-session -d -s node-codex -x 100 -y 30 "node '$FAKE_CODEX'"
tmuxc new-session -d -s other-ai -x 100 -y 30 \
    "'$TMP_DIR/opencode' '$FAKE_AI' '$CONTROL_FILE'"

for session in node-codex other-ai; do
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$TMP_DIR/$session.debug' TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar" >/dev/null
done

coproc ATTACHED {
    script -qefc "tmux -L '$SOCKET' attach-session -t node-codex" \
        --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1
}
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(sidebar_for node-codex)" ] && [ -n "$(sidebar_for other-ai)" ] && break
    sleep 0.1
done
[ -n "$(sidebar_for node-codex)" ] || fail_test 'node-codex sidebar did not start'
[ -n "$(sidebar_for other-ai)" ] || fail_test 'other-ai sidebar did not start'

wait_for_gradient node-codex node-codex

# Drive the same public Enter-based session transition used by the sidebar UI.
tmuxc select-pane -t "$(sidebar_for node-codex)"
tmuxc send-keys -t "$(sidebar_for node-codex)" Down Enter
deadline=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt "$deadline" ] && [ "$(client_session)" != other-ai ]; do sleep 0.1; done
[ "$(client_session)" = other-ai ] || fail_test 'Enter did not switch to other-ai'
wait_for_gradient other-ai other-ai

# An unchanged AI pane must lose its gradient after the ten-second idle grace.
printf 'waiting\n' > "$CONTROL_FILE"
sleep 12
idle_deadline=$(( $(date +%s) + 6 ))
while [ "$(date +%s)" -lt "$idle_deadline" ]; do
    idle_colors="$(row_gradient_count other-ai "$(sidebar_for other-ai)")"
    [ "$idle_colors" -eq 0 ] && break
    sleep 0.2
done
[ "${idle_colors:-1}" -eq 0 ] || fail_test "idle other-ai retained gradient ($idle_colors color cells)"

tmuxc select-pane -t "$(sidebar_for other-ai)"
tmuxc send-keys -t "$(sidebar_for other-ai)" Down Enter
deadline=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt "$deadline" ] && [ "$(client_session)" != node-codex ]; do sleep 0.1; done
[ "$(client_session)" = node-codex ] || fail_test 'Enter did not return to node-codex'
wait_for_gradient node-codex node-codex

printf 'PASS: node Codex recovers after Enter and idle AI gradient stops\n'
printf 'SUMMARY: pass=1 xfail=0 fail=0\n'
