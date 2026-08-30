#!/usr/bin/env bash
# Contract: slot mutations are mutually exclusive across processes.
#
# 1. While another process holds the slot lock, subpane_hub_atomic_migrate
#    gives up (rc 1, traced) without joining anything.
# 2. Once the holder is gone the same call succeeds and leaves no lock behind.
# 3. A lock left by a dead process is reclaimed immediately.
set -euo pipefail
TEST_TMUX_CONF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd -P)/test-tmux.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOCKET="test-subpane-lock-$$"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-subpane-lock.XXXXXX")"
HOLDER_PID=""
export TMUX_SESSION_LAUNCHER_LOCK_ROOT="$RUN_DIR"
export TMUX_SESSION_LAUNCHER_TRACE=1
export TMUX_SESSION_LAUNCHER_TRACE_FILE="$RUN_DIR/trace.log"
export TMUX_SESSION_SIDEBAR_SUBPANE_LOCK_WAIT_SECONDS=1

cleanup()
{
    [ -n "$HOLDER_PID" ] && kill -9 "$HOLDER_PID" >/dev/null 2>&1 || true
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$RUN_DIR"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; tail -15 "$RUN_DIR/trace.log" >&2 2>/dev/null || true; exit 1; }

tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" new-session -d -s main -n work -x 120 -y 40 'sleep 60'
win_id="$(tmux -L "$SOCKET" display-message -p -t main '#{window_id}')"

export TMUX="$SOCKET"
source "$SCRIPT_DIR/scripts/lib/sidebar_domain.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_port_tmux.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_subpane_hub.sh"
source "$SCRIPT_DIR/scripts/tmux-session-launcher" --source-only 2>/dev/null || true

sidebar_port_split_sidebar_pane "$win_id" 30 'sleep 60'
launcher_pane="$(sidebar_window_pane "$win_id" || true)"
[ -n "$launcher_pane" ] || fail "launcher pane not created"
pane_count() { tmux -L "$SOCKET" list-panes -t "$win_id" | wc -l | tr -d ' '; }
before="$(pane_count)"

lock_dir="$(subpane_hub_lock_path)"
[ -n "$lock_dir" ] || fail "no lock path"

# --- 1. a live holder blocks the migrate -------------------------------------
mkdir "$lock_dir"
sleep 300 & HOLDER_PID=$!
printf '%s\n' "$HOLDER_PID" > "$lock_dir/pid"
if subpane_hub_atomic_migrate "$launcher_pane" 10 >/dev/null; then
    fail "migrate succeeded while another process held the slot lock"
fi
[ "$(pane_count)" = "$before" ] || fail "migrate joined panes without the lock"
grep -q "subpane.lock.busy" "$RUN_DIR/trace.log" || fail "lock wait not traced"
grep -q "subpane.migrate.skip reason=lock-busy" "$RUN_DIR/trace.log" || fail "migrate skip not traced"
[ -d "$lock_dir" ] || fail "waiter removed a live holder's lock"
printf 'PASS: migrate yields to a live lock holder\n'

# --- 2. holder gone: migrate proceeds and releases -----------------------------
kill -9 "$HOLDER_PID"; wait "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=""
# The holder died without cleaning up: the next caller must reclaim.
subpane_hub_atomic_migrate "$launcher_pane" 10 >/dev/null || fail "migrate failed after the holder died"
grep -q "subpane.lock.reclaim" "$RUN_DIR/trace.log" || fail "dead-owner reclaim not traced"
[ -n "$(sidebar_window_subpane "$win_id")" ] || fail "no subpane after migrate"
[ ! -d "$lock_dir" ] || fail "lock not released after migrate"
printf 'PASS: dead holder reclaimed, migrate completed, lock released\n'

# --- 3. reentrancy: swap parks and migrates under one lock --------------------
subpane_hub_swap_stack_position "$win_id" >/dev/null || fail "position swap failed"
[ ! -d "$lock_dir" ] || fail "lock not released after swap"
[ -n "$(sidebar_window_subpane "$win_id")" ] || fail "subpane lost across swap"
printf 'PASS: swap runs park+migrate under one reentrant lock\n'
