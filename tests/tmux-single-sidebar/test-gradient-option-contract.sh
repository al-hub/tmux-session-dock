#!/usr/bin/env bash
# Contract: @session-dock-gradient and @session-dock-gradient-speed reach a
# running presenter without restarting it, and turning the gradient off stops
# the fast frame loop rather than only skipping the drawing.
#
# 1. A presenter picks up the options it starts with.
# 2. Changing either option lands within a second, on the live presenter.
# 3. An out-of-range speed is clamped to the same range the popup shows.
# 4. Re-reading costs nothing while nothing changes (no trace churn).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
SOCKET="dotfiles-gradient-option-$$"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-gradient-option.XXXXXX")"
unset TMUX TMUX_PANE   # never inherit the outer server; the array below is local
TMUX=(tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf")

export TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET"
export TMUX_SESSION_LAUNCHER_LOCK_ROOT="$RUN_DIR"
export TMUX_SESSION_LAUNCHER_TRACE=1
export TMUX_SESSION_LAUNCHER_TRACE_FILE="$RUN_DIR/trace.log"

cleanup() { "${TMUX[@]}" kill-server >/dev/null 2>&1 || true; rm -rf "$RUN_DIR"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; tail -15 "$RUN_DIR/trace.log" >&2 2>/dev/null || true; exit 1; }

last_config() { grep -a "gradient.config" "$RUN_DIR/trace.log" 2>/dev/null | tail -1; }
config_count() { grep -ac "gradient.config" "$RUN_DIR/trace.log" 2>/dev/null || echo 0; }

wait_for_config() {   # wait_for_config <substring> <what>
    local want="$1" what="$2" deadline=$(( $(date +%s) + 8 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        case "$(last_config)" in *"$want"*) return 0 ;; esac
        sleep 0.1
    done
    fail "$what: never saw '$want' (last: ${$(last_config):-none})"
}

"${TMUX[@]}" new-session -d -s main -x 120 -y 30 -c "$REPO_ROOT" 'sleep 300'
for v in TMUX_SESSION_LAUNCHER_TRACE TMUX_SESSION_LAUNCHER_TRACE_FILE TMUX_SESSION_LAUNCHER_LOCK_ROOT; do
    "${TMUX[@]}" set-environment -g "$v" "$(eval printf '%s' "\$$v")"
done

# --- 1. the presenter starts with the configured cycle -----------------------
"${TMUX[@]}" set-option -gq @session-dock-gradient-speed 2000
win="$("${TMUX[@]}" display-message -p -t '=main:' '#{window_id}')"
"${TMUX[@]}" run-shell "$LAUNCHER --ensure-sidebar-window $win 34"
for _ in $(seq 1 200); do
    [ "$("${TMUX[@]}" show-option -wqv -t '=main:' @dotfiles_sidebar_ready 2>/dev/null)" = 1 ] && break
    sleep 0.05
done
[ "$("${TMUX[@]}" show-option -wqv -t '=main:' @dotfiles_sidebar_ready 2>/dev/null)" = 1 ] || fail "presenter never became ready"
wait_for_config "enabled=true cycle_ms=2000" "startup"
case "$(last_config)" in
    *"frame_us=83333"*"interval=0.083333"*) ;;
    *) fail "startup derived the wrong clocks: $(last_config)" ;;
esac
printf 'PASS: the presenter starts with the configured cycle and derives both clocks\n'

# --- 2. a change reaches the live presenter ----------------------------------
"${TMUX[@]}" set-option -gq @session-dock-gradient off
wait_for_config "enabled=false" "gradient off"
"${TMUX[@]}" set-option -gq @session-dock-gradient on
"${TMUX[@]}" set-option -gq @session-dock-gradient-speed 500
wait_for_config "enabled=true cycle_ms=500" "gradient on at 500 ms"
printf 'PASS: an option change lands on the running presenter\n'

# --- 3. out of range is clamped ----------------------------------------------
"${TMUX[@]}" set-option -gq @session-dock-gradient-speed 10
wait_for_config "cycle_ms=400" "clamp low"
"${TMUX[@]}" set-option -gq @session-dock-gradient-speed 99999
wait_for_config "cycle_ms=4000" "clamp high"
printf 'PASS: an out-of-range cycle is clamped, not refused\n'

# --- 4. re-reading is silent while nothing changes ---------------------------
before="$(config_count)"
sleep 3
after="$(config_count)"
[ "$before" = "$after" ] || fail "the once-a-second re-read logged $((after - before)) times with no change"
printf 'PASS: re-reading the options is silent while they do not change\n'
