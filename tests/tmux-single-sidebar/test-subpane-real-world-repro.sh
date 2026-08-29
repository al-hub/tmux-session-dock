#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-subpane-real-world-repro.sh
# Detects real-world subpane degradation across:
# 1) Repeated rapid swaps ('p' -> 'p' -> 'p' -> 'p')
# 2) Bidirectional session roundtrip (sess1 -> sess2 -> sess1)
# 3) Ghost pane duplication and launcher collapse
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_SOCKET="dock-test-repro-$$"
BIN_SCRIPT="$REPO_ROOT/scripts/tmux-session-dock"
source "$REPO_ROOT/tests/lib/subpane_topology_oracle.sh"
stack_or_flag() {   # stack_or_flag <label> <window> <position> <h1> <h2>
    local label="$1" window="$2" position="$3"; shift 3
    if ! subpane_oracle_assert_stack "$TEST_SOCKET" "$window" 2 "$position" "$@"; then
        echo "🚨 [DETECTED BUG] $label: slot order/height/column violated ($*)"
        suite_failed=1
    fi
}
suite_failed=0
STATE_DIR="$(mktemp -d /tmp/subpane-real-world-state.XXXXXX)"
export TMUX_SESSION_SIDEBAR_SUBPANE_HEIGHT_STATE_FILE="$STATE_DIR/height"
export TMUX_SESSION_SIDEBAR_SUBPANE_POSITION_STATE_FILE="$STATE_DIR/position"
export TMUX_SESSION_SIDEBAR_SUBPANE_ENABLED_STATE_FILE="$STATE_DIR/enabled"

cleanup() {
    tmux -L "$TEST_SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT

echo "=========================================================================="
echo "🧪 REAL-WORLD SUBPANE STABILITY & HEIGHT DETECTION SUITE"
echo "=========================================================================="

# 1. Initialize sess1 with 2 subpane slots
tmux -L "$TEST_SOCKET" -f /dev/null new-session -d -s sess1 -n main -x 120 -y 50
win1="$(tmux -L "$TEST_SOCKET" display-message -p '#{window_id}')"
m1="$(tmux -L "$TEST_SOCKET" display-message -p '#{pane_id}')"
s1_bar="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$m1" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$s1_bar" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$s1_bar" @dotfiles_sidebar_pane 1

# Configure 2 slots
tmux -L "$TEST_SOCKET" set-option -gq "@session-dock-subpane-count" 2
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$s1_bar" bash "$BIN_SCRIPT" --toggle-subpane

sp1="$(tmux -L "$TEST_SOCKET" list-panes -t "$win1" -F '#{pane_id}|#{@dotfiles_subpane_slot}' | awk -F '|' '$2 == "1" { print $1 }')"
sp2="$(tmux -L "$TEST_SOCKET" list-panes -t "$win1" -F '#{pane_id}|#{@dotfiles_subpane_slot}' | awk -F '|' '$2 == "2" { print $1 }')"
canonical_ids=("$sp1" "$sp2")

CUSTOM_H1=9
CUSTOM_H2=16
tmux -L "$TEST_SOCKET" resize-pane -t "$s1_bar" -y 23
tmux -L "$TEST_SOCKET" resize-pane -t "$sp1" -y "$CUSTOM_H1"

# Notify resize hook
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    remember_sidebar_subpane_height_for_window '$win1'
"

echo ""
echo "=== [Setup] Initial State in sess1 ==="
echo "Launcher ($s1_bar) height=$(tmux -L "$TEST_SOCKET" display-message -p -t "$s1_bar" '#{pane_height}')"
echo "Slot 1   ($sp1) height=$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp1" '#{pane_height}') (Expected $CUSTOM_H1)"
echo "Slot 2   ($sp2) height=$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp2" '#{pane_height}') (Expected $CUSTOM_H2)"

# ------------------------------------------------------------------------------
# Test 1: Repeated Rapid Swaps (p 4 times)
# ------------------------------------------------------------------------------
echo ""
echo "=== [Test 1] Repeated Rapid Swaps (p 4 times) ==="
swap_failed=0
for i in 1 2 3 4; do
    TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$s1_bar" bash "$BIN_SCRIPT" --swap-subpane-position
    cur_h1="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp1" '#{pane_height}')"
    cur_h2="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp2" '#{pane_height}')"
    echo "  Swap $i: Slot 1=$cur_h1 (expected $CUSTOM_H1), Slot 2=$cur_h2 (expected $CUSTOM_H2)"
    if [ "$cur_h1" -ne "$CUSTOM_H1" ] || [ "$cur_h2" -ne "$CUSTOM_H2" ]; then
        swap_failed=1
    fi
    if [ $((i % 2)) -eq 1 ]; then swap_pos=top; else swap_pos=bottom; fi
    stack_or_flag "swap $i" "$win1" "$swap_pos" "$CUSTOM_H1" "$CUSTOM_H2"
