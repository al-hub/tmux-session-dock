#!/usr/bin/env bash
# A presenter whose own session is a plain shell must still observe the AI
# activity of the other sessions: the user parks on a shell session and reads
# the sidebar to see which AI sessions are working.  Reproduces the field
# report "gradient works after the first Enter, then stays frozen after the
# next Enter" (the second Enter landed on a shell-only session).
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"  # never inherit ~/.tmux.conf

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="${TMUX_SESSION_LAUNCHER_UNDER_TEST:-$REPO_ROOT/scripts/tmux-session-launcher}"
FAKE_AI="$TEST_DIR/fake-ai.sh"
SOCKET="gradient-shell-presenter-$$"
TMP_DIR="$(mktemp -d)"
CONTROL_FILE="$TMP_DIR/ai.control"
GRACE_SECONDS=3

cleanup() {
    kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    wait "${CLIENT_PID:-}" >/dev/null 2>&1 || true
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR" 2>/dev/null || { sleep 0.5; rm -rf "$TMP_DIR" 2>/dev/null || true; }
}
trap cleanup EXIT INT TERM

tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
client_session() { tmuxc list-clients -F '#{session_name}' | sed -n 1p; }
sidebar_for() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '!done && $2 == "dotfiles-session-sidebar" { print $1; done = 1 }'
}
strip_ansi() { sed -E $'s/\x1B\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    tmuxc list-clients -F '#{client_tty}|#{session_name}' >&2 || true
    tmuxc list-panes -a -F '#{session_name}|#{pane_id}|#{pane_title}|#{pane_current_command}' >&2 || true
    for debug_file in "$TMP_DIR"/*.debug; do
        [ -f "$debug_file" ] || continue
        printf '%s\n' "== $(basename "$debug_file") ==" >&2
        grep -E 'ai-observer|state session=ai' "$debug_file" | tail -n 20 >&2
    done
    exit 1
}
row_raw() {
    local session="$1" pane="$2" frame plain line_index
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
    printf '\n'
}
row_gradient_count() { { grep -o '38;5;' <<< "$(row_raw "$1" "$2")" || true; } | wc -l | tr -d ' '; }
# wait_for_gradient <row session> <presenter session> <present|absent> <seconds> <message>
wait_for_gradient() {
    local session="$1" presenter="$2" expected="$3" seconds="$4" message="$5" deadline colors=-1
    deadline=$(( $(date +%s) + seconds ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        colors="$(row_gradient_count "$session" "$(sidebar_for "$presenter")")"
        case "$expected" in
            present) [ "$colors" -ge 1 ] && return 0 ;;
            absent) [ "$colors" -eq 0 ] && return 0 ;;
        esac
        sleep 0.2
    done
    fail_test "$message (gradient cells=$colors)"
}

cp "$(command -v bash)" "$TMP_DIR/codex"
printf 'active\n' > "$CONTROL_FILE"
tmuxc new-session -d -s ai1 -x 120 -y 30 "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL_FILE'" >/dev/null
tmuxc new-session -d -s shell1 -x 120 -y 30 >/dev/null
for session in ai1 shell1; do
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$session:" \
        "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$TMP_DIR/$session.debug' TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 TMUX_SESSION_SIDEBAR_BUSY_SECONDS=$GRACE_SECONDS '$LAUNCHER' --sidebar" >/dev/null
done

coproc ATTACHED {
    script -qefc "tmux -L '$SOCKET' attach-session -t ai1" \
        --log-in "$TMP_DIR/input.log" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1
}
CLIENT_PID="$ATTACHED_PID"

deadline=$(( $(date +%s) + 12 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(sidebar_for ai1)" ] && [ -n "$(sidebar_for shell1)" ] && [ "$(client_session)" = ai1 ] && break
    sleep 0.1
done
[ -n "$(sidebar_for ai1)" ] || fail_test 'ai1 sidebar did not start'
[ -n "$(sidebar_for shell1)" ] || fail_test 'shell1 sidebar did not start'
[ "$(client_session)" = ai1 ] || fail_test 'client did not attach to ai1'

wait_for_gradient ai1 ai1 present 10 'working ai1 row has no gradient in its own presenter'

# Enter onto the shell-only session.
tmuxc select-pane -t "$(sidebar_for ai1)"
tmuxc send-keys -t "$(sidebar_for ai1)" Down Enter
deadline=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt "$deadline" ] && [ "$(client_session)" != shell1 ]; do sleep 0.1; done
[ "$(client_session)" = shell1 ] || fail_test 'Enter did not switch to shell1'
wait_for_gradient ai1 shell1 present 10 'shell1 presenter shows no gradient for the working ai1 row after Enter'

# The AI stops: the shell presenter must drop the gradient after the grace.
printf 'waiting\n' > "$CONTROL_FILE"
wait_for_gradient ai1 shell1 absent $((GRACE_SECONDS + 10)) 'shell1 presenter kept the ai1 gradient after the AI went idle'
printf 'PASS: shell-only presenter drops the gradient when the other session goes idle\n'

# ... and light it again when work resumes.
printf 'active\n' > "$CONTROL_FILE"
wait_for_gradient ai1 shell1 present 10 'shell1 presenter did not light the ai1 row when work resumed'
printf 'PASS: shell-only presenter lights the gradient when the other session resumes\n'

# Discovery: with the only AI gone, nothing is tracked anywhere.  A new AI CLI
# started later in a third session must still be found by the shell presenter
# (periodic rescan every TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS, 5 s).
printf 'exit\n' > "$CONTROL_FILE"
wait_for_gradient ai1 shell1 absent $((GRACE_SECONDS + 10)) 'shell1 presenter kept the ai1 gradient after the AI exited'
LATER_CONTROL="$TMP_DIR/later.control"
printf 'active\n' > "$LATER_CONTROL"
later_shell="$(tmuxc new-session -d -P -F '#{pane_id}' -s later -x 120 -y 30)"
tmuxc set-option -q -t "=later:" @dotfiles_sidebar_managed 1
# The presenters provision a sidebar into the new session on their own and may
# make it the active pane, so address the shell pane explicitly.
sleep 1
tmuxc send-keys -t "$later_shell" "exec '$TMP_DIR/codex' '$FAKE_AI' '$LATER_CONTROL'" Enter
wait_for_gradient later shell1 present 20 'shell1 presenter never discovered the AI started later in another session'
printf 'PASS: shell-only presenter discovers an AI CLI started later in another session\n'
printf 'SUMMARY: pass=3 xfail=0 fail=0\n'
