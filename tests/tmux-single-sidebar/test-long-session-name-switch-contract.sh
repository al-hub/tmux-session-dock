#!/usr/bin/env bash
# Regression: Enter must switch to a session whose name is wider than the row's
# name cell.
#
# The dock fits a name into a 19-column cell of a 34-column dock and draws the
# rest as an ellipsis, while the switch confirms the target presenter has
# settled by reading that row back as text. Demanding the whole name there made
# every session with a long name unreachable: the client moved and the switch
# then aborted with "sidebar content is not ready" - the same shape as the
# awaiting-header defect, triggered by the name instead of the header.
set -euo pipefail
export TERM=xterm-256color  # attached clients must not inherit a dumb TERM (CI runners)
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
SOCKET="long-name-switch-$$"
TMP_DIR="$(mktemp -d)"
DEBUG_FILE="$TMP_DIR/debug.log"
TRACE_FILE="$TMP_DIR/trace.log"
CLIENT_PID=""

# Wider than the 19-column name cell of a 34-column dock, so the row can only
# ever show a prefix of it.
LONG=a-very-long-session-name-indeed
PREFIX=''   # what the row actually shows; read back from the dock below
ELLIPSIS=$'\u2026'
# The dock remembers its width in the user's state directory; keep this test off
# it, or the row is as wide as whatever the developer last dragged it to.
export TMUX_SESSION_SIDEBAR_WIDTH_STATE_FILE="$TMP_DIR/width"

cleanup() { kill "${CLIENT_PID:-}" >/dev/null 2>&1 || true; tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
tmuxc() { tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" "$@"; }
dock() { tmuxc capture-pane -p -t "$1" 2>/dev/null; }
client_session() { tmuxc list-clients -F '#{client_session}' | sed -n 1p; }
sidebar_of() {
    tmuxc list-panes -t "=$1:" -F '#{pane_id}|#{pane_title}' |
        awk -F'|' '!done && $2=="dotfiles-session-sidebar" { print $1; done=1 }'
}
selected_row() { dock "$1" | awk '/^>/ { print; exit }'; }
fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    printf -- '--- anchor dock ---\n' >&2; dock "${ANCHOR_SB:-}" | sed -n '1,10p' >&2 || true
    printf -- '--- switch trace ---\n' >&2
    grep -a 'switch\.' "$TRACE_FILE" 2>/dev/null | tail -12 >&2 || true
    [ -f "$DEBUG_FILE" ] && tail -n 30 "$DEBUG_FILE" >&2 || true
    exit 1
}

tmuxc new-session -d -s anchor -x 100 -y 30 'sleep 300' >/dev/null
tmuxc set-option -gq '@dotfiles-session-sidebar-width' 34
tmuxc new-session -d -s "$LONG" -x 100 -y 30 'sleep 300' >/dev/null
for s in anchor "$LONG"; do
    tmuxc set-option -q -t "=$s:" @dotfiles_sidebar_managed 1
    tmuxc split-window -d -h -b -l 34 -t "=$s:" \
        "TMUX_SESSION_SIDEBAR_WIDTH_STATE_FILE='$TMP_DIR/width' TMUX_SESSION_LAUNCHER_TRACE=1 TMUX_SESSION_LAUNCHER_TRACE_FILE='$TRACE_FILE' TMUX_SESSION_LAUNCHER_DEBUG=1 TMUX_SESSION_LAUNCHER_DEBUG_FILE='$DEBUG_FILE' TMUX_SESSION_SIDEBAR_STATE_REFRESH_SECONDS=1 TMUX_SESSION_SIDEBAR_POLL_TIMEOUT=0.05 '$LAUNCHER' --sidebar"
done

coproc ATTACHED { script -qefc "tmux -L '$SOCKET' attach-session -t anchor" --log-out "$TMP_DIR/out.log" >/dev/null 2>&1; }
CLIENT_PID="$ATTACHED_PID"

# The name cell of the elided row, as the dock actually drew it.
elided_cell() {
    dock "$1" | awk -v e="$ELLIPSIS" -F "$ELLIPSIS" 'index($0, e) { sub(/^[^[:alnum:]]*/, "", $1); print $1; exit }'
}

ANCHOR_SB=''
deadline=$(( $(date +%s) + 45 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    ANCHOR_SB="$(sidebar_of anchor)"
    [ -n "$ANCHOR_SB" ] && [ -n "$(sidebar_of "$LONG")" ] &&
        [ -n "$(elided_cell "$ANCHOR_SB")" ] && break
    sleep 0.2
done
[ -n "$ANCHOR_SB" ] || fail_test 'the anchor dock never started'
PREFIX="$(elided_cell "$ANCHOR_SB")"
[ -n "$PREFIX" ] || fail_test 'the long-named row never appeared'

# The row must actually be elided, and elided from THIS name - otherwise the
# test proves nothing.
dock "$ANCHOR_SB" | grep -Fq "$LONG" &&
    fail_test "the dock drew the whole name, so the name cell is not narrower than '$LONG'"
[ "${LONG#"$PREFIX"}" != "$LONG" ] ||
    fail_test "the elided row shows '$PREFIX', which is not a prefix of '$LONG'"
printf 'setup: the row shows "%s%s"\n' "$PREFIX" "$ELLIPSIS"

for _ in $(seq 1 12); do
    case "$(selected_row "$ANCHOR_SB")" in *"$PREFIX"*) break ;; esac
    tmuxc send-keys -t "$ANCHOR_SB" Down
    sleep 0.4
done
case "$(selected_row "$ANCHOR_SB")" in
    *"$PREFIX"*) ;;
    *) fail_test "could not put the cursor on the long-named row (selected: $(selected_row "$ANCHOR_SB"))" ;;
esac

tmuxc send-keys -t "$ANCHOR_SB" Enter
switched=false
deadline=$(( $(date +%s) + 25 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(client_session)" = "$LONG" ] && { switched=true; break; }
    sleep 0.2
done
[ "$switched" = true ] || fail_test "Enter did not move the client to '$LONG'"

# The client moving is not the whole switch: the defect moved it and then
# declared the target unready. The dock's message is overwritten by the next
# render, so judge from the trace, which is not.
deadline=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -aqE "switch\.(end mode=window-local session=$LONG|abort)" "$TRACE_FILE" 2>/dev/null && break
    sleep 0.3
done
if grep -aq 'switch\.abort reason=sidebar-content-unready' "$TRACE_FILE" 2>/dev/null; then
    fail_test "the switch aborted as unready for a long session name: $(grep -a 'switch\.abort' "$TRACE_FILE" | tail -1)"
fi
grep -aq "switch\.end mode=window-local session=$LONG" "$TRACE_FILE" 2>/dev/null ||
    fail_test "the switch to '$LONG' never completed: $(grep -a 'switch\.' "$TRACE_FILE" | tail -3 | tr '\n' '|')"
printf 'PASS: Enter switches to a session whose name is wider than the row\n'
