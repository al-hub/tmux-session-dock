#!/usr/bin/env bash
# Unit tests for the terminal cell-width helpers in scripts/lib/sidebar_domain_animation.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/sidebar_domain_animation.sh"

pass_count=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL: %s (expected: [%s], got: [%s])\n' "$msg" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$msg"
    pass_count=$((pass_count + 1))
}

echo "=== Running Animation Cell Width Unit Tests ==="

# measure_cell_width: ASCII is 1 cell, Hangul / CJK / emoji are 2 cells
assert_eq "5" "$(sidebar_domain_animation_measure_cell_width "alpha")" "ASCII 'alpha' measures 5 cells"
assert_eq "0" "$(sidebar_domain_animation_measure_cell_width "")" "empty string measures 0 cells"
# '세'(2) '션'(2) '-'(1) '1'(1)
assert_eq "6" "$(sidebar_domain_animation_measure_cell_width "세션-1")" "Hangul '세션-1' measures 6 cells"
# '🚀'(2) + 'ai-worker'(9)
assert_eq "11" "$(sidebar_domain_animation_measure_cell_width "🚀ai-worker")" "Emoji '🚀ai-worker' measures 11 cells"
assert_eq "4" "$(sidebar_domain_animation_measure_cell_width "🚀ai")" "Emoji '🚀ai' measures 4 cells"

# fit_cell_width: truncates on glyph boundaries, never splits a 2-cell glyph
assert_eq "alpha" "$(sidebar_domain_animation_fit_cell_width "alpha" 8)" "fit keeps a name that already fits"
assert_eq "alp" "$(sidebar_domain_animation_fit_cell_width "alpha" 3)" "fit truncates ASCII to the cell budget"
assert_eq "세" "$(sidebar_domain_animation_fit_cell_width "세션-1" 3)" "fit does not slice 2-cell Hangul mid-glyph"
assert_eq "세션" "$(sidebar_domain_animation_fit_cell_width "세션-1" 4)" "fit fills an even Hangul budget exactly"
assert_eq "🚀ai" "$(sidebar_domain_animation_fit_cell_width "🚀ai-worker" 4)" "fit does not slice 2-cell Emoji mid-glyph"
assert_eq "🚀ai-" "$(sidebar_domain_animation_fit_cell_width "🚀ai-worker" 5)" "fit fits exact 5 cells for emoji prefix"
assert_eq "" "$(sidebar_domain_animation_fit_cell_width "세션" 1)" "fit yields empty when the first glyph does not fit"

# fit then measure round-trips within the budget
fitted="$(sidebar_domain_animation_fit_cell_width "세션-1-🚀-long-name" 9)"
width="$(sidebar_domain_animation_measure_cell_width "$fitted")"
[ "$width" -le 9 ] || { printf 'FAIL: fitted width %s exceeds budget 9\n' "$width" >&2; exit 1; }
assert_eq "세션-1-🚀" "$fitted" "fit of mixed-width name stops before the glyph that would overflow"

echo "=== All $pass_count Animation Cell Width Unit Tests Passed ==="
