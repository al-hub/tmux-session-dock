#!/usr/bin/env bash
# Pure domain helpers for tmux-session-launcher with zero external side-effects or CLI dependencies
set -euo pipefail

sidebar_domain_sanitize_name() {
    local raw="${1:-}"
    local clean="${raw//[:. ]/_}"
    printf '%s\n' "$clean"
}

sidebar_domain_validate_archive_line() {
    local line="${1:-}"
    [[ "$line" =~ ^[0-9]+\|[^|]+\|[^|]+\|[0-9]+\|[0-9]+\|[^|]+\|[0-9]+\|[0-9]+\|[0-9]+\|[^|]*\|[0-9]+$ ]]
}

sidebar_domain_epoch_now() {
    if [ -n "${EPOCHSECONDS:-}" ]; then
        printf '%s\n' "$EPOCHSECONDS"
    else
        date +%s
    fi
}

sidebar_domain_format_duration() {
    local elapsed="${1:-0}"
    case "$elapsed" in
        ''|*[!0-9]*) elapsed=0 ;;
    esac
    local days=$((elapsed / 86400))
    local remain=$((elapsed % 86400))
    local hours=$((remain / 3600))
    remain=$((remain % 3600))
    local minutes=$((remain / 60))
    local seconds=$((remain % 60))
    printf '%d:%02d:%02d:%02d\n' "$days" "$hours" "$minutes" "$seconds"
}

sidebar_domain_session_age_value() {
    local -n _age_out_ref="$1"
    local created_value="${2:-}"
    local now_value
    now_value="$(sidebar_domain_epoch_now)"
    case "$created_value" in
        ''|*[!0-9]*) created_value="$now_value" ;;
    esac
    local duration_elapsed=$((now_value - created_value))
    [ "$duration_elapsed" -lt 0 ] && duration_elapsed=0
    _age_out_ref="$(sidebar_domain_format_duration "$duration_elapsed")"
}

sidebar_domain_layout_body() {
    local layout="${1:-}"
    case "$layout" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F],*) printf '%s\n' "${layout#*,}" ;;
        *) printf '%s\n' "$layout" ;;
    esac
}

# tmux layout checksum (layout_checksum in tmux/layout-custom.c): 16-bit
# rotate-right-and-add over the bytes of the body. select-layout rejects a
# body whose checksum is missing or wrong.
sidebar_domain_layout_checksum() {
    local body="$1"
    local checksum=0 bytes byte
    bytes="$(printf '%s' "$body" | od -An -tu1 -v)"
    for byte in $bytes; do
        checksum=$((((checksum >> 1) | ((checksum & 1) << 15))))
        checksum=$(((checksum + byte) & 65535))
    done
    printf '%04x,%s\n' "$checksum" "$body"
}

# ------------------------------------------------------------------------------
# Dock column geometry - pure functions.
#
# The dock column is the leftmost column of a window: the sidebar pane plus
# N Subpane Slots stacked above it (position top) or below it (bottom).
# Instead of joining slots with computed lengths and resizing afterwards, the
# builder joins them in order (any size) and declares the whole window once
# with `select-layout '<checksum>,<body>'`. tmux assigns leaves to panes in
# pane-list order, so order is the builder's job; geometry is this file's.
#
# Border rule: with `pane-border-status top`, tmux draws the status row inside
# the topmost cells - every leaf at y=0 renders one row shorter than its cell.
# `bottom` charges the bottom-edge cell instead; `off` charges nothing. The
# leaf on the charged edge is therefore written one row taller than the
# height it must render. The caller passes that edge (top|bottom|none).
# ------------------------------------------------------------------------------
SIDEBAR_DOCK_MIN_SLOT_ROWS=4
SIDEBAR_DOCK_MIN_SIDEBAR_ROWS=6

sidebar_domain_dock_border_edge() {
    case "${1:-}" in
        top|TOP) printf 'top\n' ;;
        bottom|BOTTOM) printf 'bottom\n' ;;
        *) printf 'none\n' ;;
    esac
}

# Which slot (1..N) carries the border charge, or 0 for none / the sidebar.
_sidebar_dock_charged_slot() {   # <position> <edge> <count>
    if [ "$1" = "top" ] && [ "$2" = "top" ]; then printf '1\n'
    elif [ "$1" != "top" ] && [ "$2" = "bottom" ]; then printf '%s\n' "$3"
    else printf '0\n'
    fi
}

