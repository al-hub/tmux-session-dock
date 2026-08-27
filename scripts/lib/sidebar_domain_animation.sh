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
