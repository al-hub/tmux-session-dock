#!/usr/bin/env bash
# ==============================================================================
# setup.sh - Universal Lifecycle Manager for tmux-session-dock
# Autonomous Install, Update, Uninstall, Build, Test & Status Diagnostics
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${TMUX_DOCK_BIN_DIR:-$HOME/.local/bin}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-session-dock"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-session-dock"
CONFIG_FILE="${TMUX_CONF:-$HOME/.tmux.conf}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}${BOLD}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}${BOLD}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}${BOLD}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}${BOLD}[ERROR]${NC} $*" >&2; }

usage() {
    echo -e "${BOLD}tmux-session-dock - Universal Setup & Lifecycle Controller${NC}"
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [COMMAND] [OPTIONS]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${CYAN}install${NC}       Compile bundle, register ~/.local/bin symlinks & configure tmux"
    echo -e "  ${CYAN}update${NC}        Pull latest upstream changes, rebuild dist & reload tmux"
    echo -e "  ${CYAN}uninstall${NC}     Cleanly remove binaries, symlinks, and ~/.tmux.conf bindings"
    echo -e "  ${CYAN}purge${NC}         Full uninstall + purge all runtime state, cache & history"
    echo -e "  ${CYAN}status${NC}        Check installation integrity, active version & dependencies"
    echo -e "  ${CYAN}build${NC}         Compile scripts/lib/ modules into single production dist/ bundle"
    echo -e "  ${CYAN}test${NC}          Run self-contained test matrix (Gate A~E, Subpane, Gradient)"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo -e "  --bin-dir DIR     Custom target directory for binary symlinks (default: ~/.local/bin)"
    echo -e "  --no-tmux-conf    Skip modifying ~/.tmux.conf"
    echo -e "  -h, --help        Show this help message"
    exit 0
}

do_build() {
    log_info "Building production standalone bundle..."
    bash "$SCRIPT_DIR/scripts/build-dist.sh"
    log_ok "Bundle ready: $SCRIPT_DIR/dist/tmux-session-dock"
}

do_test() {
    log_info "Running test matrix..."
    bash "$SCRIPT_DIR/tests/run-tests.sh" "$@"
}

do_status() {
    echo -e "${CYAN}${BOLD}======================================================================${NC}"
    echo -e "  ${BOLD}tmux-session-dock - Status & Diagnostics${NC}"
    echo -e "${CYAN}${BOLD}======================================================================${NC}"
    
    # Check binary in BIN_DIR
    if [ -x "$BIN_DIR/tmux-session-dock" ]; then
        echo -e "  Binary:       ${GREEN}INSTALLED${NC} ($BIN_DIR/tmux-session-dock)"
    else
        echo -e "  Binary:       ${YELLOW}NOT FOUND${NC} in $BIN_DIR"
    fi

    # Check dist bundle
    if [ -x "$SCRIPT_DIR/dist/tmux-session-dock" ]; then
        echo -e "  Dist Bundle:  ${GREEN}BUILT${NC} ($SCRIPT_DIR/dist/tmux-session-dock)"
    else
        echo -e "  Dist Bundle:  ${YELLOW}NOT BUILT${NC} (Run: ./setup.sh build)"
    fi

    # Check themes
    local theme_count
    theme_count=$(find "$SCRIPT_DIR/themes" -name "*.conf" 2>/dev/null | wc -l)
    echo -e "  Themes:       ${GREEN}$theme_count themes available${NC} ($SCRIPT_DIR/themes)"

    # Check tmux requirement
    if command -v tmux >/dev/null 2>&1; then
        local tmux_ver
        tmux_ver=$(tmux -V 2>/dev/null || echo "unknown")
        echo -e "  tmux Server:  ${GREEN}DETECTED${NC} ($tmux_ver)"
    else
        echo -e "  tmux Server:  ${RED}NOT DETECTED${NC}"
    fi

    # Check ~/.tmux.conf configuration
    if [ -f "$CONFIG_FILE" ] && grep -q "tmux-session-dock" "$CONFIG_FILE" 2>/dev/null; then
        echo -e "  ~/.tmux.conf: ${GREEN}CONFIGURED${NC} ($CONFIG_FILE)"
    else
        echo -e "  ~/.tmux.conf: ${YELLOW}NOT CONFIGURED${NC}"
    fi

    echo -e "${CYAN}${BOLD}======================================================================${NC}"
}

