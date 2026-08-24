#!/usr/bin/env bash
# Presenter & Screen Rendering Module
set -euo pipefail

sidebar_presenter_map_key() {
    local key="$1"
    case "$key" in
        q|Q|ㅂ|ᄇ|$'\x03') echo "QUIT" ;;
        s|S|ㄴ|ᄂ) echo "TOGGLE" ;;
        j|J|ㅓ|ᅥ|$'\x0e') echo "DOWN" ;;
        k|K|ㅏ|ᅡ|$'\x10') echo "UP" ;;
        o|O|ㅐ|ᅢ|ㅒ|ᅤ|$'\t') echo "HISTORY" ;;
        c|C|ㅊ|ᄎ|'+') echo "CREATE" ;;
        r|R|ㄱ|ᄀ|$'\x12') echo "RENAME" ;;
        d|D|ㅇ|ᄋ|$'\x04'|$'\x7f'|$'\x08') echo "DELETE" ;;
        p|P|ㅔ|ᅦ|ㅖ|ᅨ) echo "SWAP_POSITION" ;;
        a|A|ㅁ|ᄆ) echo "MARK_ALL" ;;
        h|H|ㅗ|ᅩ|\?) echo "HELP" ;;
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
