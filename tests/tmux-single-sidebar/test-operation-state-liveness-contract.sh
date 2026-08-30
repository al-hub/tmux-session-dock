#!/usr/bin/env bash
# Contract: the shared operation state (DOTFILES_SIDEBAR_OPERATION) blocks
# input and hooks only while its owner is alive and within its deadline.
#
# 1. Format: busy states carry owner pid + deadline; idle does not.
# 2. Readers: alive owner => busy; dead owner or expired deadline => idle
#    (self-healing, traced); legacy two-field values stay busy.
# 3. A live presenter accepts a key after the process that owned a
#    "restoring:" operation died, instead of answering "Busy" forever.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
SOCKET="dotfiles-operation-liveness-$$"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-operation-liveness.XXXXXX")"
unset TMUX TMUX_PANE   # never inherit the outer server; the array below is local
TMUX=(tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf")

export TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET"
export TMUX_SESSION_LAUNCHER_LOCK_ROOT="$RUN_DIR"
export TMUX_SESSION_LAUNCHER_TRACE=1
export TMUX_SESSION_LAUNCHER_TRACE_FILE="$RUN_DIR/trace.log"

cleanup()
{
    "${TMUX[@]}" kill-server >/dev/null 2>&1 || true
    rm -rf "$RUN_DIR"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; printf -- '--- trace ---\n' >&2; tail -20 "$RUN_DIR/trace.log" >&2 2>/dev/null || true; exit 1; }
in_launcher() { bash -c "source '$LAUNCHER' --source-only 2>/dev/null || true; $1"; }
set_state() { "${TMUX[@]}" set-environment -gh DOTFILES_SIDEBAR_OPERATION "$1"; }
get_state() { "${TMUX[@]}" show-environment -gh DOTFILES_SIDEBAR_OPERATION 2>/dev/null | sed 's/^[^=]*=//'; }

"${TMUX[@]}" new-session -d -s main -x 120 -y 30 -c "$REPO_ROOT" 'sleep 300'

# A pid that is certainly dead.
bash -c 'exit 0' & dead_pid=$!; wait "$dead_pid" || true
now="$(date +%s)"

# --- 1. writer format -------------------------------------------------------
in_launcher 'sidebar_operation_set restoring op-fmt; printf "%s\n" "$$" > "'"$RUN_DIR"'/writer.pid"'
state="$(get_state)"
writer_pid="$(cat "$RUN_DIR/writer.pid")"
case "$state" in
    "restoring:op-fmt:$writer_pid:"[0-9]*) ;;
    *) fail "busy state lacks owner pid/deadline: $state" ;;
esac
deadline="${state##*:}"
[ "$deadline" -ge $((now + 60)) ] || fail "deadline too close: $state"
in_launcher 'sidebar_operation_set idle op-fmt'
[ "$(get_state)" = "idle:op-fmt" ] || fail "idle state should stay two-field: $(get_state)"
printf 'PASS: busy state carries owner pid and deadline\n'

# --- 2. reader liveness -----------------------------------------------------
set_state "deleting:op-legacy"
in_launcher 'sidebar_operation_busy' || fail "legacy two-field busy state must still count as busy"

set_state "restoring:op-alive:$$:$((now + 100))"
in_launcher 'sidebar_operation_busy' || fail "alive owner within deadline must be busy"
in_launcher 'sidebar_operation_is_owner op-alive' || fail "owner match must accept the four-field value"

set_state "restoring:op-dead:$dead_pid:$((now + 100))"
if in_launcher 'sidebar_operation_busy'; then
    fail "dead owner still reported busy"
fi
[ "$(get_state)" = "idle:stale-cleared" ] || fail "dead owner state not cleared: $(get_state)"
grep -q "operation.stale-clear state=restoring:op-dead" "$RUN_DIR/trace.log" || fail "stale-clear not traced"

set_state "saving:op-expired:$$:$((now - 1))"
if in_launcher 'sidebar_operation_busy'; then
    fail "expired deadline still reported busy"
fi
printf 'PASS: dead or expired owners heal to idle, alive owners block\n'

# --- 3. a presenter recovers from an orphaned restoring: operation --------
"${TMUX[@]}" split-window -d -t '=main:' -h -b -l 35 \
    "TMUX_SESSION_LAUNCHER_LOCK_ROOT=$RUN_DIR TMUX_SESSION_LAUNCHER_TRACE=1 TMUX_SESSION_LAUNCHER_TRACE_FILE=$RUN_DIR/trace.log $LAUNCHER --sidebar"
sidebar_pane=""
for _ in $(seq 1 200); do
    sidebar_pane="$("${TMUX[@]}" list-panes -t '=main:' -F '#{pane_id}|#{pane_title}' | awk -F '|' '$2 == "dotfiles-session-sidebar" { print $1; exit }')"
    [ -n "$sidebar_pane" ] && [ "$("${TMUX[@]}" show-option -wqv -t '=main:' @dotfiles_sidebar_ready 2>/dev/null)" = 1 ] && break
    sleep 0.05
done
[ -n "$sidebar_pane" ] || fail "presenter did not start"
[ "$("${TMUX[@]}" show-option -wqv -t '=main:' @dotfiles_sidebar_ready 2>/dev/null)" = 1 ] || fail "presenter never became ready"

# The presenter that owned this restore died mid-way (simulated by a dead pid).
set_state "restoring:op-orphan:$dead_pid:$(( $(date +%s) + 100 ))"
: > "$RUN_DIR/keys.mark"
"${TMUX[@]}" send-keys -t "$sidebar_pane" j
accepted=0
for _ in $(seq 1 100); do
    if grep -q "input.rejected.*reason=operation-busy" "$RUN_DIR/trace.log" 2>/dev/null; then
        fail "presenter rejected input because of an orphaned operation: $(grep -m1 'input.rejected' "$RUN_DIR/trace.log")"
    fi
    if grep -q "operation.stale-clear state=restoring:op-orphan" "$RUN_DIR/trace.log" 2>/dev/null; then
        accepted=1; break
    fi
    sleep 0.05
done
[ "$accepted" = 1 ] || fail "presenter did not heal the orphaned operation after a key press"
[ "$(get_state)" = "idle:stale-cleared" ] || fail "orphaned operation not cleared by the presenter: $(get_state)"
printf 'PASS: presenter accepts input after the operation owner died\n'
