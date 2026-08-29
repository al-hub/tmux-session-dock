#!/usr/bin/env bash
# ============================================================================
# Verifies per-slot User Height Intent for the supported 3-slot stack.
#
# This deliberately combines the high-value transitions in one scenario:
#   1. independently resize every slot and snapshot the live layout;
#   2. swap the whole stack top/bottom;
#   3. lease the pool into another Presenter Window;
#   4. independently resize every slot again and snapshot it;
#   5. swap once more and verify no slot drifted.
#
# It complements the single-slot resize tests and the slot-count tests without
# adding a separate test for every permutation of count/position/session.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOCKET="test-subpane-multi-slot-resize-$$"
STATE_DIR="$(mktemp -d /tmp/test-subpane-multi-slot-resize.XXXXXX)"

cleanup() {
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT

export TMUX_SESSION_LAUNCHER_SOCKET="$SOCKET"
export TMUX="$SOCKET"
export TMUX_SESSION_SIDEBAR_SUBPANE_HEIGHT_STATE_FILE="$STATE_DIR/height"
export TMUX_SESSION_SIDEBAR_SUBPANE_POSITION_STATE_FILE="$STATE_DIR/position"
export TMUX_SESSION_SIDEBAR_SUBPANE_ENABLED_STATE_FILE="$STATE_DIR/enabled"

tmuxc() { tmux -L "$SOCKET" "$@"; }
source "$REPO_ROOT/tests/lib/subpane_topology_oracle.sh"
stack() {   # stack <window> <position> <h1> <h2> <h3>  - order + heights + column oracle
    local window="$1" position="$2"; shift 2
    subpane_oracle_assert_stack "$SOCKET" "$window" 3 "$position" "$@" || { echo "FAIL: stack oracle: $window $position $*" >&2; exit 1; }
}

slot_pane() {
    local window_id="$1" slot="$2"
    tmuxc list-panes -t "$window_id" -F '#{pane_id}|#{@dotfiles_subpane_slot}' |
        awk -F '|' -v wanted="$slot" '!done && $2 == wanted { print $1; done = 1 }'
}

slot_height() {
    tmuxc display-message -p -t "$1" '#{pane_height}'
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_slot_count() {
    local window_id="$1" expected="$2" actual
    actual="$(tmuxc list-panes -t "$window_id" -F '#{@dotfiles_sidebar_subpane}' |
        awk '$0 == 1 { count++ } END { print count + 0 }')"
    assert_eq "subpane slot count in $window_id" "$expected" "$actual"
}

setup_presenter_window() {
    local target="$1" main_pane sidebar
    main_pane="$(tmuxc display-message -p -t "$target" '#{pane_id}')"
    sidebar="$(tmuxc split-window -h -b -t "$main_pane" -l 34 -P -F '#{pane_id}')"
    tmuxc select-pane -t "$sidebar" -T dotfiles-session-sidebar
    tmuxc set-option -p -q -t "$sidebar" @dotfiles_sidebar_pane 1
    printf '%s\n' "$sidebar"
}

tmuxc -f /dev/null new-session -d -s sess1 -n main -x 140 -y 70 'sleep 120'
win1="$(tmuxc display-message -p -t sess1:main '#{window_id}')"
sidebar1="$(setup_presenter_window "$win1")"
tmuxc set-option -gq @session-dock-subpane-count 3

TMUX_PANE="$sidebar1" bash "$REPO_ROOT/scripts/tmux-session-dock" --toggle-subpane
assert_slot_count "$win1" 3

declare -a slot1_panes slot1_heights
for slot in 1 2 3; do
    slot1_panes[$slot]="$(slot_pane "$win1" "$slot")"
    [ -n "${slot1_panes[$slot]}" ] || { echo "FAIL: slot $slot pane missing" >&2; exit 1; }
done

# Distinct, conservative values make slot identity loss visible without
# exhausting the presenter's vertical budget.
for pair in '1:6' '2:8' '3:10'; do
    slot="${pair%%:*}"
    requested="${pair##*:}"
    tmuxc resize-pane -t "${slot1_panes[$slot]}" -y "$requested"
done
for slot in 1 2 3; do
    slot1_heights[$slot]="$(slot_height "${slot1_panes[$slot]}")"
    [ "${slot1_heights[$slot]}" -ge 2 ] || {
        echo "FAIL: slot $slot became unusably small after multi-slot resize" >&2
        exit 1
    }
done

source "$REPO_ROOT/scripts/lib/sidebar_domain.sh"
source "$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh"
source "$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh"
source "$REPO_ROOT/scripts/lib/sidebar_switch.sh"

stack "$win1" bottom "${slot1_heights[1]}" "${slot1_heights[2]}" "${slot1_heights[3]}"
remember_sidebar_subpane_height_for_window "$win1"
saved_total_height="$(tmuxc show-option -gqv @dotfiles_sidebar_subpane_height)"
for slot in 1 2 3; do
    saved="$(tmuxc show-option -gqv "@dotfiles_subpane_slot_${slot}_height")"
    assert_eq "slot $slot live height snapshot" "${slot1_heights[$slot]}" "$saved"
done

# Toggle the entire Sidebar off and on. The Subpane Pool should be parked,
# then re-leased with the same slot identities and User Height Intents.
TMUX_PANE="$sidebar1" bash "$REPO_ROOT/scripts/tmux-session-dock" --toggle-sidebar-session sess1
sidebar_subpane_count_off="$(tmuxc list-panes -t "$win1" -F '#{@dotfiles_sidebar_subpane}' |
    awk '$0 == 1 { count++ } END { print count + 0 }')"
