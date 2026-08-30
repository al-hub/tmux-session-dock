#!/usr/bin/env bash
# Contract: a transition lock lives exactly as long as its owner process.
#
# 1. A slow but alive switch (lock older than any age heuristic) is still
#    active for every other process: no stale-clear, lock dir intact.
# 2. A process that does not own the lock cannot release it.
# 3. When the owner dies (SIGKILL) the next reader reclaims the lock and
#    marks the transition stale-cleared, so switches are never blocked forever.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
SOCKET="dotfiles-transition-liveness-$$"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-transition-liveness.XXXXXX")"
unset TMUX TMUX_PANE   # never inherit the outer server; the array below is local
TMUX=(tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf")
HOLDER_PID=""

export TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET"
export TMUX_SESSION_LAUNCHER_LOCK_ROOT="$RUN_DIR"
export TMUX_SESSION_LAUNCHER_TRACE=1
export TMUX_SESSION_LAUNCHER_TRACE_FILE="$RUN_DIR/trace.log"

cleanup()
{
    [ -n "$HOLDER_PID" ] && kill -9 "$HOLDER_PID" >/dev/null 2>&1 || true
    [ -s "$RUN_DIR/holder.pid" ] && kill -9 "$(cat "$RUN_DIR/holder.pid")" >/dev/null 2>&1 || true
    "${TMUX[@]}" kill-server >/dev/null 2>&1 || true
    rm -rf "$RUN_DIR"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; printf -- '--- trace ---\n' >&2; tail -20 "$RUN_DIR/trace.log" >&2 2>/dev/null || true; exit 1; }

# Run a snippet in a fresh process with the launcher's functions loaded.
in_launcher()
{
    bash -c "source '$LAUNCHER' --source-only 2>/dev/null || true; $1"
}

"${TMUX[@]}" new-session -d -s main -x 120 -y 30 -c "$REPO_ROOT" 'sleep 300'

lock_dir="$(in_launcher 'transition_lock_path')"
[ -n "$lock_dir" ] || fail "could not resolve the transition lock path"

# --- 1. an alive holder keeps the lock no matter how old it is -------------
in_launcher 'transition_lock_acquire || exit 1
    transition_state_set "operation_id=op-hold;source=main;target=other;result=running"
    printf "%s\n" "$BASHPID" > "'"$RUN_DIR"'/holder.pid"
    exec sleep 300' &
HOLDER_PID=$!
for _ in $(seq 1 100); do
    [ -s "$RUN_DIR/holder.pid" ] && [ -d "$lock_dir" ] && break
    sleep 0.05
done
[ -d "$lock_dir" ] || fail "holder did not acquire the lock"
[ "$(cat "$lock_dir/pid")" = "$(cat "$RUN_DIR/holder.pid")" ] || fail "lock pid file does not name the holder"

# Age the lock far beyond any former lease timeout (2.5-3 s).
touch -d '-30 seconds' "$lock_dir" "$lock_dir/pid"

if ! in_launcher 'transition_is_active'; then
    fail "an alive holder's transition was reported inactive (age heuristic tore it down)"
fi
[ -d "$lock_dir" ] || fail "lock dir removed while the owner was alive"
state="$("${TMUX[@]}" show-environment -gh DOTFILES_SIDEBAR_TRANSITION | sed 's/^[^=]*=//')"
case "$state" in *"result=running"*) ;; *) fail "state changed while the owner was alive: $state" ;; esac
if grep -q "transition.stale-clear" "$RUN_DIR/trace.log" 2>/dev/null; then
    fail "stale-clear traced for an alive owner"
fi
printf 'PASS: alive holder survives a lock age of 30 s\n'

# --- 2. a foreign process cannot release the holder's lock -----------------
in_launcher "SIDEBAR_TRANSITION_LOCK_DIR='$lock_dir'; SIDEBAR_TRANSITION_LOCK_PID=999999; transition_lock_release"
[ -d "$lock_dir" ] || fail "a non-owner released the lock"
grep -q "transition.lock result=release-skipped" "$RUN_DIR/trace.log" || fail "release by a non-owner was not traced as skipped"
if in_launcher 'transition_lock_acquire'; then
    fail "a second switch acquired the lock while the holder was alive"
fi
printf 'PASS: only the owner can release the lock\n'

# --- 3. a dead holder is reclaimed by the next reader ----------------------
# The lock names the inner bash (now exec'd into sleep); the background job
# pid is only its parent subshell.  Kill the owner itself.
owner_pid="$(cat "$RUN_DIR/holder.pid")"
kill -9 "$owner_pid" 2>/dev/null || true
kill -9 "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
for _ in $(seq 1 50); do kill -0 "$owner_pid" 2>/dev/null || break; sleep 0.02; done
if in_launcher 'transition_is_active'; then
    fail "transition still active after its owner died"
fi
[ ! -d "$lock_dir" ] || fail "lock dir not reclaimed after the owner died"
state="$("${TMUX[@]}" show-environment -gh DOTFILES_SIDEBAR_TRANSITION | sed 's/^[^=]*=//')"
case "$state" in *"result=stale-cleared"*) ;; *) fail "state not stale-cleared after owner death: $state" ;; esac
grep -q "transition.stale-clear reason=owner-pid-dead" "$RUN_DIR/trace.log" || fail "dead-owner reclaim not traced"
in_launcher 'transition_lock_acquire && transition_lock_release' || fail "fresh switch could not acquire the reclaimed lock"
printf 'PASS: dead holder reclaimed, next switch proceeds\n'
