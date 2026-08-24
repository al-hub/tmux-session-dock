#!/usr/bin/env bash
# ==============================================================================
# tests/tmux-single-sidebar/test-subpane-single-slot-bugs.sh
# Detects bugs specific to single-slot (count=1) subpane operation:
#
# Bug 1a: After mouse drag resize, height NOT preserved across repeated swaps
# Bug 1b: After mouse drag resize, height NOT preserved across session roundtrip
# Bug 2:  Subpane entry should ONLY happen when sidebar session has focus
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_SOCKET="dock-test-single-slot-$$"
BIN_SCRIPT="$REPO_ROOT/scripts/tmux-session-dock"

cleanup() {
    tmux -L "$TEST_SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

PASS=0
FAIL=0
report() {
    local status="$1" name="$2"
    shift 2
    if [ "$status" = "PASS" ]; then
        PASS=$((PASS + 1))
        echo "  ✅ [PASS] $name"
    else
        FAIL=$((FAIL + 1))
        echo "  🚨 [FAIL] $name"
        [ $# -gt 0 ] && echo "         $*"
    fi
}

# Simulate mouse drag: resize pane then trigger the real hook path
# In production: after-resize-pane → --sync-sidebar-layout $WIN manual-resize
#   → sync_sidebar_layout() → remember_sidebar_subpane_height_for_window()
# The CLI path has guards (sidebar_enabled, find_sidebar_pane, transition, etc.)
# that the direct function call skips. We simulate BOTH paths.
simulate_mouse_drag() {
    local pane="$1" new_h="$2" win="$3"
    tmux -L "$TEST_SOCKET" resize-pane -t "$pane" -y "$new_h"

    # Path A: Direct function call (what previous tests did — may NOT match prod)
    TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
        source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
        source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
        remember_sidebar_subpane_height_for_window '$win'
    " 2>/dev/null || true

    # Path B: CLI hook path (matches production after-resize-pane hook)
    TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$pane" \
        bash "$BIN_SCRIPT" --sync-sidebar-layout "$win" manual-resize 2>/dev/null || true
}

echo "=========================================================================="
echo "🧪 SINGLE-SLOT SUBPANE BUG DETECTION SUITE (with mouse drag)"
echo "=========================================================================="

# ─── Setup: sess1 with 1 subpane slot ────────────────────────────────────────
tmux -L "$TEST_SOCKET" -f /dev/null new-session -d -s sess1 -n main -x 120 -y 50
# Enable sidebar globally
tmux -L "$TEST_SOCKET" set-option -gq "@dotfiles_sidebar_enabled" 1
win1="$(tmux -L "$TEST_SOCKET" display-message -p -t sess1:main '#{window_id}')"
m1="$(tmux -L "$TEST_SOCKET" display-message -p -t sess1:main '#{pane_id}')"
# Create sidebar pane
s1_bar="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$m1" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$s1_bar" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$s1_bar" @dotfiles_sidebar_pane 1

# Configure 1 slot (single) — set count before toggle
tmux -L "$TEST_SOCKET" set-option -gq "@session-dock-subpane-count" 1
# Toggle subpane on (flips enabled 0→1 and provisions)
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$s1_bar" bash "$BIN_SCRIPT" --toggle-subpane

# Find the single subpane
sp1="$(tmux -L "$TEST_SOCKET" list-panes -t "$win1" \
    -F '#{pane_id}|#{@dotfiles_sidebar_subpane}' | \
    awk -F '|' '$2 == "1" { print $1 }' | head -n 1)"

if [ -z "$sp1" ]; then
    echo "❌ Setup failed: no subpane found after toggle"
    exit 99
fi

# Simulate mouse drag to custom height (10 lines)
CUSTOM_H=10
simulate_mouse_drag "$sp1" "$CUSTOM_H" "$win1"
sleep 0.1

init_h="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp1" '#{pane_height}')"
saved_slot1="$(tmux -L "$TEST_SOCKET" show-option -gqv '@dotfiles_subpane_slot_1_height' 2>/dev/null || true)"
saved_total="$(tmux -L "$TEST_SOCKET" show-option -gqv '@dotfiles_sidebar_subpane_height' 2>/dev/null || true)"

echo ""
echo "=== Setup ==="
echo "    Single-slot, mouse-dragged to height=$CUSTOM_H"
echo "    Actual pane height=$init_h"
echo "    Saved slot_1_height=$saved_slot1, total_height=$saved_total"

# ─────────────────────────────────────────────────────────────────────────────
# Test 1a: Mouse drag → 4 repeated swaps → height preserved?
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== [Test 1a] Mouse drag → 4 repeated swaps ==="
swap_failed=0
for i in 1 2 3 4; do
    TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$s1_bar" bash "$BIN_SCRIPT" --swap-subpane-position
    cur_h="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp1" '#{pane_height}')"
    echo "    Swap $i: height=$cur_h (expected $CUSTOM_H)"
    if [ "$cur_h" -ne "$CUSTOM_H" ]; then
        swap_failed=1
    fi
