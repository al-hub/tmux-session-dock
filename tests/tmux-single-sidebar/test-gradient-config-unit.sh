#!/usr/bin/env bash
# Unit: the gradient's two clocks derive from one user-facing number.
#
# The wave has 24 phases. The user configures the cycle length in milliseconds;
# the frame clock (microseconds, used for the phase) and the presenter's read
# timeout (seconds) must both come from it, or the loop wakes at a rate the
# frame clock does not match.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/sidebar_domain_animation.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

check() {
    local input="$1" want_cycle="$2" want_frame="$3" want_interval="$4"
    sidebar_domain_animation_timing "$input"
    [ "$sidebar_animation_timing_cycle_ms" = "$want_cycle" ] ||
        fail "cycle for '$input' was $sidebar_animation_timing_cycle_ms, expected $want_cycle"
    [ "$sidebar_animation_timing_frame_us" = "$want_frame" ] ||
        fail "frame_us for '$input' was $sidebar_animation_timing_frame_us, expected $want_frame"
    [ "$sidebar_animation_timing_interval" = "$want_interval" ] ||
        fail "interval for '$input' was $sidebar_animation_timing_interval, expected $want_interval"
}

# --- the documented default and its neighbours -------------------------------
check 1000 1000 41666 0.041666
check 2000 2000 83333 0.083333
check 500   500 20833 0.020833
printf 'PASS: a cycle in ms yields the frame clock and the read timeout\n'

# --- unusable values fall back to the default --------------------------------
for bad in "" abc 12ms -500 " "; do
    sidebar_domain_animation_timing "$bad"
    [ "$sidebar_animation_timing_cycle_ms" = "$SIDEBAR_ANIMATION_CYCLE_MS_DEFAULT" ] ||
        fail "'$bad' should fall back to the default, got $sidebar_animation_timing_cycle_ms"
done
printf 'PASS: an unusable value falls back to the default cycle\n'

# --- out of range is clamped, never refused ----------------------------------
check 1 "$SIDEBAR_ANIMATION_CYCLE_MS_MIN" 16666 0.016666
check 399 "$SIDEBAR_ANIMATION_CYCLE_MS_MIN" 16666 0.016666
check 99999 "$SIDEBAR_ANIMATION_CYCLE_MS_MAX" 166666 0.166666
printf 'PASS: values outside the range are clamped to it\n'

# --- the two clocks agree at every step in the range -------------------------
for ms in 400 617 1000 1333 2500 4000; do
    sidebar_domain_animation_timing "$ms"
    frame="$sidebar_animation_timing_frame_us"
    # interval is the frame clock expressed in seconds
    seconds="${sidebar_animation_timing_interval%%.*}"
    micros="${sidebar_animation_timing_interval#*.}"
    micros="${micros#"${micros%%[!0]*}"}"
    [ -n "$micros" ] || micros=0
    [ $(( seconds * 1000000 + micros )) -eq "$frame" ] ||
        fail "interval $sidebar_animation_timing_interval does not equal frame_us $frame at ${ms}ms"
    # 24 frames must span the requested cycle, within rounding
    span=$(( frame * SIDEBAR_ANIMATION_PHASES / 1000 ))
    [ $(( ms - span )) -le 1 ] && [ $(( ms - span )) -ge 0 ] ||
        fail "24 frames span ${span}ms, expected ${ms}ms"
done
printf 'PASS: the read timeout and the frame clock stay in step across the range\n'