done

if [ "$swap_failed" -eq 1 ]; then
    echo "🚨 [DETECTED BUG 1]: Heights degraded during repeated swaps!"
    suite_failed=1
else
    echo "ℹ️ [Test 1 PASS]: Heights preserved across 4 repeated swaps."
fi

# ------------------------------------------------------------------------------
# Test 2: Bidirectional Session Roundtrip (sess1 -> sess2 -> sess1)
# ------------------------------------------------------------------------------
echo ""
echo "=== [Test 2] Bidirectional Session Roundtrip (sess1 -> sess2 -> sess1) ==="

# Move the pool to top before leasing it to another presenter. This exercises
# the multi-slot top ingress calculation rather than only bottom migration.
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$s1_bar" bash "$BIN_SCRIPT" --swap-subpane-position
top_h1="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp1" '#{pane_height}')"
top_h2="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp2" '#{pane_height}')"
if [ "$top_h1" -ne "$CUSTOM_H1" ] || [ "$top_h2" -ne "$CUSTOM_H2" ]; then
    echo "🚨 [DETECTED BUG 2]: Top transition changed slot heights (slot1=$top_h1, slot2=$top_h2)"
    suite_failed=1
fi

# 1. Create sess2
tmux -L "$TEST_SOCKET" -f /dev/null new-session -d -s sess2 -n main -x 120 -y 50
win2="$(tmux -L "$TEST_SOCKET" display-message -p -t "sess2:main" '#{window_id}')"
m2="$(tmux -L "$TEST_SOCKET" display-message -p -t "sess2:main" '#{pane_id}')"
s2_bar="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$m2" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$s2_bar" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$s2_bar" @dotfiles_sidebar_pane 1

# Migrate to sess2
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    ensure_sidebar_subpane_window '$win2' '$s2_bar'
"
subpane_oracle_assert_leased_pool "$TEST_SOCKET" 2 "$win2" "${canonical_ids[@]}"
stack_or_flag "migration to sess2 (top)" "$win2" top "$CUSTOM_H1" "$CUSTOM_H2"

s2_count="$(tmux -L "$TEST_SOCKET" list-panes -t "$win2" -F '#{@dotfiles_sidebar_subpane}' | grep -c '1' || true)"
s2_h1="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp1" '#{pane_height}')"
s2_h2="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp2" '#{pane_height}')"
echo "Panes in sess2 after migration: $s2_count subpane(s) (Expected 2), heights=$s2_h1/$s2_h2"

# 2. Migrate back to sess1
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    ensure_sidebar_subpane_window '$win1' '$s1_bar'
"
subpane_oracle_assert_leased_pool "$TEST_SOCKET" 2 "$win1" "${canonical_ids[@]}"
stack_or_flag "roundtrip back to sess1 (top)" "$win1" top "$CUSTOM_H1" "$CUSTOM_H2"

s1_count_back="$(tmux -L "$TEST_SOCKET" list-panes -t "$win1" -F '#{@dotfiles_sidebar_subpane}' | grep -c '1' || true)"
launcher_h_back="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s1_bar" '#{pane_height}')"
s1_h1_back="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp1" '#{pane_height}')"
s1_h2_back="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp2" '#{pane_height}')"
echo "Panes in sess1 after roundtrip: $s1_count_back subpane(s) (Expected 2), heights=$s1_h1_back/$s1_h2_back, Launcher height=$launcher_h_back (Expected >= 20)"

if [ "$s2_count" -ne 2 ] || [ "$s1_count_back" -ne 2 ] || [ "$launcher_h_back" -lt 15 ] || \
    [ "$s2_h1" -ne "$CUSTOM_H1" ] || [ "$s2_h2" -ne "$CUSTOM_H2" ] || \
    [ "$s1_h1_back" -ne "$CUSTOM_H1" ] || [ "$s1_h2_back" -ne "$CUSTOM_H2" ]; then
    echo "🚨 [DETECTED BUG 2]: Session roundtrip caused subpane loss, ghost duplication, or launcher collapse!"
    echo "   sess2 count=$s2_count heights=$s2_h1/$s2_h2; sess1 back count=$s1_count_back heights=$s1_h1_back/$s1_h2_back; launcher height=$launcher_h_back"
    suite_failed=1
else
    echo "ℹ️ [Test 2 PASS]: Session roundtrip preserved clean 2-slot stack without ghost panes."
fi

echo ""
echo "=========================================================================="
echo "Detection suite complete."
echo "=========================================================================="
exit "$suite_failed"