done

if [ "$swap_failed" -eq 1 ]; then
    report FAIL "1a: Mouse drag + 4 swaps height preserved" \
        "Height drifted from $CUSTOM_H"
else
    report PASS "1a: Mouse drag + 4 swaps height preserved"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 1b: Mouse drag → session roundtrip → height preserved?
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== [Test 1b] Mouse drag → session roundtrip (sess1→sess2→sess1) ==="

# Re-drag to ensure custom height is current
simulate_mouse_drag "$sp1" "$CUSTOM_H" "$win1"
sleep 0.1

# Create sess2 with sidebar
tmux -L "$TEST_SOCKET" new-session -d -s sess2 -n main -x 120 -y 50
win2="$(tmux -L "$TEST_SOCKET" display-message -p -t sess2:main '#{window_id}')"
m2="$(tmux -L "$TEST_SOCKET" display-message -p -t sess2:main '#{pane_id}')"
s2_bar="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$m2" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$s2_bar" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$s2_bar" @dotfiles_sidebar_pane 1

# Migrate subpane to sess2
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    ensure_sidebar_subpane_window '$win2' '$s2_bar'
"

s2_sub_h="$(tmux -L "$TEST_SOCKET" list-panes -t "$win2" \
    -F '#{pane_id}|#{@dotfiles_sidebar_subpane}|#{pane_height}' | \
    awk -F '|' '$2 == "1" { print $3 }' | head -n 1)"
echo "    In sess2: subpane height=${s2_sub_h:-N/A} (expected $CUSTOM_H)"

# Migrate back to sess1
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    ensure_sidebar_subpane_window '$win1' '$s1_bar'
"

s1_sub_count="$(tmux -L "$TEST_SOCKET" list-panes -t "$win1" \
    -F '#{@dotfiles_sidebar_subpane}' | grep -c '1' || true)"
s1_sub_h="$(tmux -L "$TEST_SOCKET" list-panes -t "$win1" \
    -F '#{pane_id}|#{@dotfiles_sidebar_subpane}|#{pane_height}' | \
    awk -F '|' '$2 == "1" { print $3 }' | head -n 1)"
launcher_h="$(tmux -L "$TEST_SOCKET" display-message -p -t "$s1_bar" '#{pane_height}')"

echo "    Back in sess1:"
echo "      subpane count=${s1_sub_count:-0} (expected 1)"
echo "      subpane height=${s1_sub_h:-N/A} (expected $CUSTOM_H)"
echo "      launcher height=${launcher_h:-N/A} (expected >= 20)"

roundtrip_ok=true
[ "${s1_sub_count:-0}" -ne 1 ] && roundtrip_ok=false
[ "${s1_sub_h:-0}" -ne "$CUSTOM_H" ] && roundtrip_ok=false
[ "${launcher_h:-0}" -lt 15 ] && roundtrip_ok=false

if $roundtrip_ok; then
    report PASS "1b: Mouse drag + session roundtrip height preserved"
else
    report FAIL "1b: Mouse drag + session roundtrip height preserved" \
        "count=${s1_sub_count:-0} height=${s1_sub_h:-N/A} launcher=${launcher_h:-N/A}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 1c: Mouse drag → swap → mouse drag again → session roundtrip
#          (complex real-world sequence)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== [Test 1c] Mouse drag → swap → mouse drag again → session roundtrip ==="

