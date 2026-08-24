#!/usr/bin/env bash
# Presenter & Screen Rendering Module
set -euo pipefail

sidebar_presenter_map_key() {
    local key="$1"
    case "$key" in
        q|Q|ㅂ) echo "QUIT" ;;
        s|S|ㄴ) echo "TOGGLE" ;;
        j|J|ㅓ) echo "DOWN" ;;
        k|K|ㅏ) echo "UP" ;;
        o|O|ㅐ|ㅒ) echo "HISTORY" ;;
        c|C|ㅊ) echo "CREATE" ;;
        r|R|ㄱ) echo "RENAME" ;;
        d|D|ㅇ) echo "DELETE" ;;
        p|P|ㅔ|ㅖ) echo "SWAP_POSITION" ;;
        a|A|ㅁ) echo "MARK_ALL" ;;
        h|H|ㅗ|\?) echo "HELP" ;;
        *) echo "UNKNOWN" ;;
    esac
}

sidebar_presenter_render_header() {
    local title="$1" width="$2"
    printf "\033[1;36m%-*s\033[0m\n" "$width" "$title"
}

sidebar_presenter_render_footer() {
    local help_text="$1" width="$2"
    printf "\033[1;30m%-*s\033[0m\n" "$width" "$help_text"
}