assert_eq "subpane count after Sidebar OFF" 0 "$sidebar_subpane_count_off"

TMUX_PANE="$sidebar1" bash "$REPO_ROOT/scripts/tmux-session-dock" --toggle-sidebar-session sess1
sidebar1="$(sidebar_window_pane "$win1")"
assert_slot_count "$win1" 3
for slot in 1 2 3; do
    slot1_panes[$slot]="$(slot_pane "$win1" "$slot")"
    [ -n "${slot1_panes[$slot]}" ] || { echo "FAIL: slot $slot missing after Sidebar toggle" >&2; exit 1; }
    assert_eq "slot $slot height after Sidebar OFF/ON" \
        "${slot1_heights[$slot]}" "$(slot_height "${slot1_panes[$slot]}")"
done
stack "$win1" bottom "${slot1_heights[1]}" "${slot1_heights[2]}" "${slot1_heights[3]}"

TMUX_PANE="$sidebar1" bash "$REPO_ROOT/scripts/tmux-session-dock" --swap-subpane-position
for slot in 1 2 3; do
    assert_eq "slot $slot height after first position swap" \
        "${slot1_heights[$slot]}" "$(slot_height "${slot1_panes[$slot]}")"
done
stack "$win1" top "${slot1_heights[1]}" "${slot1_heights[2]}" "${slot1_heights[3]}"

tmuxc -f /dev/null new-session -d -s sess2 -n main -x 140 -y 70 'sleep 120'
win2="$(tmuxc display-message -p -t sess2:main '#{window_id}')"
sidebar2="$(setup_presenter_window "$win2")"

# Use the same hot switch seam as pressing Enter in the launcher. This is
# intentionally not ensure_sidebar_subpane_window: Enter supplies one
# canonical subpane plus the aggregate height to the switch transaction.
sidebar_switch_execute_hot "" "sess2" "$win2" "$sidebar2" "34" \
    "${slot1_panes[1]}" "$saved_total_height"
assert_slot_count "$win2" 3

declare -a slot2_panes slot2_heights
for slot in 1 2 3; do
    slot2_panes[$slot]="$(slot_pane "$win2" "$slot")"
    [ -n "${slot2_panes[$slot]}" ] || { echo "FAIL: migrated slot $slot missing" >&2; exit 1; }
    slot2_heights[$slot]="$(slot_height "${slot2_panes[$slot]}")"
    assert_eq "slot $slot height after Presenter Window migration" \
        "${slot1_heights[$slot]}" "${slot2_heights[$slot]}"
done
stack "$win2" top "${slot1_heights[1]}" "${slot1_heights[2]}" "${slot1_heights[3]}"

# Resize every slot after migration; this catches implementations that only
# remember the first visible slot or only update the aggregate height.
for pair in '1:7' '2:9' '3:11'; do
    slot="${pair%%:*}"
    requested="${pair##*:}"
    tmuxc resize-pane -t "${slot2_panes[$slot]}" -y "$requested"
done
for slot in 1 2 3; do
    slot2_heights[$slot]="$(slot_height "${slot2_panes[$slot]}")"
    [ "${slot2_heights[$slot]}" -ge 2 ] || {
        echo "FAIL: migrated slot $slot became unusably small after multi-slot resize" >&2
        exit 1
    }
done

remember_sidebar_subpane_height_for_window "$win2"
for slot in 1 2 3; do
    saved="$(tmuxc show-option -gqv "@dotfiles_subpane_slot_${slot}_height")"
    assert_eq "slot $slot second live height snapshot" "${slot2_heights[$slot]}" "$saved"
done

TMUX_PANE="$sidebar2" bash "$REPO_ROOT/scripts/tmux-session-dock" --swap-subpane-position
for slot in 1 2 3; do
    assert_eq "slot $slot height after second position swap" \
        "${slot2_heights[$slot]}" "$(slot_height "${slot2_panes[$slot]}")"
done
stack "$win2" bottom "${slot2_heights[1]}" "${slot2_heights[2]}" "${slot2_heights[3]}"

echo "PASS: 3-slot per-slot resize intent survived snapshots, migration, and position swaps"
