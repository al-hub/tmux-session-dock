#!/usr/bin/env bash
# Presenter & Screen Rendering Module
set -euo pipefail

sidebar_presenter_map_key() {
    local key="$1"
    case "$key" in
        q|Q|$'\x03') echo "QUIT" ;;
        s) echo "TOGGLE" ;;
        S) echo "CONFIG_SUBPANE" ;;
        j|J|$'\x0e') echo "DOWN" ;;
        k|K|$'\x10') echo "UP" ;;
        o|O|$'\t') echo "HISTORY" ;;
        c|C|'+') echo "CREATE" ;;
        r|R|$'\x12') echo "RENAME" ;;
        d|D|$'\x04'|$'\x7f'|$'\x08') echo "DELETE" ;;
        p|P) echo "SWAP_POSITION" ;;
        a|A) echo "MARK_ALL" ;;
        h|H|\?) echo "HELP" ;;
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
