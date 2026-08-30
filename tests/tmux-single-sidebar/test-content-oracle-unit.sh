#!/usr/bin/env bash
# Unit: the frame the dock draws is a frame the switch recognises.
#
# A session switch is only complete once the target presenter has drawn a frame
# for the target session, and that is judged by reading the pane back as text.
# The header and the mark column are therefore an implicit contract between the
# renderer and the switch - one that has been broken twice by drawing more into
# them (a count of waiting sessions, and the awaiting glyph), each time leaving
# every switch to abort as "sidebar content is not ready".
#
# This pins the contract: every mark row_mark_value can emit, and every header
# render_header can emit, must be recognised.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"

for lib in "$REPO_ROOT"/scripts/lib/sidebar_*.sh; do
    # shellcheck disable=SC1090
    [ -r "$lib" ] && source "$lib"
done
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$LAUNCHER") 2>/dev/null || true
declare -f sidebar_content_matches >/dev/null || { printf 'FAIL: sidebar_content_matches not loaded\n' >&2; exit 2; }
declare -f row_mark_value >/dev/null || { printf 'FAIL: row_mark_value not loaded\n' >&2; exit 2; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Ask the renderer itself for a mark, exactly as format_row does.
mark_for_case() {   # mark_for_case <is_selected> <is_current> <is_awaiting>
    declare -ga session_names=(target)
    declare -ga session_awaiting=("$3")
    selected_index=-1; [ "$1" = true ] && selected_index=0
    current_session=''; [ "$2" = true ] && current_session=target
    sidebar_awaiting_enabled=true
    sidebar_awaiting_blink_ms=0            # steady glyph, not mid-blink
    row_mark_value 0
    printf '%s' "$row_mark_result"
}

frame() { printf '%s\n%s target      0:00:01:02\n   other       0:00:02:03\n' "$1" "$2"; }

# --- every mark the renderer can draw ----------------------------------------
checked=0
for selected in true false; do
    for current in true false; do
        for awaiting in true false; do
            [ "$current" = true ] && [ "$awaiting" = true ] && continue  # cannot co-occur
            mark="$(mark_for_case "$selected" "$current" "$awaiting")"
            [ "${#mark}" -eq 2 ] ||
                fail "mark for selected=$selected current=$current awaiting=$awaiting is ${#mark} columns, not 2: '$mark'"
            for header in 'sessions' 'sessions · 1 awaiting' 'sessions · 12 awaiting'; do
                sidebar_content_matches "$(frame "$header" "$mark")" target ||
                    fail "an unrecognised frame: header='$header' mark='$mark' (selected=$selected current=$current awaiting=$awaiting)"
                checked=$((checked + 1))
            done
        done
    done
done
printf 'PASS: %d frames the renderer can draw are all recognised\n' "$checked"

# --- the blinking mark, mid-blink, is still a valid frame --------------------
declare -ga session_names=(target) session_awaiting=(true)
selected_index=0; current_session=''
sidebar_awaiting_enabled=true; sidebar_awaiting_blink_ms=-1
for phase in on off; do
    awaiting_blink_phase="$phase"
    row_mark_value 0
    sidebar_content_matches "$(frame 'sessions · 1 awaiting' "$row_mark_result")" target ||
        fail "the blinking mark is unrecognised in phase '$phase': '$row_mark_result'"
done
printf 'PASS: both halves of the blink cycle are recognised\n'

# --- and it still rejects a frame that has not settled -----------------------
sidebar_content_matches "$(printf 'sessions\n   other   0:00:01:02\n')" target &&
    fail 'a frame without the session was accepted'
sidebar_content_matches "$(printf 'loading\n>* target  0:00:01:02\n')" target &&
    fail 'a frame with no dock header was accepted'
printf 'PASS: a frame missing the session or the header is still rejected\n'

# --- the frames above are hand-written; these are the renderer's own ----------
#
# The sections above assemble a frame by hand and only ask the renderer for the
# mark. That leaves the rest of the row outside the contract - in particular the
# name cell, which the renderer TRUNCATES to fit the dock while the switch looks
# for the whole session name. So the frame is built here the way the presenter
# builds it: render_header for line 1, format_row for every row, ANSI stripped
# exactly as capture-pane -p hands the text to the switch.

# A CSI sequence: parameters, then intermediates 0x20-0x2F, then one final
# byte. The bracket must not be written [ -\/]: that is the range 0x20-0x5C,
# which swallows the final byte and then eats real text behind it.
strip_ansi() { sed -E 's|\x1B\[[0-9;?]*[ -/]*[@-~]||g'; }

# Draw the whole dock for the current session_* globals at the given width.
real_frame() {  # real_frame <pane_width>
    local index out
    cached_pane_width="$1"
    cached_pane_height=40
    scroll_offset=0
    out="$(render_header | strip_ansi)"
    for index in "${!session_names[@]}"; do
        format_row "$index"
        out+=$'\n'"$(printf '%s' "$row_render_result" | strip_ansi)"
    done
    printf '%s\n' "$out"
}

# One dock holding every name, drawn at the default 34-column width.
declare -ga session_names=(
    ai
    seventeen-chars-x
    a-very-long-session-name-indeed
    한글세션이름아주아주길다
)
declare -ga session_created=($(( ${EPOCHSECONDS:-$(date +%s)} - 3662 )) $(( ${EPOCHSECONDS:-$(date +%s)} - 3662 )) $(( ${EPOCHSECONDS:-$(date +%s)} - 3662 )) $(( ${EPOCHSECONDS:-$(date +%s)} - 3662 )))
declare -ga session_awaiting=(false false false false)
declare -ga session_animate=(false false false false)
declare -ga session_animation_seed=(0 0 0 0)
declare -gA session_awaiting_since=()
sidebar_awaiting_enabled=true
sidebar_awaiting_blink_ms=0
awaiting_blink_phase=on
current_session=ai
_session_name_fit_cache=()

for width in 34 35 24; do
    for index in "${!session_names[@]}"; do
        selected_index="$index"
        name="${session_names[$index]}"
        row_name_cell_width "$width"
        sidebar_content_matches "$(real_frame "$width")" "$name" ||
            fail "the dock drew a frame for '$name' that the switch does not recognise (width=$width, name cell=$row_name_cell_width_result columns):
$(real_frame "$width" | sed 's/^/    /')"
    done
done
printf 'PASS: every name the dock can draw is recognised in the dock its renderer produces\n'

# A truncated row is only this session's row when what it shows is a prefix of
# this session's name; the loosened match must not accept any elided row.
sidebar_content_matches "$(printf 'sessions\n>  some-other-sessio…  0:00:01:02 \n')" a-very-long-session-name-indeed &&
    fail 'a truncated row for a different session was accepted'
sidebar_content_matches "$(printf 'sessions\n>  a-very-long-sessio   0:00:01:02 \n')" a-very-long-session-name-indeed &&
    fail 'a prefix without the ellipsis was accepted as a truncated row'
printf 'PASS: a truncated row that is not this session is still rejected\n'
