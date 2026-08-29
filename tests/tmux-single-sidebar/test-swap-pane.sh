#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-swap-pane.sh
# Ctrl+Alt+arrow (--swap-pane) is dock-aware:
#   - a work pane swaps with its geometric neighbour and keeps focus
#   - a swap towards the dock column (sidebar / subpane) is ignored
#   - from the sidebar or the subpane, Up/Down flips the subpane stack
#     position; Left/Right do nothing
#   - the plugin binds C-M-arrows to --swap-pane
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMUX_CONF="$SCRIPT_DIR/tests/fixtures/test-tmux.conf"
BIN="$SCRIPT_DIR/scripts/tmux-session-dock"
PLUGIN_ENTRY="$SCRIPT_DIR/session-dock.tmux"
SOCKET="test-swap-pane-$$"
STATE_DIR="$(mktemp -d)"
cleanup() { tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$STATE_DIR"; }
trap cleanup EXIT

export TMUX="$SOCKET"
export TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET"
export TMUX_SESSION_SIDEBAR_SUBPANE_HEIGHT_STATE_FILE="$STATE_DIR/height"
export TMUX_SESSION_SIDEBAR_SUBPANE_POSITION_STATE_FILE="$STATE_DIR/pos"
export TMUX_SESSION_SIDEBAR_SUBPANE_ENABLED_STATE_FILE="$STATE_DIR/enabled"
source "$SCRIPT_DIR/scripts/lib/sidebar_domain.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_port_tmux.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_subpane_hub.sh"
source "$SCRIPT_DIR/tests/lib/subpane_topology_oracle.sh"

t() { tmux -L "$SOCKET" "$@"; }
geo() { t display-message -p -t "$1" '#{pane_left}'; }
active() { t display-message -p -t work:main '#{pane_id}'; }
swap() {   # swap <dir> <from-pane>
    t select-pane -t "$2"
    TMUX_PANE="$2" bash "$BIN" --swap-pane "$1"
}
fail() { echo "FAIL: $*"; t list-panes -t work:main -F '#{pane_id} #{pane_left},#{pane_top} #{pane_width}x#{pane_height} #{pane_title}'; exit 1; }

echo "=== [1/6] plugin binds C-M-arrows to --swap-pane ==="
tmux -L "$SOCKET" -f "$TEST_TMUX_CONF" new-session -d -s work -n main -x 140 -y 40 'sleep 120'
t run-shell "bash '$PLUGIN_ENTRY'"
for pair in "C-M-Left:L" "C-M-Right:R" "C-M-Up:U" "C-M-Down:D"; do
    key="${pair%%:*}"; dir="${pair##*:}"
    binding="$(t list-keys -T root "$key")"
    case "$binding" in *"--swap-pane $dir"*) ;; *) fail "$key must run --swap-pane $dir, got: $binding" ;; esac
done
echo "PASS: bindings"

echo "=== [2/6] layout: sidebar(+subpane) | w1 | w2 ==="
win="$(t display-message -p -t work:main '#{window_id}')"
w1="$(t display-message -p -t work:main '#{pane_id}')"
sidebar="$(t split-window -P -F '#{pane_id}' -d -t "$win" -h -f -b -l 34 'sleep 120')"
t select-pane -t "$sidebar" -T dotfiles-session-sidebar
t set-option -p -q -t "$sidebar" @dotfiles_sidebar_pane 1
sub="$(provision_sidebar_subpane "$win" "$sidebar" 12 "")"
[ -n "$sub" ] || fail "could not provision the subpane"
w2="$(t split-window -P -F '#{pane_id}' -h -t "$w1" 'sleep 120')"
[ "$(geo "$w1")" -lt "$(geo "$w2")" ] || fail "precondition: w1 left of w2"

