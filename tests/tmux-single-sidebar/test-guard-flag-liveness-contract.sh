#!/usr/bin/env bash
# Contract: hook-suppression flags (@dotfiles_sidebar_provisioning,
# @dotfiles_sidebar_restore_topology, @tmux_batch_busy) suppress only while
# their owner is alive and within the deadline.
#
# 1. Writer format "<owner_pid>:<deadline>"; legacy 1 honoured; 0 inactive.
# 2. Dead owner or expired deadline heals to 0 (traced).
# 3. --ensure-sidebar-window provisions through a flag whose owner died and
#    still honours a flag whose owner is alive.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
SOCKET="dotfiles-guard-liveness-$$"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-guard-liveness.XXXXXX")"
unset TMUX TMUX_PANE   # never inherit the outer server; the array below is local
TMUX=(tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf")

export TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET"
export TMUX_SESSION_LAUNCHER_LOCK_ROOT="$RUN_DIR"
export TMUX_SESSION_LAUNCHER_TRACE=1
export TMUX_SESSION_LAUNCHER_TRACE_FILE="$RUN_DIR/trace.log"

cleanup() { "${TMUX[@]}" kill-server >/dev/null 2>&1 || true; rm -rf "$RUN_DIR"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; printf -- '--- trace ---\n' >&2; tail -20 "$RUN_DIR/trace.log" >&2 2>/dev/null || true; exit 1; }
in_launcher() { bash -c "source '$LAUNCHER' --source-only 2>/dev/null || true; $1"; }
opt_get() { "${TMUX[@]}" show-option -gqv "$1" 2>/dev/null || true; }
opt_set() { "${TMUX[@]}" set-option -gq "$1" "$2"; }
sidebar_count() { "${TMUX[@]}" list-panes -t "$1" -F '#{pane_title}' | awk '$0 == "dotfiles-session-sidebar" { n++ } END { print n + 0 }'; }

"${TMUX[@]}" new-session -d -s main -x 120 -y 30 -c "$REPO_ROOT" 'sleep 300'
"${TMUX[@]}" new-session -d -s other -x 120 -y 30 -c "$REPO_ROOT" 'sleep 300'
bash -c 'exit 0' & dead_pid=$!; wait "$dead_pid" || true
now="$(date +%s)"
PROV=@dotfiles_sidebar_provisioning
TOPO=@dotfiles_sidebar_restore_topology
BATCH=@tmux_batch_busy

# --- 1. writer format ---------------------------------------------------------
in_launcher "sidebar_guard_flag_set $PROV 30; printf '%s\n' \"\$\$\" > '$RUN_DIR/writer.pid'"
value="$(opt_get $PROV)"
case "$value" in "$(cat "$RUN_DIR/writer.pid")":[0-9]*) ;; *) fail "flag value lacks owner pid/deadline: $value" ;; esac
[ "${value#*:}" -ge $((now + 25)) ] || fail "deadline too close: $value"
in_launcher "sidebar_guard_flag_clear $PROV"
[ "$(opt_get $PROV)" = 0 ] || fail "clear did not write 0"
printf 'PASS: guard flag carries owner pid and deadline\n'

# --- 2. reader liveness -------------------------------------------------------
opt_set $PROV 1
in_launcher 'sidebar_provisioning_active' || fail "legacy value 1 must be active"
opt_set $PROV "$$:$((now + 100))"
in_launcher 'sidebar_provisioning_active' || fail "alive owner within deadline must be active"
opt_set $PROV "$dead_pid:$((now + 100))"
if in_launcher 'sidebar_provisioning_active'; then fail "dead owner still active"; fi
[ "$(opt_get $PROV)" = 0 ] || fail "dead-owner flag not healed to 0: $(opt_get $PROV)"
grep -q "guard.stale-clear option=$PROV" "$RUN_DIR/trace.log" || fail "stale-clear not traced"
opt_set $PROV "$$:$((now - 1))"
if in_launcher 'sidebar_provisioning_active'; then fail "expired deadline still active"; fi
opt_set $TOPO 0; opt_set $BATCH "$dead_pid:$((now + 100))"
if in_launcher 'restore_topology_guard_active'; then fail "restore guard active with a dead batch owner"; fi
opt_set $BATCH "$$:$((now + 100))"
in_launcher 'restore_topology_guard_active' || fail "restore guard must be active with an alive batch owner"
opt_set $BATCH 0
printf 'PASS: dead or expired owners heal, alive owners suppress\n'

# --- 3. hook path: --ensure-sidebar-window ------------------------------------
main_win="$("${TMUX[@]}" display-message -p -t '=main:' '#{window_id}')"
other_win="$("${TMUX[@]}" display-message -p -t '=other:' '#{window_id}')"
opt_set $TOPO "$dead_pid:$((now + 100))"          # a restore whose presenter died
"${TMUX[@]}" run-shell "TMUX_SESSION_LAUNCHER_LOCK_ROOT=$RUN_DIR $LAUNCHER --ensure-sidebar-window $main_win 30"
for _ in $(seq 1 100); do [ "$(sidebar_count "$main_win")" = 1 ] && break; sleep 0.05; done
[ "$(sidebar_count "$main_win")" = 1 ] || fail "ensure-sidebar-window stayed suppressed by a flag whose owner is dead"
opt_set $TOPO "$$:$((now + 100))"                 # a restore that is really running
"${TMUX[@]}" run-shell "TMUX_SESSION_LAUNCHER_LOCK_ROOT=$RUN_DIR $LAUNCHER --ensure-sidebar-window $other_win 30"
sleep 0.5
[ "$(sidebar_count "$other_win")" = 0 ] || fail "ensure-sidebar-window ignored a live restore guard"
printf 'PASS: hooks resume after the guard owner dies and still honour a live guard\n'