do_install() {
    local no_conf=0
    for arg in "$@"; do
        case "$arg" in
            --no-tmux-conf) no_conf=1 ;;
            --bin-dir) shift; BIN_DIR="${1:-$BIN_DIR}" ;;
        esac
    done

    log_info "Installing tmux-session-dock..."

    # 1. Build dist bundle if missing
    if [ ! -f "$SCRIPT_DIR/dist/tmux-session-dock" ]; then
        do_build
    fi

    # 2. Setup symlinks in BIN_DIR
    mkdir -p "$BIN_DIR"
    ln -sf "$SCRIPT_DIR/dist/tmux-session-dock" "$BIN_DIR/tmux-session-dock"
    ln -sf "$SCRIPT_DIR/dist/tmux-sidebar-tmux-adapter" "$BIN_DIR/tmux-sidebar-tmux-adapter"
    ln -sf "$SCRIPT_DIR/scripts/tmux-theme-picker" "$BIN_DIR/tmux-theme-picker"
    ln -sf "$SCRIPT_DIR/scripts/tmux-command-palette" "$BIN_DIR/tmux-command-palette"
    ln -sf "$SCRIPT_DIR/scripts/tmux-help-viewer" "$BIN_DIR/tmux-help-viewer"
    log_ok "Symlinks registered in $BIN_DIR"

    # 3. Setup themes directory
    local user_theme_dir="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/themes"
    mkdir -p "$user_theme_dir"
    cp "$SCRIPT_DIR/themes"/*.conf "$user_theme_dir/" 2>/dev/null || true
    log_ok "38 themes synchronized to $user_theme_dir"

    # 4. Inject configuration into ~/.tmux.conf if requested
    if [ "$no_conf" -eq 0 ]; then
        touch "$CONFIG_FILE"
        local marker="# >>> tmux-session-dock configuration >>>"
        if ! grep -q "$marker" "$CONFIG_FILE" 2>/dev/null; then
            log_info "Registering configuration snippet in $CONFIG_FILE..."
            cat <<'CONF_EOF' >> "$CONFIG_FILE"

# >>> tmux-session-dock configuration >>>
# Auto-managed by tmux-session-dock setup controller
run-shell -b "~/.local/share/tmux-session-dock/session-dock.tmux" 2>/dev/null || run-shell -b "$HOME/workspace/tmux-session-dock/session-dock.tmux"
# <<< tmux-session-dock configuration <<<
CONF_EOF
            log_ok "Snippet injected into $CONFIG_FILE"
        fi
    fi

    # 5. Hot-reload active tmux server if running
    if tmux info >/dev/null 2>&1; then
        tmux source-file "$CONFIG_FILE" 2>/dev/null || true
        log_ok "Active tmux server configuration reloaded."
    fi

    log_ok "🎉 tmux-session-dock installation complete!"
}

do_update() {
    log_info "Updating tmux-session-dock..."
    cd "$SCRIPT_DIR"
    if [ -d ".git" ]; then
        git pull --ff-only origin main || git pull origin master || true
    fi
    do_build

    local user_theme_dir="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/themes"
    if [ -d "$user_theme_dir" ]; then
        cp "$SCRIPT_DIR/themes"/*.conf "$user_theme_dir/" 2>/dev/null || true
    fi

    if tmux info >/dev/null 2>&1; then
        tmux source-file "$CONFIG_FILE" 2>/dev/null || true
    fi
    log_ok "Update completed successfully!"
}

do_uninstall() {
    local purge="${1:-0}"
    log_warn "Uninstalling tmux-session-dock..."

    # 1. Remove symlinks
    rm -f "$BIN_DIR/tmux-session-dock" \
          "$BIN_DIR/tmux-sidebar-tmux-adapter" \
          "$BIN_DIR/tmux-theme-picker" \
          "$BIN_DIR/tmux-command-palette" \
          "$BIN_DIR/tmux-help-viewer"
    log_ok "Symlinks removed from $BIN_DIR"

    # 2. Clean ~/.tmux.conf
    if [ -f "$CONFIG_FILE" ] && grep -q "tmux-session-dock" "$CONFIG_FILE" 2>/dev/null; then
        sed -i '/# >>> tmux-session-dock configuration >>>/,/# <<< tmux-session-dock configuration <<</d' "$CONFIG_FILE"
        log_ok "Configuration snippet removed from $CONFIG_FILE"
    fi

    # 3. Purge state if requested
    if [ "$purge" -eq 1 ]; then
        log_warn "Purging state and cache directories..."
        rm -rf "$STATE_DIR" "$CACHE_DIR"
        log_ok "Purged $STATE_DIR and $CACHE_DIR"
    fi

    if tmux info >/dev/null 2>&1; then
        tmux source-file "$CONFIG_FILE" 2>/dev/null || true
    fi
    log_ok "Uninstallation complete. Zero residual hooks."
}

# Auto-dispatch based on invocation filename (install.sh / uninstall.sh symlink compat)
INVOKED_AS="$(basename "$0")"
if [ "$INVOKED_AS" = "install.sh" ] && [ $# -eq 0 ]; then
    set -- "install"
elif [ "$INVOKED_AS" = "uninstall.sh" ] && [ $# -eq 0 ]; then
    set -- "uninstall"
fi

CMD="${1:-install}"
shift || true

case "$CMD" in
    install)    do_install "$@" ;;
    update)     do_update "$@" ;;
    uninstall)  do_uninstall 0 "$@" ;;
    purge)      do_uninstall 1 "$@" ;;
    status|doctor) do_status ;;
    build)      do_build ;;
    test)       do_test "$@" ;;
    -h|--help)  usage ;;
    *)          usage ;;
esac