# 1 when the sidebar sits on the charged edge (it then needs one extra row).
_sidebar_dock_sidebar_charged() {   # <position> <edge>
    if { [ "$1" != "top" ] && [ "$2" = "top" ]; } || { [ "$1" = "top" ] && [ "$2" = "bottom" ]; }; then
        printf '1\n'
    else
        printf '0\n'
    fi
}

# Fit the requested slot heights into <rows>. Prints one height per line.
# Policy: every slot >= SIDEBAR_DOCK_MIN_SLOT_ROWS; the sidebar keeps
# SIDEBAR_DOCK_MIN_SIDEBAR_ROWS (+1 when it is on the charged edge). Short:
# shrink slots from the last to the first, each down to the minimum. Still
# short: let the sidebar go down to 2 rows. Below that: rc 2, nothing printed.
sidebar_domain_dock_budget() {   # <rows> <position> <edge> <h1> [h2 ...]
    local rows="$1" position="$2" edge="$3"
    shift 3
    local -a heights=("$@")
    local count="${#heights[@]}"
    [ "$count" -gt 0 ] || return 2
    case "$rows" in ''|*[!0-9]*) return 2 ;; esac

    local i h charged sidebar_charged sum need avail deficit
    charged="$(_sidebar_dock_charged_slot "$position" "$edge" "$count")"
    sidebar_charged="$(_sidebar_dock_sidebar_charged "$position" "$edge")"
    for ((i = 0; i < count; i++)); do
        h="${heights[$i]}"
        case "$h" in ''|*[!0-9]*) h="$SIDEBAR_DOCK_MIN_SLOT_ROWS" ;; esac
        [ "$h" -ge "$SIDEBAR_DOCK_MIN_SLOT_ROWS" ] || h="$SIDEBAR_DOCK_MIN_SLOT_ROWS"
        heights[$i]="$h"
    done

    cells_sum() {
        local total=0 k
        for ((k = 0; k < count; k++)); do
            total=$((total + heights[k]))
        done
        [ "$charged" -gt 0 ] && total=$((total + 1))
        printf '%s\n' "$total"
    }

    need=$((SIDEBAR_DOCK_MIN_SIDEBAR_ROWS + sidebar_charged))
    avail=$((rows - count - $(cells_sum)))
    if [ "$avail" -lt "$need" ]; then
        deficit=$((need - avail))
        for ((i = count - 1; i >= 0 && deficit > 0; i--)); do
            local room=$((heights[i] - SIDEBAR_DOCK_MIN_SLOT_ROWS))
            [ "$room" -gt 0 ] || continue
            if [ "$room" -ge "$deficit" ]; then
                heights[$i]=$((heights[i] - deficit)); deficit=0
            else
                heights[$i]="$SIDEBAR_DOCK_MIN_SLOT_ROWS"; deficit=$((deficit - room))
            fi
        done
        avail=$((rows - count - $(cells_sum)))
        [ "$avail" -ge $((2 + sidebar_charged)) ] || return 2
    fi
    printf '%s\n' "${heights[@]}"
}

