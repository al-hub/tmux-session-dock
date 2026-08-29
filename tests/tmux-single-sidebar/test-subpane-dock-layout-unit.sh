#!/usr/bin/env bash
# test-subpane-dock-layout-unit.sh — pure dock geometry (scripts/lib/sidebar_domain.sh)
# sidebar_domain_dock_layout / _budget / _border_edge / layout_checksum, no tmux.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/scripts/lib/sidebar_domain.sh"

fail() { echo "FAIL: $*"; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }
WORK='85x40,35,0,0'
ROOT="120x40,0,0{34x40,0,0,1,$WORK}"
dock() { sidebar_domain_dock_layout "$@"; }

echo "=== [1/7] border edge ==="
eq "top" "$(sidebar_domain_dock_border_edge top)" top
eq "bottom" "$(sidebar_domain_dock_border_edge bottom)" bottom
eq "off" "$(sidebar_domain_dock_border_edge off)" none
eq "empty" "$(sidebar_domain_dock_border_edge '')" none

echo "=== [2/7] checksum matches tmux ==="
eq "checksum" "$(sidebar_domain_layout_checksum '120x40,0,0,0')" 'aafd,120x40,0,0,0'
eq "body strip" "$(sidebar_domain_layout_body 'aafd,120x40,0,0,0')" '120x40,0,0,0'

echo "=== [3/7] one slot, every position/edge combination ==="
eq "bottom/none" "$(dock "$ROOT" 34 bottom none 12)" "120x40,0,0{34x40,0,0[34x27,0,0,0,34x12,0,28,0],$WORK}"
eq "top/top (slot charged)" "$(dock "$ROOT" 34 top top 12)" "120x40,0,0{34x40,0,0[34x13,0,0,0,34x26,0,14,0],$WORK}"
eq "top/none" "$(dock "$ROOT" 34 top none 12)" "120x40,0,0{34x40,0,0[34x12,0,0,0,34x27,0,13,0],$WORK}"
eq "bottom/bottom (slot charged)" "$(dock "$ROOT" 34 bottom bottom 12)" "120x40,0,0{34x40,0,0[34x26,0,0,0,34x13,0,27,0],$WORK}"
eq "bottom/top == bottom/none (sidebar absorbs)" "$(dock "$ROOT" 34 bottom top 12)" "$(dock "$ROOT" 34 bottom none 12)"

echo "=== [4/7] stacks: 2, 3 and 4 slots (N-agnostic) ==="
eq "2 bottom/none 8,11" "$(dock "$ROOT" 34 bottom none 8 11)" "120x40,0,0{34x40,0,0[34x19,0,0,0,34x8,0,20,0,34x11,0,29,0],$WORK}"
eq "3 top/top 4,5,6" "$(dock "$ROOT" 34 top top 4 5 6)" "120x40,0,0{34x40,0,0[34x5,0,0,0,34x5,0,6,0,34x6,0,12,0,34x21,0,19,0],$WORK}"
eq "3 bottom/none 4,5,6" "$(dock "$ROOT" 34 bottom none 4 5 6)" "120x40,0,0{34x40,0,0[34x22,0,0,0,34x4,0,23,0,34x5,0,28,0,34x6,0,34,0],$WORK}"
eq "4 bottom/none 4x4 -> sidebar 20" "$(dock "$ROOT" 34 bottom none 4 4 4 4)" "120x40,0,0{34x40,0,0[34x20,0,0,0,34x4,0,21,0,34x4,0,26,0,34x4,0,31,0,34x4,0,36,0],$WORK}"
eq "checksum prefix accepted" "$(dock "$(sidebar_domain_layout_checksum "$ROOT")" 34 bottom none 12)" "$(dock "$ROOT" 34 bottom none 12)"

echo "=== [5/7] the work subtree is kept byte-verbatim; dock children are replaced ==="
NESTED='85x40,35,0[85x20,35,0,2,85x19,35,21,3]'
eq "nested work" "$(dock "120x40,0,0{34x40,0,0,1,$NESTED}" 34 bottom none 12)" "120x40,0,0{34x40,0,0[34x27,0,0,0,34x12,0,28,0],$NESTED}"
TWO='42x40,35,0,2,42x40,78,0,3'
eq "two work siblings" "$(dock "120x40,0,0{34x40,0,0,1,$TWO}" 34 bottom none 12)" "120x40,0,0{34x40,0,0[34x27,0,0,0,34x12,0,28,0],$TWO}"
DEEP='85x40,35,0[85x26,35,0{54x26,35,0,0,30x26,90,0,6},85x13,35,27,2]'
eq "deep nested work" "$(dock "120x40,0,0{34x40,0,0,1,$DEEP}" 34 top none 5)" "120x40,0,0{34x40,0,0[34x5,0,0,0,34x34,0,6,0],$DEEP}"
eq "dock with children rebuilt" "$(dock "120x40,0,0{34x40,0,0[34x20,0,0,1,34x19,0,21,4],$WORK}" 34 bottom none 12)" "120x40,0,0{34x40,0,0[34x27,0,0,0,34x12,0,28,0],$WORK}"
eq "dock with 3 children -> 1 slot" "$(dock "120x40,0,0{34x40,0,0[34x5,0,0,7,34x5,0,6,8,34x28,0,12,1],$WORK}" 34 bottom none 12)" "120x40,0,0{34x40,0,0[34x27,0,0,0,34x12,0,28,0],$WORK}"

echo "=== [6/7] budget policy ==="
eq "24 rows top/top 10,10,10 -> 6 4 4" "$(sidebar_domain_dock_budget 24 top top 10 10 10 | paste -sd ' ')" "6 4 4"
eq "below-minimum request is raised to 4" "$(sidebar_domain_dock_budget 40 bottom none 2 3 | paste -sd ' ')" "4 4"
eq "fits: unchanged" "$(sidebar_domain_dock_budget 40 bottom none 8 11 | paste -sd ' ')" "8 11"
out="$(sidebar_domain_dock_budget 12 top top 4 4 4)" && fail "12 rows / 3 slots must be rc 2" || eq "12 rows rc" "$?" 2
[ -z "$out" ] || fail "12 rows must print nothing"
eq "20 rows top/top 4,4,4 -> sidebar 4 (soft floor breached, still emitted)" "$(dock "120x20,0,0{34x20,0,0,1,85x20,35,0,0}" 34 top top 4 4 4)" "120x20,0,0{34x20,0,0[34x5,0,0,0,34x4,0,6,0,34x4,0,11,0,34x4,0,16,0],85x20,35,0,0}"
dock "120x12,0,0{34x12,0,0,1,85x12,35,0,0}" 34 top top 4 4 4 >/dev/null && fail "budget rc must propagate" || eq "layout budget rc" "$?" 2

echo "=== [7/7] not a dock window -> rc 1 ==="
for bad in '120x40,0,0[34x20,0,0,1,120x19,0,21,0]' '120x40,0,0{30x40,0,0,1,89x40,31,0,0}' '120x40,0,0{85x40,0,0,0,34x40,86,0,1}' '120x40,0,0,1' '120x40,0,0{34x40,0,0,1}' 'garbage'; do
    dock "$bad" 34 bottom none 12 >/dev/null 2>&1 && fail "must reject [$bad]" || eq "reject rc [$bad]" "$?" 1
done

echo "PASS: dock layout unit tests"