echo "=== [3/6] work pane swaps with its neighbour and keeps focus ==="
swap L "$w2"
[ "$(geo "$w2")" = "35" ] || fail "w2 must have moved next to the dock, got left=$(geo "$w2")"
[ "$(geo "$w1")" -gt "$(geo "$w2")" ] || fail "Left from w2: w2 must now be left of w1"
[ "$(active)" = "$w2" ] || fail "focus must follow the swapped pane"
swap L "$w2"
[ "$(geo "$w2")" = "35" ] && [ "$(geo "$w1")" -gt "$(geo "$w2")" ] || fail "Left next to the dock must be ignored"
swap R "$w2"
[ "$(geo "$w1")" -lt "$(geo "$w2")" ] || fail "Right from w2 must swap back"
[ "$(active)" = "$w2" ] || fail "focus must follow after Right"
echo "PASS: horizontal swaps"

echo "=== [4/6] vertical swap ==="
w3="$(t split-window -P -F '#{pane_id}' -v -t "$w1" 'sleep 120')"
[ "$(t display-message -p -t "$w3" '#{pane_top}')" -gt "$(t display-message -p -t "$w1" '#{pane_top}')" ] || fail "precondition: w3 below w1"
swap U "$w3"
[ "$(t display-message -p -t "$w3" '#{pane_top}')" -lt "$(t display-message -p -t "$w1" '#{pane_top}')" ] || fail "Up from w3 must move it above w1"
[ "$(active)" = "$w3" ] || fail "focus must follow the vertical swap"
before="$(t list-panes -t "$win" -F '#{pane_id} #{pane_left},#{pane_top}' | sort)"
swap U "$w3"
[ "$(t list-panes -t "$win" -F '#{pane_id} #{pane_left},#{pane_top}' | sort)" = "$before" ] || fail "Up with no neighbour must be a no-op"
swap D "$w3"
[ "$(t display-message -p -t "$w3" '#{pane_top}')" -gt "$(t display-message -p -t "$w1" '#{pane_top}')" ] || fail "Down must swap back"
t kill-pane -t "$w3"
echo "PASS: vertical swaps"

echo "=== [5/6] from the sidebar / subpane, Up/Down flips the stack position ==="
subpane_oracle_assert_stack "$SOCKET" "$win" 1 bottom 12 || fail "precondition: bottom stack"
swap U "$sidebar"
[ "$(sidebar_subpane_get_position)" = "top" ] || fail "Up from the sidebar must flip the stack to top"
subpane_oracle_assert_stack "$SOCKET" "$win" 1 top 12 || fail "stack must be on top after Up"
[ "$(active)" = "$sidebar" ] || fail "focus must stay on the sidebar"
swap U "$sidebar"
subpane_oracle_assert_stack "$SOCKET" "$win" 1 top 12 || fail "Up while already top must be a no-op"
sub="$(t list-panes -t "$win" -F '#{pane_id}|#{@dotfiles_sidebar_subpane}' | awk -F '|' '$2=="1"{print $1; exit}')"
swap D "$sub"
[ "$(sidebar_subpane_get_position)" = "bottom" ] || fail "Down from the subpane must flip the stack to bottom"
subpane_oracle_assert_stack "$SOCKET" "$win" 1 bottom 12 || fail "stack must be at the bottom after Down"
echo "PASS: stack position flips"

echo "=== [6/6] Left/Right from the dock column and swaps into it are ignored ==="
before="$(t list-panes -t "$win" -F '#{pane_id} #{pane_left},#{pane_top}' | sort)"
swap L "$sidebar"; swap R "$sidebar"; swap R "$sub"
[ "$(t list-panes -t "$win" -F '#{pane_id} #{pane_left},#{pane_top}' | sort)" = "$before" ] || fail "Left/Right from the dock column must be no-ops"
swap L "$w1"
[ "$(t list-panes -t "$win" -F '#{pane_id} #{pane_left},#{pane_top}' | sort)" = "$before" ] || fail "a work pane must never swap into the dock column"
echo "PASS: dock column untouched"

echo "PASS: dock-aware pane swap"