# Rewrite a window layout so that the dock column (first child of the root
# left-to-right split, at x=0, <dock_width> wide) becomes
# [sidebar, slots...] (bottom) or [slots..., sidebar] (top) with the given
# rendered heights; the work subtree to its right is kept byte-verbatim.
# Prints the body without checksum. rc 1: not a dock window; rc 2: budget.
sidebar_domain_dock_layout() {   # <window_layout> <dock_width> <position> <edge> <h1> [h2 ...]
    local layout="$1" dock_width="$2" position="$3" edge="$4"
    shift 4
    local body width rows inner tail rest
    body="$(sidebar_domain_layout_body "$layout")"
    [[ $body =~ ^([0-9]+)x([0-9]+),0,0\{(.*)\}$ ]] || return 1
    width="${BASH_REMATCH[1]}"; rows="${BASH_REMATCH[2]}"; inner="${BASH_REMATCH[3]}"
    [[ $inner =~ ^([0-9]+)x([0-9]+),0,0(.*)$ ]] || return 1
    [ "${BASH_REMATCH[1]}" = "$dock_width" ] || return 1
    [ "${BASH_REMATCH[2]}" = "$rows" ] || return 1
    tail="${BASH_REMATCH[3]}"
    case "$tail" in
        ,*)
            # The dock is a bare sidebar leaf: ",<id>,<siblings>"
            [[ $tail =~ ^,[0-9]+,(.*)$ ]] || return 1
            rest="${BASH_REMATCH[1]}"
            ;;
        \[*|\{*)
            # The dock already has children: skip its balanced subtree.
            local depth=0 pos=0 ch
            while [ "$pos" -lt "${#tail}" ]; do
                ch="${tail:$pos:1}"
                case "$ch" in
                    \[|\{) depth=$((depth + 1)) ;;
                    \]|\}) depth=$((depth - 1)) ;;
                esac
                pos=$((pos + 1))
                [ "$depth" -eq 0 ] && break
            done
            [ "$depth" -eq 0 ] || return 1
            [ "${tail:$pos:1}" = "," ] || return 1
            rest="${tail:$((pos + 1))}"
            ;;
        *) return 1 ;;
    esac
    [ -n "$rest" ] || return 1

    local -a heights=()
    mapfile -t heights < <(sidebar_domain_dock_budget "$rows" "$position" "$edge" "$@") || return 2
    [ "${#heights[@]}" -gt 0 ] || return 2
    local count="${#heights[@]}" charged cells_sum=0 i cell sidebar_cell y=0
    local -a cells=() children=()
    charged="$(_sidebar_dock_charged_slot "$position" "$edge" "$count")"
    for ((i = 0; i < count; i++)); do
        cell="${heights[$i]}"
        [ "$((i + 1))" -eq "$charged" ] && cell=$((cell + 1))
        cells[$i]="$cell"
        cells_sum=$((cells_sum + cell))
    done
    sidebar_cell=$((rows - count - cells_sum))
    [ "$sidebar_cell" -ge 1 ] || return 2

    add_leaf() { children+=("${dock_width}x${1},0,${y},0"); y=$((y + $1 + 1)); }
    if [ "$position" = "top" ]; then
        for ((i = 0; i < count; i++)); do add_leaf "${cells[$i]}"; done
        add_leaf "$sidebar_cell"
    else
        add_leaf "$sidebar_cell"
        for ((i = 0; i < count; i++)); do add_leaf "${cells[$i]}"; done
    fi
    local joined
    joined="$(IFS=,; printf '%s' "${children[*]}")"
    printf '%sx%s,0,0{%sx%s,0,0[%s],%s}\n' "$width" "$rows" "$dock_width" "$rows" "$joined" "$rest"
}
SIDEBAR_SUBPANE_OPTION="@dotfiles_sidebar_subpane_enabled"
SIDEBAR_SUBPANE_HEIGHT_OPTION="@dotfiles_sidebar_subpane_height"
SIDEBAR_SUBPANE_POSITION_OPTION="@dotfiles_sidebar_subpane_position"
SIDEBAR_SUBPANE_ENABLED_STATE_FILE="${TMUX_SESSION_SIDEBAR_SUBPANE_ENABLED_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/tmux-sidebar-subpane-enabled}"
SIDEBAR_SUBPANE_HEIGHT_STATE_FILE="${TMUX_SESSION_SIDEBAR_SUBPANE_HEIGHT_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/tmux-sidebar-subpane-height}"
SIDEBAR_SUBPANE_POSITION_STATE_FILE="${TMUX_SESSION_SIDEBAR_SUBPANE_POSITION_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/tmux-sidebar-subpane-position}"

sidebar_subpane_title() {
    printf '%s\n' "${SIDEBAR_SUBPANE_TITLE:-dotfiles-sidebar-subpane}"
}

sidebar_subpane_height_option() {
    printf '%s\n' "${SIDEBAR_SUBPANE_HEIGHT_OPTION:-@dotfiles_sidebar_subpane_height}"
}

sidebar_subpane_position_option() {
    printf '%s\n' "${SIDEBAR_SUBPANE_POSITION_OPTION:-@dotfiles_sidebar_subpane_position}"
}

is_sidebar_subpane() {
    local title="${1:-}"
    [ "$title" = "${SIDEBAR_SUBPANE_TITLE:-dotfiles-sidebar-subpane}" ]
}

sidebar_subpane_default_height() {
    local total="${1:-0}"
    case "$total" in
        ''|*[!0-9]*) total=0 ;;
    esac
    local h=$((total * 30 / 100))
    if [ "$h" -lt 8 ]; then
        h=8
    elif [ "$h" -gt 25 ]; then
        h=25
    fi
    printf '%d\n' "$h"
}

is_infrastructure_session() {
    local session="${1:-}"
    case "$session" in
        dotfiles-subpane-hub) return 0 ;;
        *) return 1 ;;
    esac
}
