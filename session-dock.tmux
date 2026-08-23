#!/usr/bin/env bash
# ==============================================================================
# session-dock.tmux - TPM (Tmux Plugin Manager) Entry Point
# ==============================================================================
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_PATH="$CURRENT_DIR/dist/tmux-session-dock"
[ -x "$BIN_PATH" ] || BIN_PATH="$CURRENT_DIR/bin/tmux-session-dock"

get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local option_value
    option_value="$(tmux show-option -gqv "$option")"
    if [ -z "$option_value" ]; then
        echo "$default_value"
    else
        echo "$option_value"
    fi
}

# 0. Batteries-Included Ergonomics Preset
DOTFILES_MODE="$(get_tmux_option "@session-dock-dotfiles-mode" "off")"
ERGONOMICS_MODE="$(get_tmux_option "@session-dock-ergonomics" "$DOTFILES_MODE")"

if [ "$ERGONOMICS_MODE" = "on" ] || [ "$ERGONOMICS_MODE" = "1" ] || [ "$ERGONOMICS_MODE" = "full" ]; then
    if [ -f "$CURRENT_DIR/presets/dotfiles-tmux.conf" ]; then
        tmux source-file "$CURRENT_DIR/presets/dotfiles-tmux.conf" 2>/dev/null || true
    fi
fi

# 1. Option Parsing & Defaults
TOGGLE_KEY="$(get_tmux_option "@session-dock-key" "s")"
SUBPANE_KEY="$(get_tmux_option "@session-dock-subpane-key" "P")"
THEME_KEY="$(get_tmux_option "@session-dock-theme-key" "T")"
HELP_KEY="$(get_tmux_option "@session-dock-help-key" "h")"
PALETTE_KEY="$(get_tmux_option "@session-dock-palette-key" "/")"
DEFAULT_WIDTH="$(get_tmux_option "@session-dock-width" "34")"
SUBPANE_POS="$(get_tmux_option "@session-dock-subpane-position" "bottom")"

# 2. Keybindings Registration
tmux bind-key -N "🗂️ Toggle Session Dock" "$TOGGLE_KEY" run-shell "$BIN_PATH --toggle-sidebar" 2>/dev/null || tmux bind-key "$TOGGLE_KEY" run-shell "$BIN_PATH --toggle-sidebar" 2>/dev/null || true
tmux bind-key -N "🔄 Swap Subpane Position (Top/Bottom)" "$SUBPANE_KEY" run-shell "$BIN_PATH --swap-subpane-position" 2>/dev/null || tmux bind-key "$SUBPANE_KEY" run-shell "$BIN_PATH --swap-subpane-position" 2>/dev/null || true
tmux bind-key -N "🎨 Session Dock Theme Picker" "$THEME_KEY" display-popup -E -w 75% -h 65% "$CURRENT_DIR/scripts/tmux-theme-picker" 2>/dev/null || tmux bind-key "$THEME_KEY" display-popup -E -w 75% -h 65% "$CURRENT_DIR/scripts/tmux-theme-picker" 2>/dev/null || true
tmux bind-key -N "📖 Session Dock Interactive Help" "$HELP_KEY" display-popup -E -w 70% -h 65% "$CURRENT_DIR/scripts/tmux-help-viewer" 2>/dev/null || tmux bind-key "$HELP_KEY" display-popup -E -w 70% -h 65% "$CURRENT_DIR/scripts/tmux-help-viewer" 2>/dev/null || true
tmux bind-key -N "⌨️ Session Dock Command Palette" "$PALETTE_KEY" display-popup -E -w 70% -h 60% "env TMUX_PANE='#{pane_id}' $CURRENT_DIR/scripts/tmux-command-palette" 2>/dev/null || tmux bind-key "$PALETTE_KEY" display-popup -E -w 70% -h 60% "env TMUX_PANE='#{pane_id}' $CURRENT_DIR/scripts/tmux-command-palette" 2>/dev/null || true

# 3. Work-Pane Safe Split Wrappers
tmux bind-key -N "✂️ Safe Horizontal Split" "|" run-shell "$BIN_PATH --split-horizontal" 2>/dev/null || tmux bind-key "|" run-shell "$BIN_PATH --split-horizontal" 2>/dev/null || true
tmux bind-key -N "✂️ Safe Vertical Split" "_" run-shell "$BIN_PATH --split-vertical" 2>/dev/null || tmux bind-key "_" run-shell "$BIN_PATH --split-vertical" 2>/dev/null || true
tmux bind-key -N "✂️ Safe Horizontal Split (Default)" "%" run-shell "$BIN_PATH --split-horizontal" 2>/dev/null || tmux bind-key "%" run-shell "$BIN_PATH --split-horizontal" 2>/dev/null || true
tmux bind-key -N "✂️ Safe Vertical Split (Default)" '"' run-shell "$BIN_PATH --split-vertical" 2>/dev/null || tmux bind-key '"' run-shell "$BIN_PATH --split-vertical" 2>/dev/null || true
