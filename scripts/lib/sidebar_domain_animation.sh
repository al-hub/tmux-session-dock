#!/usr/bin/env bash
# Pure domain terminal cell-width helpers for session name rendering in tmux-session-dock
# Zero external CLI dependencies, zero side-effects, fully unit testable
set -euo pipefail

sidebar_domain_animation_measure_cell_width() {
    local text="${1:-}"
    local total=0
    local len="${#text}"
    local i char w
    for ((i = 0; i < len; i++)); do
        char="${text:i:1}"
        case "$char" in
            [\ -~]|$'\t'|"") w=1 ;;
            *)
                if [[ "$char" == [ᄀ-ᇿ⺀-꓏가-힣豈-﫿！-｠￠-￦] ]] || \
                   [[ "$char" == [☀-➿㈀-㋿] ]] || \
                   [[ "$char" == [🀀-🫿𠀀-㓟] ]] || \
                   [[ "$char" == [🌀-🿽] ]]; then
                    w=2
                else
                    w=1
                fi
                ;;
        esac
        total=$((total + w))
    done
    printf '%d\n' "$total"
}

sidebar_domain_animation_fit_cell_width() {
    local text="${1:-}"
    local max_cells="${2:-30}"
    local out=""
    local cur_cells=0
    local len="${#text}"
    local i char w
    for ((i = 0; i < len; i++)); do
        char="${text:i:1}"
        case "$char" in
            [\ -~]|$'\t'|"") w=1 ;;
            *)
                if [[ "$char" == [ᄀ-ᇿ⺀-꓏가-힣豈-﫿！-｠￠-￦] ]] || \
                   [[ "$char" == [☀-➿㈀-㋿] ]] || \
                   [[ "$char" == [🀀-🫿𠀀-㓟] ]] || \
                   [[ "$char" == [🌀-🿽] ]]; then
                    w=2
                else
                    w=1
                fi
                ;;
        esac
        if [ $((cur_cells + w)) -gt "$max_cells" ]; then
            break
        fi
        out+="$char"
        cur_cells=$((cur_cells + w))
    done
    printf '%s\n' "$out"
}

# The gradient is a 24-phase wave. The user configures one number - how long a
# full cycle takes, in milliseconds - and both clocks derive from it: the frame
# clock the phase is computed against, and the read timeout that decides how
# often the presenter loop wakes. Deriving them together is the point: setting
# one without the other makes the loop wake at a rate the frame clock does not
# match, which either burns wakeups or drops frames.
#
# Results land in sidebar_animation_timing_{cycle_ms,frame_us,interval}.
SIDEBAR_ANIMATION_PHASES=24
SIDEBAR_ANIMATION_CYCLE_MS_MIN=400
SIDEBAR_ANIMATION_CYCLE_MS_MAX=4000
SIDEBAR_ANIMATION_CYCLE_MS_DEFAULT=1000

sidebar_animation_timing_cycle_ms=0
sidebar_animation_timing_frame_us=0
sidebar_animation_timing_interval=0

sidebar_domain_animation_timing() {
    local cycle_ms="${1:-}"
    case "$cycle_ms" in
        ''|*[!0-9]*) cycle_ms="$SIDEBAR_ANIMATION_CYCLE_MS_DEFAULT" ;;
    esac
    # A cycle faster than the floor costs more wakeups per second than the
    # gradient is worth; slower than the ceiling reads as a stalled wave.
    [ "$cycle_ms" -lt "$SIDEBAR_ANIMATION_CYCLE_MS_MIN" ] && cycle_ms="$SIDEBAR_ANIMATION_CYCLE_MS_MIN"
    [ "$cycle_ms" -gt "$SIDEBAR_ANIMATION_CYCLE_MS_MAX" ] && cycle_ms="$SIDEBAR_ANIMATION_CYCLE_MS_MAX"
    local frame_us=$(( cycle_ms * 1000 / SIDEBAR_ANIMATION_PHASES ))
    sidebar_animation_timing_cycle_ms="$cycle_ms"
    sidebar_animation_timing_frame_us="$frame_us"
    printf -v sidebar_animation_timing_interval '%d.%06d' \
        $(( frame_us / 1000000 )) $(( frame_us % 1000000 ))
}