# Drag to 8
DRAG_H1=8
simulate_mouse_drag "$sp1" "$DRAG_H1" "$win1"
sleep 0.1
echo "    Step 1: Dragged to $DRAG_H1, actual=$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp1" '#{pane_height}')"

# Swap once
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" TMUX_PANE="$s1_bar" bash "$BIN_SCRIPT" --swap-subpane-position
after_swap_h="$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp1" '#{pane_height}')"
echo "    Step 2: After swap, height=$after_swap_h (expected $DRAG_H1)"

# Drag to 12 (user adjusts again after swap)
DRAG_H2=12
simulate_mouse_drag "$sp1" "$DRAG_H2" "$win1"
sleep 0.1
echo "    Step 3: Re-dragged to $DRAG_H2, actual=$(tmux -L "$TEST_SOCKET" display-message -p -t "$sp1" '#{pane_height}')"

# Session roundtrip: sess1 → sess2 → sess1
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    ensure_sidebar_subpane_window '$win2' '$s2_bar'
"
TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    ensure_sidebar_subpane_window '$win1' '$s1_bar'
"

final_h="$(tmux -L "$TEST_SOCKET" list-panes -t "$win1" \
    -F '#{pane_id}|#{@dotfiles_sidebar_subpane}|#{pane_height}' | \
    awk -F '|' '$2 == "1" { print $3 }' | head -n 1)"
echo "    Step 4: After roundtrip, height=${final_h:-N/A} (expected $DRAG_H2)"

if [ "${final_h:-0}" -eq "$DRAG_H2" ]; then
    report PASS "1c: Drag→swap→drag→roundtrip height preserved"
else
    report FAIL "1c: Drag→swap→drag→roundtrip height preserved" \
        "Expected $DRAG_H2, got ${final_h:-N/A}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Subpane entry should require sidebar focus
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== [Test 2] Subpane entry requires sidebar focus ==="

# Clean slate
tmux -L "$TEST_SOCKET" kill-session -t "=dotfiles-subpane-hub:" 2>/dev/null || true

# Fresh sess3
tmux -L "$TEST_SOCKET" new-session -d -s sess3 -n main -x 120 -y 50
win3="$(tmux -L "$TEST_SOCKET" display-message -p -t sess3:main '#{window_id}')"
m3="$(tmux -L "$TEST_SOCKET" display-message -p -t sess3:main '#{pane_id}')"
s3_bar="$(tmux -L "$TEST_SOCKET" split-window -h -b -t "$m3" -l 34 -P -F '#{pane_id}')"
tmux -L "$TEST_SOCKET" select-pane -t "$s3_bar" -T "dotfiles-session-sidebar"
tmux -L "$TEST_SOCKET" set-option -p -q -t "$s3_bar" @dotfiles_sidebar_pane 1

tmux -L "$TEST_SOCKET" set-option -gq "@dotfiles_sidebar_subpane_enabled" 1
tmux -L "$TEST_SOCKET" set-option -gq "@session-dock-subpane-count" 1

# Focus on WORK pane (not sidebar)
tmux -L "$TEST_SOCKET" select-pane -t "$m3"

pane_count_before="$(tmux -L "$TEST_SOCKET" list-panes -t "$win3" | wc -l | tr -d ' ')"

TMUX_SESSION_LAUNCHER_SOCKET="$TEST_SOCKET" bash -c "
    source '$REPO_ROOT/scripts/lib/sidebar_port_tmux.sh'
    source '$REPO_ROOT/scripts/lib/sidebar_subpane_hub.sh'
    ensure_sidebar_subpane_window '$win3' '$s3_bar'
" 2>/dev/null || true

sub_count_after="$(tmux -L "$TEST_SOCKET" list-panes -t "$win3" \
    -F '#{@dotfiles_sidebar_subpane}' | grep -c '1' || true)"

echo "    Focus was on: work pane ($m3), NOT sidebar ($s3_bar)"
echo "    Subpane slots provisioned=${sub_count_after:-0} (expected 0)"

if [ "${sub_count_after:-0}" -gt 0 ]; then
    report FAIL "2: Subpane entry blocked when sidebar has no focus" \
        "Provisioned $sub_count_after despite work pane focus"
else
    report PASS "2: Subpane entry blocked when sidebar has no focus"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=========================================================================="
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
echo "=========================================================================="
exit $FAIL
