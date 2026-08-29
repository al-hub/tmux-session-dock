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

# 1. Theme Loading (Persistence & Defaults)
USER_THEME_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/theme.conf"
CONFIGURED_THEME="$(get_tmux_option "@session-dock-theme" "")"

if [ -f "$USER_THEME_CONF" ]; then
    tmux source-file "$USER_THEME_CONF" 2>/dev/null || true
elif [ -n "$CONFIGURED_THEME" ]; then
    THEME_SEARCH_DIRS=("${XDG_CONFIG_HOME:-$HOME/.config}/tmux/themes" "$CURRENT_DIR/themes")
    THEME_FILE=""
    for dir in "${THEME_SEARCH_DIRS[@]}"; do
        if [ -f "$dir/${CONFIGURED_THEME}.conf" ]; then
            THEME_FILE="$dir/${CONFIGURED_THEME}.conf"
            break
        elif [ -f "$dir/${CONFIGURED_THEME}" ]; then
            THEME_FILE="$dir/${CONFIGURED_THEME}"
            break
        else
            matched="$(find "$dir" -maxdepth 1 -name "*${CONFIGURED_THEME}*.conf" 2>/dev/null | head -n 1 || true)"
            if [ -n "$matched" ] && [ -f "$matched" ]; then
                THEME_FILE="$matched"
                break
            fi
        fi
    done
    if [ -n "$THEME_FILE" ] && [ -f "$THEME_FILE" ]; then
        tmux source-file "$THEME_FILE" 2>/dev/null || true
    fi
fi

# 2. Option Parsing & Defaults
TOGGLE_KEY="$(get_tmux_option "@session-dock-key" "s")"
QUICK_JUMP_KEY="$(get_tmux_option "@session-dock-quick-jump-key" "M-s")"
THEME_KEY="$(get_tmux_option "@session-dock-theme-key" "T")"
HELP_KEY="$(get_tmux_option "@session-dock-help-key" "h")"
PALETTE_KEY="$(get_tmux_option "@session-dock-palette-key" "/")"
DEFAULT_WIDTH="$(get_tmux_option "@session-dock-width" "34")"
SUBPANE_POS="$(get_tmux_option "@session-dock-subpane-position" "bottom")"

# Ensure UTF-8 locale for accurate key handling
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"

# 2. Keybindings Registration
tmux bind-key -n -N "⚡ Quick Jump to Session Dock" "$QUICK_JUMP_KEY" run-shell "$BIN_PATH --focus-sidebar" 2>/dev/null || tmux bind-key -n "$QUICK_JUMP_KEY" run-shell "$BIN_PATH --focus-sidebar" 2>/dev/null || true

tmux bind-key -N "🗂️ Toggle Session Dock" "$TOGGLE_KEY" run-shell "$BIN_PATH --toggle-sidebar" 2>/dev/null || tmux bind-key "$TOGGLE_KEY" run-shell "$BIN_PATH --toggle-sidebar" 2>/dev/null || true

tmux bind-key -N "⚙️ Session Dock Settings (Subpane Stack · IME)" "S" display-popup -E -w 70% -h 60% "$CURRENT_DIR/scripts/tmux-subpane-picker" 2>/dev/null || tmux bind-key "S" display-popup -E -w 70% -h 60% "$CURRENT_DIR/scripts/tmux-subpane-picker" 2>/dev/null || true

tmux bind-key -N "🎨 Session Dock Theme Picker" "$THEME_KEY" display-popup -E -w 75% -h 65% "$CURRENT_DIR/scripts/tmux-theme-picker" 2>/dev/null || tmux bind-key "$THEME_KEY" display-popup -E -w 75% -h 65% "$CURRENT_DIR/scripts/tmux-theme-picker" 2>/dev/null || true

tmux bind-key -N "📖 Session Dock Interactive Help" "$HELP_KEY" display-popup -E -w 70% -h 65% "$CURRENT_DIR/scripts/tmux-help-viewer" 2>/dev/null || tmux bind-key "$HELP_KEY" display-popup -E -w 70% -h 65% "$CURRENT_DIR/scripts/tmux-help-viewer" 2>/dev/null || true

tmux bind-key -N "⌨️ Session Dock Command Palette" "$PALETTE_KEY" display-popup -E -w 70% -h 60% "env TMUX_PANE='#{pane_id}' $CURRENT_DIR/scripts/tmux-command-palette" 2>/dev/null || tmux bind-key "$PALETTE_KEY" display-popup -E -w 70% -h 60% "env TMUX_PANE='#{pane_id}' $CURRENT_DIR/scripts/tmux-command-palette" 2>/dev/null || true

# 3. Work-Pane Safe Split Wrappers
tmux bind-key -N "✂️ Safe Horizontal Split" "|" run-shell "$BIN_PATH --split-horizontal" 2>/dev/null || tmux bind-key "|" run-shell "$BIN_PATH --split-horizontal" 2>/dev/null || true
tmux bind-key -N "✂️ Safe Vertical Split" "_" run-shell "$BIN_PATH --split-vertical" 2>/dev/null || tmux bind-key "_" run-shell "$BIN_PATH --split-vertical" 2>/dev/null || true
tmux bind-key -N "✂️ Safe Horizontal Split (Default)" "%" run-shell "$BIN_PATH --split-horizontal" 2>/dev/null || tmux bind-key "%" run-shell "$BIN_PATH --split-horizontal" 2>/dev/null || true
tmux bind-key -N "✂️ Safe Vertical Split (Default)" '"' run-shell "$BIN_PATH --split-vertical" 2>/dev/null || tmux bind-key '"' run-shell "$BIN_PATH --split-vertical" 2>/dev/null || true

# 4. Smart Pane Navigation
# Route every Alt+arrow through the Dock-aware navigator. Left is geometric
# (sidebar | w1 | w2: Left from w2 goes to w1); when the left neighbour is the
# dock column it enters the Sidebar, never the Subpane below it - the Subpane
# is reached from the Sidebar with Down.
tmux bind-key -n -N "🧭 Smart Focus Left" 'M-Left' run-shell "$BIN_PATH --smart-pane L" 2>/dev/null || true
tmux bind-key -n -N "🧭 Smart Focus Right" 'M-Right' run-shell "$BIN_PATH --smart-pane R" 2>/dev/null || true
tmux bind-key -n -N "🧭 Smart Focus Up" 'M-Up' run-shell "$BIN_PATH --smart-pane U" 2>/dev/null || true
tmux bind-key -n -N "🧭 Smart Focus Down" 'M-Down' run-shell "$BIN_PATH --smart-pane D" 2>/dev/null || true

# 5. IME focus hook (opt-in: set -g @session-dock-ime on). Reconciled on every
# config load so a tmux.conf change or the S popup takes effect immediately.
"$BIN_PATH" --apply-ime-hook >/dev/null 2>&1 || true
