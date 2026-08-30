#!/usr/bin/env bash
# Contract: a session whose AI stopped, and that the user has not visited, gets
# the awaiting mark; arriving clears it; new output takes it back to the wave;
# and @session-dock-awaiting hides it.
#
# The mark lives in column 2 of the row, the same column as the current-session
# star. They can never both apply: being on the session is exactly what clears
# awaiting. This test drives a real presenter and reads the rendered pane.
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
# The mark is a multi-byte glyph; the row must be sliced by character, not byte.
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-heartbeat.sh"
SOCKET="gradient-awaiting-$$"
TMP_DIR="$(mktemp -d)"
CONTROL="$TMP_DIR/control"
HEARTBEAT="$TMP_DIR/heartbeat"
DEBUG_FILE="$TMP_DIR/debug.log"
CLIENT_PID=""
cp "$(command -v bash)" "$TMP_DIR/codex"   # the AI-process probe matches on the command name

cleanup() { kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true; tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    printf -- '--- anchor sidebar ---\n' >&2
    tmuxc capture-pane -p -t "$SIDEBAR" 2>/dev/null | strip_ansi | head -8 >&2 || true
    [ -f "$DEBUG_FILE" ] && tail -n 40 "$DEBUG_FILE" >&2 || true
    exit 1
}

# The row for a session, as rendered, with escapes removed. Column 1 is the
# cursor, column 2 the session status mark.
row_for() {
    tmuxc capture-pane -p -t "$SIDEBAR" 2>/dev/null | strip_ansi |
        awk -v name="$1" '$0 ~ ("(^|[^[:alnum:]_-])" name "([^[:alnum:]_-]|$)") { print; exit }'
}
mark_for() { local row; row="$(row_for "$1")"; printf '%s' "${row:1:1}"; }

wait_for_mark() {   # wait_for_mark <session> <expected char> <what>
    local want="$2" deadline=$(( $(date +%s) + 20 )) got=''
    while [ "$(date +%s)" -lt "$deadline" ]; do
        got="$(mark_for "$1" || true)"
        [ "$got" = "$want" ] && return 0
        sleep 0.2
    done
    fail_test "$3: column 2 for '$1' was '${got:- }', expected '$want' (row: $(row_for "$1"))"
}

printf 'active\n' > "$CONTROL"
tmuxc new-session -d -s anchor -x 100 -y 30 'sleep 300' >/dev/null
tmuxc new-session -d -s worker -x 100 -y 30 "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL' '$HEARTBEAT'" >/dev/null
for session in anchor worker; do
    tmuxc set-option -q -t "=$session:" @dotfiles_sidebar_managed 1
done
# A short threshold keeps the test honest but quick; the clamp floor is 1000 ms.
tmuxc set-option -gq @session-dock-awaiting-after 1000
tmuxc set-option -gq @session-dock-gradient on

tmuxc split-window -d -h -b -l 35 -t '=anchor:' \
    "TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"

coproc ATTACHED { script -qefc "tmux -L '$SOCKET' attach-session -t anchor" --log-out "$TMP_DIR/output.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"

SIDEBAR=''
deadline=$(( $(date +%s) + 15 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    SIDEBAR="$(tmuxc list-panes -t '=anchor:' -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '!done && $2 == "dotfiles-session-sidebar" { print $1; done = 1 }')"
    [ -n "$SIDEBAR" ] && [ -n "$(row_for worker)" ] && break
    sleep 0.2
done
[ -n "$SIDEBAR" ] || fail_test 'the anchor sidebar never started'
[ -n "$(row_for worker)" ] || fail_test 'the worker row never appeared in the dock'
[ -s "$HEARTBEAT" ] || fail_test 'the fake AI never produced output'

# --- 1. a stop the user did not witness raises the mark ----------------------
# The client is on anchor throughout, so worker is never acknowledged.
printf 'waiting\n' > "$CONTROL"
wait_for_mark worker '●' 'a stop nobody visited'
printf 'PASS: a session that stopped while unattended is marked\n'

# --- 2. the header answers without scrolling ---------------------------------
header="$(tmuxc capture-pane -p -t "$SIDEBAR" | strip_ansi | sed -n 1p)"
case "$header" in
    *awaiting*) ;;
    *) fail_test "the header does not report the count: '$header'" ;;
esac
printf 'PASS: the header reports how many sessions are waiting\n'

# --- 3. arriving clears it, and leaving does not bring it back ---------------
# Read the mark from the anchor sidebar while the client is back on anchor: a
# presenter nobody is attached to has a stale idea of the current session.
client_tty="$(tmuxc list-clients -F '#{client_tty}' | sed -n 1p)"
tmuxc switch-client -c "$client_tty" -t '=worker:'
sleep 4                     # the observer publishes the client list once a second
tmuxc switch-client -c "$client_tty" -t '=anchor:'
wait_for_mark worker ' ' 'after visiting the session'
sleep 5                     # well past the 1 s threshold: a re-arm would show by now
[ "$(mark_for worker)" = '●' ] &&
    fail_test 'leaving the session re-raised a stop the user had already seen'
printf 'PASS: visiting clears the mark, and leaving does not bring it back\n'

# --- 4. new output takes it back to the wave ---------------------------------
printf 'active\n' > "$CONTROL"
deadline=$(( $(date +%s) + 15 )); moved=false
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(mark_for worker)" = ' ' ] && { moved=true; break; }
    sleep 0.2
done
[ "$moved" = true ] || fail_test "resumed output did not clear the mark (row: $(row_for worker))"
printf 'PASS: output resuming returns the row to the gradient\n'

# --- 5. the option hides it --------------------------------------------------
tmuxc set-option -gq @session-dock-awaiting off
printf 'waiting\n' > "$CONTROL"
sleep 5
[ "$(mark_for worker)" = '●' ] && fail_test '@session-dock-awaiting off still drew the mark'
header="$(tmuxc capture-pane -p -t "$SIDEBAR" | strip_ansi | sed -n 1p)"
case "$header" in
    *awaiting*) fail_test "the header still counts with the marker off: '$header'" ;;
esac
printf 'PASS: @session-dock-awaiting off hides the mark and the count\n'
printf 'SUMMARY: pass=5 xfail=0 fail=0\n'
