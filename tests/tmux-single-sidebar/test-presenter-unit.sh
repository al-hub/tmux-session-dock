#!/usr/bin/env bash
# Unit test for presenter module in scripts/lib/sidebar_presenter.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/scripts/lib/sidebar_domain.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_presenter.sh"

key_action="$(sidebar_presenter_map_key "q")"
[ "$key_action" = "QUIT" ] || { echo "FAIL: map_key expected 'QUIT', got '$key_action'"; exit 1; }

# Test universal terminal control keys
[ "$(sidebar_presenter_map_key $'\t')" = "HISTORY" ] || { echo "FAIL: Tab expected HISTORY"; exit 1; }
[ "$(sidebar_presenter_map_key $'\x0e')" = "DOWN" ] || { echo "FAIL: Ctrl-n expected DOWN"; exit 1; }
[ "$(sidebar_presenter_map_key $'\x10')" = "UP" ] || { echo "FAIL: Ctrl-p expected UP"; exit 1; }
[ "$(sidebar_presenter_map_key $'\x03')" = "QUIT" ] || { echo "FAIL: Ctrl-c expected QUIT"; exit 1; }
[ "$(sidebar_presenter_map_key $'\x04')" = "DELETE" ] || { echo "FAIL: Ctrl-d expected DELETE"; exit 1; }
[ "$(sidebar_presenter_map_key $'\x7f')" = "DELETE" ] || { echo "FAIL: Backspace expected DELETE"; exit 1; }
[ "$(sidebar_presenter_map_key $'\x12')" = "RENAME" ] || { echo "FAIL: Ctrl-r expected RENAME"; exit 1; }
[ "$(sidebar_presenter_map_key "+")" = "CREATE" ] || { echo "FAIL: + expected CREATE"; exit 1; }

echo "PASS: presenter unit tests"
