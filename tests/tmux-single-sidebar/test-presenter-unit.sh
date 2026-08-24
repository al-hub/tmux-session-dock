#!/usr/bin/env bash
# Unit test for presenter module in scripts/lib/sidebar_presenter.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/scripts/lib/sidebar_domain.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_presenter.sh"

key_action="$(sidebar_presenter_map_key "q")"
[ "$key_action" = "QUIT" ] || { echo "FAIL: map_key expected 'QUIT', got '$key_action'"; exit 1; }

# Test Korean 2-Set IME mappings
[ "$(sidebar_presenter_map_key "ㅂ")" = "QUIT" ] || { echo "FAIL: ㅂ expected QUIT"; exit 1; }
[ "$(sidebar_presenter_map_key "ㄴ")" = "TOGGLE" ] || { echo "FAIL: ㄴ expected TOGGLE"; exit 1; }
[ "$(sidebar_presenter_map_key "ㅓ")" = "DOWN" ] || { echo "FAIL: ㅓ expected DOWN"; exit 1; }
[ "$(sidebar_presenter_map_key "ㅏ")" = "UP" ] || { echo "FAIL: ㅏ expected UP"; exit 1; }
[ "$(sidebar_presenter_map_key "ㅐ")" = "HISTORY" ] || { echo "FAIL: ㅐ expected HISTORY"; exit 1; }
[ "$(sidebar_presenter_map_key "ㅒ")" = "HISTORY" ] || { echo "FAIL: ㅒ expected HISTORY"; exit 1; }
[ "$(sidebar_presenter_map_key "ㅊ")" = "CREATE" ] || { echo "FAIL: ㅊ expected CREATE"; exit 1; }
[ "$(sidebar_presenter_map_key "ㄱ")" = "RENAME" ] || { echo "FAIL: ㄱ expected RENAME"; exit 1; }
[ "$(sidebar_presenter_map_key "ㅇ")" = "DELETE" ] || { echo "FAIL: ㅇ expected DELETE"; exit 1; }
[ "$(sidebar_presenter_map_key "ㅔ")" = "SWAP_POSITION" ] || { echo "FAIL: ㅔ expected SWAP_POSITION"; exit 1; }
[ "$(sidebar_presenter_map_key "ㅖ")" = "SWAP_POSITION" ] || { echo "FAIL: ㅖ expected SWAP_POSITION"; exit 1; }
[ "$(sidebar_presenter_map_key "ㅁ")" = "MARK_ALL" ] || { echo "FAIL: ㅁ expected MARK_ALL"; exit 1; }
# Test NFD Korean IME mappings (macOS style)
[ "$(sidebar_presenter_map_key "ᄇ")" = "QUIT" ] || { echo "FAIL: ᄇ expected QUIT"; exit 1; }
[ "$(sidebar_presenter_map_key "ᄂ")" = "TOGGLE" ] || { echo "FAIL: ᄂ expected TOGGLE"; exit 1; }
[ "$(sidebar_presenter_map_key "ᅥ")" = "DOWN" ] || { echo "FAIL: ᅥ expected DOWN"; exit 1; }
[ "$(sidebar_presenter_map_key "ᅡ")" = "UP" ] || { echo "FAIL: ᅡ expected UP"; exit 1; }
[ "$(sidebar_presenter_map_key "ᅢ")" = "HISTORY" ] || { echo "FAIL: ᅢ expected HISTORY"; exit 1; }
[ "$(sidebar_presenter_map_key "ᅤ")" = "HISTORY" ] || { echo "FAIL: ᅤ expected HISTORY"; exit 1; }
[ "$(sidebar_presenter_map_key "ᄎ")" = "CREATE" ] || { echo "FAIL: ᄎ expected CREATE"; exit 1; }
[ "$(sidebar_presenter_map_key "ᄀ")" = "RENAME" ] || { echo "FAIL: ᄀ expected RENAME"; exit 1; }
[ "$(sidebar_presenter_map_key "ᄋ")" = "DELETE" ] || { echo "FAIL: ᄋ expected DELETE"; exit 1; }
[ "$(sidebar_presenter_map_key "ᅦ")" = "SWAP_POSITION" ] || { echo "FAIL: ᅦ expected SWAP_POSITION"; exit 1; }
[ "$(sidebar_presenter_map_key "ᅨ")" = "SWAP_POSITION" ] || { echo "FAIL: ᅨ expected SWAP_POSITION"; exit 1; }
[ "$(sidebar_presenter_map_key "ᄆ")" = "MARK_ALL" ] || { echo "FAIL: ᄆ expected MARK_ALL"; exit 1; }
[ "$(sidebar_presenter_map_key "ᅩ")" = "HELP" ] || { echo "FAIL: ᅩ expected HELP"; exit 1; }

echo "PASS: presenter unit tests"
