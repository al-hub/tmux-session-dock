#!/usr/bin/env bash
# Regression: pressing Enter must still switch sessions while a session is
# marked Awaiting.
#
# The dock's switch waits for the target presenter to have drawn a frame for
# the target session, and recognises that frame partly by its header. The
# header gained an "N awaiting" count, so any switch attempted while something
# was waiting never saw a frame it recognised and reported
# "sidebar content is not ready" - after the client had already moved.
#
# The waiting session must be one the switch does NOT target: landing on it
# acknowledges it, which clears the count and hides the defect.
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
FAKE_AI="$TEST_DIR/fake-ai-heartbeat.sh"
SOCKET="gradient-awaiting-switch-$$"
TMP_DIR="$(mktemp -d)"
CONTROL="$TMP_DIR/control"
HEARTBEAT="$TMP_DIR/heartbeat"
DEBUG_FILE="$TMP_DIR/debug.log"
TRACE_FILE="$TMP_DIR/trace.log"
CLIENT_PID=""
cp "$(command -v bash)" "$TMP_DIR/codex"

cleanup() { kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true; tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'; }
dock() { tmuxc capture-pane -p -t "$1" 2>/dev/null | strip_ansi; }
client_session() { tmuxc list-clients -F '#{client_session}' | sed -n 1p; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    printf -- '--- anchor dock ---\n' >&2; dock "$ANCHOR_SB" | sed -n '1,10p' >&2 || true
    printf -- '--- transition ---\n' >&2
    tmuxc show-environment -gh DOTFILES_SIDEBAR_TRANSITION 2>/dev/null >&2 || true
    printf -- '--- switch trace ---\n' >&2
    grep -a 'switch\.' "$TRACE_FILE" 2>/dev/null | tail -12 >&2 || true
    [ -f "$DEBUG_FILE" ] && tail -n 30 "$DEBUG_FILE" >&2 || true
    exit 1
}

sidebar_of() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '!done && $2=="dotfiles-session-sidebar" { print $1; done=1 }'
}
row_of() { dock "$1" | awk -v n="$2" '$0 ~ ("(^|[^[:alnum:]_-])" n "([^[:alnum:]_-]|$)") { print; exit }'; }
selected_row() { dock "$1" | awk '/^>/ { print; exit }'; }

printf 'active\n' > "$CONTROL"
tmuxc new-session -d -s anchor -x 100 -y 30 'sleep 300' >/dev/null
tmuxc new-session -d -s target -x 100 -y 30 'sleep 300' >/dev/null
tmuxc new-session -d -s worker -x 100 -y 30 "'$TMP_DIR/codex' '$FAKE_AI' '$CONTROL' '$HEARTBEAT'" >/dev/null
for s in anchor target worker; do
    tmuxc set-option -q -t "=$s:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 35 -t "=$s:" \
        "TMUX_SESSION_LAUNCHER_TRACE=1 TMUX_SESSION_LAUNCHER_TRACE_FILE='$TRACE_FILE' TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"
done
tmuxc set-option -gq @session-dock-awaiting-after 1000

coproc ATTACHED { script -qefc "tmux -L '$SOCKET' attach-session -t anchor" --log-out "$TMP_DIR/out.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"

ANCHOR_SB=''
deadline=$(( $(date +%s) + 45 ))   # three sessions and three presenters, on a loaded runner
while [ "$(date +%s)" -lt "$deadline" ]; do
    ANCHOR_SB="$(sidebar_of anchor)"
    [ -n "$ANCHOR_SB" ] && [ -n "$(sidebar_of target)" ] && [ -n "$(sidebar_of worker)" ] &&
        [ -n "$(row_of "$ANCHOR_SB" worker)" ] && [ -n "$(row_of "$ANCHOR_SB" target)" ] && break
    sleep 0.2
done
[ -n "$ANCHOR_SB" ] || fail_test 'the anchor dock never started'
[ -n "$(row_of "$ANCHOR_SB" worker)" ] || fail_test 'the worker row never appeared'
[ -n "$(row_of "$ANCHOR_SB" target)" ] || fail_test 'the target row never appeared'

# --- put a session into Awaiting so the header carries a count ---------------
printf 'waiting\n' > "$CONTROL"
deadline=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    case "$(dock "$ANCHOR_SB" | sed -n 1p)" in *awaiting*) break ;; esac
    sleep 0.2
done
header="$(dock "$ANCHOR_SB" | sed -n 1p)"
case "$header" in
    *awaiting*) ;;
    *) fail_test "no session reached Awaiting; header is '$header'" ;;
esac
printf 'setup: a session is Awaiting, anchor header reads "%s"\n' "$header"

# The readiness check reads the TARGET presenter's own frame, so the defect only
# shows once that dock is the one carrying the count.
TARGET_SB="$(sidebar_of target)"
deadline=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    case "$(dock "$TARGET_SB" | sed -n 1p)" in *awaiting*) break ;; esac
    sleep 0.2
done
target_header="$(dock "$TARGET_SB" | sed -n 1p)"
case "$target_header" in
    *awaiting*) ;;
    *) fail_test "the target dock never showed the count; header is '$target_header'" ;;
esac
printf 'setup: the target dock also reads "%s"\n' "$target_header"

# --- switch to a DIFFERENT session while worker keeps waiting ----------------
for _ in $(seq 1 12); do
    case "$(selected_row "$ANCHOR_SB")" in
        *target*) break ;;
    esac
    tmuxc send-keys -t "$ANCHOR_SB" Down
    sleep 0.4
done
case "$(selected_row "$ANCHOR_SB")" in
    *target*) ;;
    *) fail_test "could not put the cursor on target (selected: $(selected_row "$ANCHOR_SB"))" ;;
esac

tmuxc send-keys -t "$ANCHOR_SB" Enter
switched=false
deadline=$(( $(date +%s) + 25 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(client_session)" = target ] && { switched=true; break; }
    sleep 0.2
done
[ "$switched" = true ] || fail_test 'Enter did not move the client to target'

# The switch is only done when the dock stops reporting a failure. The client
# moving is not enough: the failure this guards against moved the client and
# then declared the switch unready.
# The client moving is not enough: the defect moved the client and then declared
# the switch unready. The dock's message is overwritten by the next render, so
# judge the outcome from the trace, which is not.
# The readiness wait backs off, so its verdict can take several seconds.
deadline=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -aqE 'switch\.(end mode=window-local session=target|abort)' "$TRACE_FILE" 2>/dev/null && break
    sleep 0.3
done
if grep -aq 'switch\.abort reason=sidebar-content-unready' "$TRACE_FILE" 2>/dev/null; then
    fail_test "the switch aborted as unready while a session was Awaiting: $(grep -a 'switch\.abort' "$TRACE_FILE" | tail -1)"
fi
grep -aq 'switch\.end mode=window-local session=target' "$TRACE_FILE" 2>/dev/null ||
    fail_test "the switch to target never completed: $(grep -a 'switch\.' "$TRACE_FILE" | tail -3 | tr '\n' '|')"
printf 'PASS: Enter switches sessions while a session is marked Awaiting\n'
printf 'SUMMARY: pass=1 xfail=0 fail=0\n'
