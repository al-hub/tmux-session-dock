#!/usr/bin/env bash
# ============================================================================
# Two-slot User Height Intent preservation through the real Enter switch seam.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOCKET="dock-test-height-$$"
STATE_DIR="$(mktemp -d /tmp/test-subpane-height.XXXXXX)"

cleanup() {
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT

export TMUX="$SOCKET"
export TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET"
export TMUX_SESSION_SIDEBAR_SUBPANE_HEIGHT_STATE_FILE="$STATE_DIR/height"
export TMUX_SESSION_SIDEBAR_SUBPANE_POSITION_STATE_FILE="$STATE_DIR/position"
export TMUX_SESSION_SIDEBAR_SUBPANE_ENABLED_STATE_FILE="$STATE_DIR/enabled"

tmuxc() { tmux -L "$SOCKET" "$@"; }

slot_pane() {
    local window_id="$1" slot="$2"
    tmuxc list-panes -t "$window_id" -F '#{pane_id}|#{@dotfiles_subpane_slot}' |
        awk -F '|' -v wanted="$slot" '!done && $2 == wanted { print $1; done = 1 }'
}

slot_count() {
    tmuxc list-panes -t "$1" -F '#{@dotfiles_sidebar_subpane}' |
        awk '$0 == 1 { count++ } END { print count + 0 }'
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

setup_presenter() {
    local window_id="$1" main sidebar
    main="$(tmuxc display-message -p -t "$window_id" '#{pane_id}')"
    sidebar="$(tmuxc split-window -h -b -t "$main" -l 34 -P -F '#{pane_id}')"
    tmuxc select-pane -t "$sidebar" -T dotfiles-session-sidebar
    tmuxc set-option -p -q -t "$sidebar" @dotfiles_sidebar_pane 1
    printf '%s\n' "$sidebar"
}

tmuxc -f /dev/null new-session -d -s sess1 -n main -x 120 -y 60 'sleep 120'
win1="$(tmuxc display-message -p -t sess1:main '#{window_id}')"
sidebar1="$(setup_presenter "$win1")"
tmuxc set-option -gq @session-dock-subpane-count 2
TMUX_PANE="$sidebar1" bash "$REPO_ROOT/scripts/tmux-session-dock" --toggle-subpane

assert_eq 'initial slot count' 2 "$(slot_count "$win1")"
s1="$(slot_pane "$win1" 1)"
s2="$(slot_pane "$win1" 2)"
[ -n "$s1" ] || { echo 'FAIL: slot 1 pane missing' >&2; exit 1; }
[ -n "$s2" ] || { echo 'FAIL: slot 2 pane missing' >&2; exit 1; }

# Simulate two independent mouse drags, then invoke the production
# after-resize-pane seam rather than directly writing the height options.
tmuxc resize-pane -t "$s1" -y 8
tmuxc resize-pane -t "$s2" -y 11
bash "$REPO_ROOT/scripts/tmux-session-dock" --sync-sidebar-layout "$win1" manual-resize

h1="$(tmuxc show-option -gqv @dotfiles_subpane_slot_1_height)"
h2="$(tmuxc show-option -gqv @dotfiles_subpane_slot_2_height)"
[ "$h1" -ge 4 ] || { echo "FAIL: slot 1 mouse height was not saved ($h1)" >&2; exit 1; }
[ "$h2" -ge 4 ] || { echo "FAIL: slot 2 mouse height was not saved ($h2)" >&2; exit 1; }

# This is the same seam used by pressing Enter in the launcher. The target
# starts with a Presenter Window but no Subpane lease.
tmuxc -f /dev/null new-session -d -s sess2 -n main -x 120 -y 60 'sleep 120'
win2="$(tmuxc display-message -p -t sess2:main '#{window_id}')"
sidebar2="$(setup_presenter "$win2")"
source "$REPO_ROOT/scripts/lib/sidebar_domain.sh"
source "$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh"
source "$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh"
source "$REPO_ROOT/scripts/lib/sidebar_switch.sh"

total_height="$(tmuxc show-option -gqv @dotfiles_sidebar_subpane_height)"
sidebar_switch_execute_hot '' sess2 "$win2" "$sidebar2" 34 "$s1" "$total_height"

assert_eq 'slot count after Enter switch' 2 "$(slot_count "$win2")"
s1_target="$(slot_pane "$win2" 1)"
s2_target="$(slot_pane "$win2" 2)"
[ -n "$s1_target" ] || { echo 'FAIL: target slot 1 pane missing' >&2; exit 1; }
[ -n "$s2_target" ] || { echo 'FAIL: target slot 2 pane missing' >&2; exit 1; }
assert_eq 'slot 1 height after Enter switch' "$h1" "$(tmuxc display-message -p -t "$s1_target" '#{pane_height}')"
assert_eq 'slot 2 height after Enter switch' "$h2" "$(tmuxc display-message -p -t "$s2_target" '#{pane_height}')"

echo 'PASS: two-slot mouse heights survived hook, position swap, and Enter session switch'
