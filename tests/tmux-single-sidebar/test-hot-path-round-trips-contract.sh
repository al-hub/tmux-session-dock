#!/usr/bin/env bash
# Contract: the hot paths ask the tmux server once for what they need.
#
# 1. sidebar_window_probe answers pane identity, liveness, width, readiness,
#    managed flag and pane count from a single list-panes.
# 2. sidebar_env_fetch_all returns every hidden flag plus an optional
#    pane/window format from a single show-environment round trip, and the
#    format value is exact (no stray brace from a shell default).
# 3. sidebar_env_set_many writes several flags in one round trip.
# 4. save_sidebar_layout snapshots a window with 2 reads and 1 write, and
#    stores the same values the per-field helpers would have.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
SOCKET="dotfiles-round-trips-$$"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-round-trips.XXXXXX")"
unset TMUX TMUX_PANE   # never inherit the outer server; the array below is local
TMUX=(tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf")

export TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET"
export TMUX_SESSION_LAUNCHER_LOCK_ROOT="$RUN_DIR"
export PATH="$RUN_DIR/bin:$PATH"
export TMUX_ROUND_TRIP_LOG="$RUN_DIR/calls.log"

cleanup() { "${TMUX[@]}" kill-server >/dev/null 2>&1 || true; rm -rf "$RUN_DIR"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# A counting shim in front of the real tmux binary: every exec is one round trip.
mkdir -p "$RUN_DIR/bin"
real_tmux="$(command -v tmux)"
cat > "$RUN_DIR/bin/tmux" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "\$TMUX_ROUND_TRIP_LOG"
exec "$real_tmux" "\$@"
SHIM
chmod +x "$RUN_DIR/bin/tmux"
: > "$TMUX_ROUND_TRIP_LOG"
calls() { wc -l < "$TMUX_ROUND_TRIP_LOG" | tr -d ' '; }
reset_calls() { : > "$TMUX_ROUND_TRIP_LOG"; }

"${TMUX[@]}" new-session -d -s main -n work -x 120 -y 40 -c "$REPO_ROOT" 'sleep 300'
win="$("${TMUX[@]}" display-message -p -t '=main:' '#{window_id}')"
"${TMUX[@]}" split-window -d -t "$win" 'sleep 300'
sb="$("${TMUX[@]}" list-panes -t "$win" -F '#{pane_id}' | head -1)"
"${TMUX[@]}" select-pane -t "$sb" -T dotfiles-session-sidebar
"${TMUX[@]}" set-option -wq -t "$win" @dotfiles_sidebar_ready 1
"${TMUX[@]}" set-option -q -t '=main:' @dotfiles_sidebar_managed 1

source "$LAUNCHER" --source-only 2>/dev/null || true

# --- 1. window probe -------------------------------------------------------
reset_calls
sidebar_window_probe "$win" || fail "probe failed on an existing window"
[ "$(calls)" = 1 ] || fail "window probe took $(calls) round trips, expected 1: $(cat "$TMUX_ROUND_TRIP_LOG")"
[ "$probe_pane" = "$sb" ] || fail "probe pane $probe_pane, expected $sb"
[ "$probe_dead" = 0 ] || fail "probe reported a dead pane"
[ -n "$probe_pid" ] || fail "probe returned no pid"
[ "$probe_ready" = 1 ] || fail "probe ready=$probe_ready, expected 1"
[ "$probe_managed" = 1 ] || fail "probe managed=$probe_managed, expected 1"
[ "$probe_pane_count" = 2 ] || fail "probe pane count $probe_pane_count, expected 2"
[ "$probe_sidebar_count" = 1 ] || fail "probe sidebar count $probe_sidebar_count, expected 1"
sidebar_window_probe '@999' && fail "probe succeeded on a missing window"
printf 'PASS: one list-panes answers the whole window question\n'

# --- 2. env fetch ----------------------------------------------------------
"${TMUX[@]}" set-environment -gh DOTFILES_SIDEBAR_TEST_ONE one
"${TMUX[@]}" set-environment -gh DOTFILES_SIDEBAR_TEST_TWO two
reset_calls
sidebar_env_fetch_all "$win" '#{@dotfiles_sidebar_ready}'
[ "$(calls)" = 1 ] || fail "env fetch took $(calls) round trips, expected 1"
[ "${SIDEBAR_ENV_MANY[DOTFILES_SIDEBAR_TEST_ONE]:-}" = one ] || fail "env fetch lost TEST_ONE"
[ "${SIDEBAR_ENV_MANY[DOTFILES_SIDEBAR_TEST_TWO]:-}" = two ] || fail "env fetch lost TEST_TWO"
[ "${SIDEBAR_ENV_MANY[__display]:-}" = 1 ] || fail "env fetch format returned '${SIDEBAR_ENV_MANY[__display]:-}', expected exactly 1"
printf 'PASS: one show-environment answers every flag plus a format\n'

# --- 3. batched writes -----------------------------------------------------
reset_calls
sidebar_env_set_many DOTFILES_SIDEBAR_TEST_ONE a DOTFILES_SIDEBAR_TEST_TWO b DOTFILES_SIDEBAR_TEST_THREE c
[ "$(calls)" = 1 ] || fail "batched write took $(calls) round trips, expected 1"
sidebar_env_fetch_all
for pair in ONE:a TWO:b THREE:c; do
    [ "${SIDEBAR_ENV_MANY[DOTFILES_SIDEBAR_TEST_${pair%%:*}]:-}" = "${pair#*:}" ] ||
        fail "batched write lost ${pair%%:*}"
done
printf 'PASS: several flags are written in one round trip\n'

# --- 4. layout snapshot ----------------------------------------------------
reset_calls
save_sidebar_layout "$win" || fail "layout snapshot failed"
[ "$(calls)" -le 3 ] || fail "layout snapshot took $(calls) round trips, expected at most 3: $(cat "$TMUX_ROUND_TRIP_LOG")"
[ "$(grep -c 'set-option' "$TMUX_ROUND_TRIP_LOG")" = 1 ] || fail "layout snapshot used more than one write round trip"
expected_layout="$("${TMUX[@]}" display-message -p -t "$win" '#{window_layout}')"
expected_panes="$("${TMUX[@]}" list-panes -t "$win" -F '#{pane_id}' | tr '\n' ' ' | sed 's/ *$//')"
expected_geometry="$("${TMUX[@]}" list-panes -t "$win" -F '#{pane_id}:#{pane_left},#{pane_top},#{pane_width},#{pane_height}' | sort | tr '\n' ' ' | sed 's/ *$//')"
expected_active="$("${TMUX[@]}" list-panes -t "$win" -F '#{pane_id}|#{pane_active}' | awk -F'|' '$2==1{print $1;exit}')"
[ "$("${TMUX[@]}" show-option -wqv -t "$win" @dotfiles-session-sidebar-layout)" = "$expected_layout" ] || fail "stored layout differs"
[ "$("${TMUX[@]}" show-option -wqv -t "$win" @dotfiles-session-sidebar-pane-ids)" = "$expected_panes" ] || fail "stored pane ids differ"
[ "$("${TMUX[@]}" show-option -wqv -t "$win" @dotfiles-session-sidebar-geometry)" = "$expected_geometry" ] || fail "stored geometry differs"
[ "$("${TMUX[@]}" show-option -wqv -t "$win" @dotfiles-session-sidebar-active-pane)" = "$expected_active" ] || fail "stored active pane differs"
printf 'PASS: the layout snapshot reads and writes in bulk and stores the same values\n'
