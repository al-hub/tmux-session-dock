#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/scripts/lib/sidebar_domain.sh"
source "$SCRIPT_DIR/scripts/lib/sidebar_port_tmux.sh"

[ "$(sidebar_subpane_title)" = "dotfiles-sidebar-subpane" ] || { echo "FAIL title"; exit 1; }
is_sidebar_subpane "dotfiles-sidebar-subpane" || { echo "FAIL is_sidebar_subpane"; exit 1; }
! is_sidebar_subpane "dotfiles-session-sidebar" || { echo "FAIL not main sidebar"; exit 1; }
! is_sidebar_subpane "zsh" || { echo "FAIL not work pane"; exit 1; }

[ "$(sidebar_subpane_default_height 60)" = "18" ] || { echo "FAIL height 60"; exit 1; }
[ "$(sidebar_subpane_default_height 20)" = "8" ] || { echo "FAIL height 20 min"; exit 1; }
[ "$(sidebar_subpane_calc_join_length bottom 12)" = "12" ] || { echo "FAIL bottom join length"; exit 1; }
[ "$(sidebar_subpane_calc_join_length top 12)" = "13" ] || { echo "FAIL top join border correction"; exit 1; }
[ "$(sidebar_subpane_calc_join_length top invalid)" = "13" ] || { echo "FAIL default top join length"; exit 1; }

echo "PASS: subpane unit tests"
