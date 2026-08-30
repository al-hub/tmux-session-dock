#!/usr/bin/env bash
# ==============================================================================
# setup.sh - Universal Lifecycle Manager for tmux-session-dock
# Autonomous Install, Update, Uninstall, Build, Test & Status Diagnostics
# ==============================================================================
set -euo pipefail

VERSION="v0.3.57"
REPO_URL="https://github.com/al-hub/tmux-session-dock.git"
INSTALL_DIR="${TMUX_DOCK_INSTALL_DIR:-$HOME/.local/share/tmux-session-dock}"
# Git ref (tag, branch or commit) to install from; empty means latest main.
REF="${TMUX_DOCK_REF:-}"
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

resolve_repo_root() {
    local src="${BASH_SOURCE[0]:-}"
    if [ -n "$src" ] && [ -f "$src" ]; then
        local dir
        dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd || echo "")"
        if [ -n "$dir" ] && [ -f "$dir/scripts/build-dist.sh" ]; then
            echo "$dir"
            return 0
        fi
    fi
    # If running remotely via curl/stdin pipe, always target INSTALL_DIR
    echo "$INSTALL_DIR"
}

SCRIPT_DIR="$(resolve_repo_root)"

# Put the managed clone on the requested ref: latest main by default, or the
# tag/branch/commit named by --ref / TMUX_DOCK_REF (downgrade or pin).
_repo_synced=0
sync_repo_ref() {
    [ "$_repo_synced" = 1 ] && return 0
    _repo_synced=1
    if [ -z "$REF" ]; then
        log_info "Syncing latest changes in $INSTALL_DIR..."
        (cd "$INSTALL_DIR" && git fetch origin main 2>/dev/null &&
            { git checkout -q -f main 2>/dev/null || git checkout -q -f -b main 2>/dev/null || true; } &&
            git reset --hard origin/main 2>/dev/null && git clean -fd 2>/dev/null || true)
        return 0
    fi
    log_info "Checking out ref '$REF' in $INSTALL_DIR..."
    local rc=0
    (
        cd "$INSTALL_DIR" || exit 1
        git fetch --tags origin >/dev/null 2>&1 || true
        if git rev-parse --verify --quiet "refs/tags/$REF" >/dev/null; then
            git checkout -q -f --detach "refs/tags/$REF"
        elif git rev-parse --verify --quiet "origin/$REF" >/dev/null; then
            git checkout -q -f --detach "origin/$REF"
        elif git rev-parse --verify --quiet "$REF^{commit}" >/dev/null; then
            git checkout -q -f --detach "$REF"
        else
            exit 2
        fi
        git clean -fd >/dev/null 2>&1 || true
    ) || rc=$?
    case "$rc" in
        0) log_ok "Source pinned to $(cd "$INSTALL_DIR" && git describe --tags --always 2>/dev/null)" ;;
        2) log_error "Unknown ref '$REF'. Tags: $(cd "$INSTALL_DIR" && git tag --sort=-v:refname | head -n 5 | tr '\n' ' ')"; exit 1 ;;
        *) log_error "Failed to check out '$REF' in $INSTALL_DIR"; exit 1 ;;
    esac
}

ensure_repo_present() {
    if [ "$SCRIPT_DIR" = "$INSTALL_DIR" ] || [ ! -f "$SCRIPT_DIR/scripts/build-dist.sh" ]; then
        mkdir -p "$(dirname "$INSTALL_DIR")"
        if [ ! -d "$INSTALL_DIR/.git" ]; then
            log_info "Downloading tmux-session-dock into $INSTALL_DIR..."
            git clone "$REPO_URL" "$INSTALL_DIR"
        fi
        sync_repo_ref
        SCRIPT_DIR="$INSTALL_DIR"
    elif [ -n "$REF" ]; then
        log_warn "--ref '$REF' ignored: running from a local clone ($SCRIPT_DIR). Check out the ref there yourself."
    fi
}

usage() {
    echo -e "${BOLD}tmux-session-dock - Universal Setup & Lifecycle Controller${NC}"
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [COMMAND] [OPTIONS]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${CYAN}install${NC}       Compile bundle, register ~/.local/bin symlinks & configure tmux"
    echo -e "  ${CYAN}update${NC}        Pull latest upstream changes, rebuild dist & reload tmux"
    echo -e "  ${CYAN}uninstall${NC}     Remove binaries, symlinks, ~/.tmux.conf bindings; detach the live server, keep sessions"
    echo -e "  ${CYAN}purge${NC}         Full uninstall + purge all runtime state, cache & history"
    echo -e "                ${CYAN}--kill-server${NC} also ends the tmux server (asks first; ${CYAN}--yes${NC} to skip the prompt; ignored without a TTY)"
    echo -e "  ${CYAN}status${NC}        Check installation integrity, active version & dependencies"
    echo -e "  ${CYAN}build${NC}         Compile scripts/lib/ modules into single production dist/ bundle"
    echo -e "  ${CYAN}test${NC}          Run self-contained test matrix (Gate A~E, Subpane, Gradient)"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo -e "  --bin-dir DIR     Custom target directory for binary symlinks (default: ~/.local/bin)"
    echo -e "  --ref REF         Install/update from a git tag, branch or commit instead of latest main"
    echo -e "                    (curl mode and ~/.local/share clone only; env: TMUX_DOCK_REF)"
    echo -e "  --no-tmux-conf    Skip modifying ~/.tmux.conf"
    echo -e "  -h, --help        Show this help message"
    exit 0
}

do_build() {
    ensure_repo_present
    log_info "Building production standalone bundle..."
    bash "$SCRIPT_DIR/scripts/build-dist.sh"
    log_ok "Bundle ready: $SCRIPT_DIR/dist/tmux-session-dock"
}

do_test() {
    ensure_repo_present
    log_info "Running test matrix..."
    bash "$SCRIPT_DIR/tests/run-tests.sh" "$@"
}

ensure_ime_support() {
    # WSL2 only: build the tiny Windows helper that flips the IME conversion
    # mode (한/영) of the foreground window. Source ships as bin/win/imemode.cs and
    # is compiled locally with csc.exe, part of the .NET Framework 4.x that every
    # Windows 10/11 already has. No download, no third-party binary.
    grep -qi "microsoft" /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ] || return 0
    local src="$SCRIPT_DIR/bin/win/imemode.cs" out="$BIN_DIR/imemode.exe" csc=""
    [ -r "$src" ] || return 0
    if [ -x "$out" ] && [ ! "$src" -nt "$out" ]; then
        return 0
    fi
    for csc in /mnt/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe \
               /mnt/c/Windows/Microsoft.NET/Framework/v4.0.30319/csc.exe; do
        [ -x "$csc" ] && break
        csc=""
    done
    if [ -z "$csc" ] || ! command -v wslpath >/dev/null 2>&1; then
        log_info "WSL2: csc.exe not found; sidebar IME auto-English stays unavailable"
        return 0
    fi
    mkdir -p "$BIN_DIR"
    log_info "WSL2: building IME helper from bin/win/imemode.cs..."
    if "$csc" /nologo /optimize /target:exe "/out:$(wslpath -w "$out")" "$(wslpath -w "$src")" >/dev/null 2>&1 \
        && chmod +x "$out" 2>/dev/null; then
        log_ok "IME helper built: $out  (enable: set -g @session-dock-ime on, or the S popup)"
    else
        rm -f "$out" 2>/dev/null || true
        log_info "IME helper build failed; sidebar IME auto-English stays unavailable"
    fi
}

do_status() {
    echo -e "${CYAN}${BOLD}======================================================================${NC}"
    echo -e "  ${BOLD}tmux-session-dock - Status & Diagnostics (${VERSION})${NC}"
    echo -e "${CYAN}${BOLD}======================================================================${NC}"

    # Which checkout the symlinks point at, and what ref it is on
    local source_dir source_ref
    source_dir="$(dirname "$(dirname "$(readlink -f "$BIN_DIR/tmux-session-dock" 2>/dev/null || echo "$SCRIPT_DIR/dist/x")")")"
    if [ -d "$source_dir/.git" ]; then
        source_ref="$(cd "$source_dir" && git describe --tags --always 2>/dev/null || echo "?")"
        echo -e "  Source:       ${GREEN}${source_ref}${NC} ($source_dir)"
    else
        echo -e "  Source:       $source_dir"
    fi
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
    local theme_count=0
    if [ -d "$SCRIPT_DIR/themes" ]; then
        theme_count=$(find "$SCRIPT_DIR/themes" -name "*.conf" 2>/dev/null | wc -l)
    fi
    echo -e "  Themes:       ${GREEN}$theme_count themes available${NC} ($SCRIPT_DIR/themes)"

    # Check tmux requirement
    if command -v tmux >/dev/null 2>&1; then
        local tmux_ver
        tmux_ver=$(tmux -V 2>/dev/null || echo "unknown")
        echo -e "  tmux Server:  ${GREEN}DETECTED${NC} ($tmux_ver)"
    else
        echo -e "  tmux Server:  ${RED}NOT DETECTED${NC}"
    fi

    # Sidebar IME focus hook (opt-in)
    local ime_status="setting=off backend=none hook_in=absent hook_out=absent"
    if [ -x "$SCRIPT_DIR/dist/tmux-session-dock" ]; then
        ime_status="$("$SCRIPT_DIR/dist/tmux-session-dock" --ime-status 2>/dev/null || echo "$ime_status")"
    fi
    case "$ime_status" in
        *backend=none*)    echo -e "  IME Hook:     ${CYAN}UNAVAILABLE${NC} (no helper: imemode.exe / fcitx5 / fcitx / ibus / im-select)" ;;
        *setting=restore*) echo -e "  IME Hook:     ${GREEN}RESTORE${NC} ($ime_status)" ;;
        *setting=on*)      echo -e "  IME Hook:     ${GREEN}ON${NC} ($ime_status)" ;;
        *)                 echo -e "  IME Hook:     ${YELLOW}OFF${NC} ($ime_status; enable: set -g @session-dock-ime on|restore)" ;;
    esac

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
    local dotfiles_mode="on"
    for arg in "$@"; do
        case "$arg" in
            --no-tmux-conf) no_conf=1 ;;
            --minimal)      dotfiles_mode="off" ;;
            --full|--with-dotfiles) dotfiles_mode="on" ;;
            --bin-dir) shift; BIN_DIR="${1:-$BIN_DIR}" ;;
        esac
    done

    log_info "Installing tmux-session-dock (ergonomics mode: $dotfiles_mode)..."
    ensure_repo_present

    # 1. Build dist bundle if missing
    if [ ! -f "$SCRIPT_DIR/dist/tmux-session-dock" ]; then
        do_build
    fi

    # 2. Setup symlinks in BIN_DIR
    mkdir -p "$BIN_DIR"
    ensure_ime_support
    ln -sf "$SCRIPT_DIR/dist/tmux-session-dock" "$BIN_DIR/tmux-session-dock"
    ln -sf "$SCRIPT_DIR/dist/tmux-sidebar-tmux-adapter" "$BIN_DIR/tmux-sidebar-tmux-adapter"
    ln -sf "$SCRIPT_DIR/scripts/tmux-theme-picker" "$BIN_DIR/tmux-theme-picker"
    ln -sf "$SCRIPT_DIR/scripts/tmux-subpane-picker" "$BIN_DIR/tmux-subpane-picker"
    ln -sf "$SCRIPT_DIR/scripts/tmux-command-palette" "$BIN_DIR/tmux-command-palette"
    ln -sf "$SCRIPT_DIR/scripts/tmux-help-viewer" "$BIN_DIR/tmux-help-viewer"
    ln -sf "$SCRIPT_DIR/scripts/tmux-session-dock-ime" "$BIN_DIR/tmux-session-dock-ime"
    log_ok "Symlinks registered in $BIN_DIR"

    # 3. Setup themes directory
    local user_theme_dir="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/themes"
    mkdir -p "$user_theme_dir"
    cp "$SCRIPT_DIR/themes"/*.conf "$user_theme_dir/" 2>/dev/null || true
    log_ok "59 themes synchronized to $user_theme_dir"

    # 4. Inject configuration into ~/.tmux.conf if requested
    if [ "$no_conf" -eq 0 ]; then
        touch "$CONFIG_FILE"
        local marker="# >>> tmux-session-dock configuration >>>"
        if grep -q "$marker" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '/# >>> tmux-session-dock configuration >>>/,/# <<< tmux-session-dock configuration <<</d' "$CONFIG_FILE"
        fi
        log_info "Registering configuration snippet in $CONFIG_FILE..."
        cat <<CONF_EOF >> "$CONFIG_FILE"

# >>> tmux-session-dock configuration >>>
# Auto-managed by tmux-session-dock setup controller
set -g @session-dock-dotfiles-mode "$dotfiles_mode"
run-shell 'bash "$SCRIPT_DIR/session-dock.tmux" 2>/dev/null || bash ~/.local/share/tmux-session-dock/session-dock.tmux 2>/dev/null || true'
# <<< tmux-session-dock configuration <<<
CONF_EOF
        log_ok "Snippet injected into $CONFIG_FILE"
    fi

    # 5. Hot-reload active tmux server if running
    if tmux list-sessions >/dev/null 2>&1; then
        tmux source-file "$CONFIG_FILE" 2>/dev/null || true
        log_ok "Active tmux server configuration reloaded."
    fi

    log_ok "🎉 tmux-session-dock installation complete!"
}

do_update() {
    log_info "Updating tmux-session-dock..."
    ensure_repo_present
    cd "$SCRIPT_DIR"
    do_build

    # Update symlinks
    mkdir -p "$BIN_DIR"
    ensure_ime_support
    ln -sf "$SCRIPT_DIR/dist/tmux-session-dock" "$BIN_DIR/tmux-session-dock"
    ln -sf "$SCRIPT_DIR/dist/tmux-sidebar-tmux-adapter" "$BIN_DIR/tmux-sidebar-tmux-adapter"
    ln -sf "$SCRIPT_DIR/scripts/tmux-theme-picker" "$BIN_DIR/tmux-theme-picker"
    ln -sf "$SCRIPT_DIR/scripts/tmux-subpane-picker" "$BIN_DIR/tmux-subpane-picker"
    ln -sf "$SCRIPT_DIR/scripts/tmux-command-palette" "$BIN_DIR/tmux-command-palette"
    ln -sf "$SCRIPT_DIR/scripts/tmux-help-viewer" "$BIN_DIR/tmux-help-viewer"
    ln -sf "$SCRIPT_DIR/scripts/tmux-session-dock-ime" "$BIN_DIR/tmux-session-dock-ime"
    log_ok "Symlinks updated in $BIN_DIR"

    local user_theme_dir="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/themes"
    if [ -d "$user_theme_dir" ]; then
        cp "$SCRIPT_DIR/themes"/*.conf "$user_theme_dir/" 2>/dev/null || true
    fi

    if tmux list-sessions >/dev/null 2>&1; then
        tmux source-file "$CONFIG_FILE" 2>/dev/null || true
    fi
    log_ok "Update completed successfully!"
}

# Remove every dock artefact from the RUNNING tmux server while keeping the
# user's sessions: hooks, key bindings, dock panes (sidebar / subpane slots),
# the hidden hub session and the dock's global options. Only this repo's own
# processes are terminated - never the tmux server, never by a loose name.
detach_live_server() {
    tmux list-sessions >/dev/null 2>&1 || return 0
    local dock_re='tmux-session-dock|tmux-session-launcher|tmux-subpane-picker|tmux-theme-picker|tmux-help-viewer|tmux-command-palette'
    local hook entry name index

    # Hooks: every array entry whose command names a dock script. A bare
    # `show-hooks -g` omits pane-focus-in/out on tmux 3.2, list those by name.
    for hook in $(tmux show-hooks -g 2>/dev/null | awk '{print $1}' | sed 's/\[.*//' | sort -u) pane-focus-in pane-focus-out; do
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            name="${entry%%[*}"; index="${entry#*[}"; index="${index%%]*}"
            tmux set-hook -gu "${name}[${index}]" 2>/dev/null || true
        done < <(tmux show-hooks -g "$hook" 2>/dev/null | grep -E "$dock_re" | awk '{print $1}')
    done

    # Key bindings that run a dock script or popup.
    while read -r _ table key; do
        [ -n "$key" ] || continue
        key="${key#\\}"   # list-keys prints \" for the double-quote key
        tmux unbind-key -T "$table" "$key" 2>/dev/null || true
    done < <(tmux list-keys 2>/dev/null | grep -E "$dock_re" | awk '{ for (i = 1; i <= NF; i++) if ($i == "-T") { print "k", $(i+1), $(i+2); break } }')

    # Dock panes and the hidden hub session; work panes are untouched.
    while IFS= read -r entry; do
        [ -n "$entry" ] && tmux kill-pane -t "$entry" 2>/dev/null || true
    done < <(tmux list-panes -a -F '#{pane_id}|#{pane_title}|#{@dotfiles_sidebar_pane}|#{@dotfiles_sidebar_subpane}' 2>/dev/null |
        awk -F '|' '$2 == "dotfiles-session-sidebar" || $3 == "1" || $4 == "1" { print $1 }')
    tmux kill-session -t "=dotfiles-subpane-hub" 2>/dev/null || true

    # Dock options and hidden environment.
    for name in $(tmux show-options -g 2>/dev/null | awk '{print $1}' | grep -E '^@(dotfiles_|dotfiles-|session-dock|sidebar_)' ); do
        tmux set-option -gu "$name" 2>/dev/null || true
    done
    for name in $(tmux show-environment -gh 2>/dev/null | grep -o '^DOTFILES_SIDEBAR_[A-Za-z0-9_]*'); do
        tmux set-environment -ghu "$name" 2>/dev/null || true
    done
    tmux set-option -gu focus-events 2>/dev/null || true
    log_ok "Live tmux server detached from the dock (hooks, keys, dock panes, hub, options); your sessions are untouched."
}

kill_dock_processes() {
    # Only the dock's own long-running processes (presenters, observer,
    # helpers). Never a plain `pkill -f tmux-session-dock`: that matches every
    # process whose command line merely contains the path - including this
    # setup script and unrelated tools living next to it.
    pkill -f '(tmux-session-dock|tmux-session-launcher)[^ ]* --(sidebar|observe)( |$)' 2>/dev/null || true
    pkill -f 'tmux-session-dock-ime( |$)' 2>/dev/null || true
}

do_uninstall() {
    local purge="${1:-0}" kill_server=0 assume_yes=0 arg
    shift || true
    for arg in "$@"; do
        case "$arg" in
            --kill-server) kill_server=1 ;;
            --yes|-y) assume_yes=1 ;;
        esac
    done
    log_warn "Uninstalling tmux-session-dock..."

    # 1. Remove symlinks
    rm -f "$BIN_DIR/tmux-session-dock" \
          "$BIN_DIR/tmux-sidebar-tmux-adapter" \
          "$BIN_DIR/tmux-theme-picker" \
          "$BIN_DIR/tmux-command-palette" \
          "$BIN_DIR/tmux-help-viewer" \
          "$BIN_DIR/tmux-session-dock-ime" \
          "$BIN_DIR/imemode.exe"
    log_ok "Symlinks removed from $BIN_DIR"

    # 2. Clean ~/.tmux.conf
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q "tmux-session-dock" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '/# >>> tmux-session-dock configuration >>>/,/# <<< tmux-session-dock configuration <<</d' "$CONFIG_FILE" 2>/dev/null || true
            sed -i '/tmux-session-dock/d' "$CONFIG_FILE" 2>/dev/null || true
            log_ok "Configuration snippet removed from $CONFIG_FILE"
        fi
        # Remove ~/.tmux.conf if empty or only comments
        if [ ! -s "$CONFIG_FILE" ] || [ "$(grep -v '^[[:space:]]*#' "$CONFIG_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' | wc -l)" -eq 0 ]; then
            rm -f "$CONFIG_FILE"
            log_ok "Removed empty $CONFIG_FILE"
        fi
    fi

    # 3. Purge themes, state, and cache directories
    if [ "$purge" -eq 1 ]; then
        log_warn "Purging themes, state, and cache directories..."
        rm -rf "$STATE_DIR" "$CACHE_DIR"
        rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/themes"
        rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/theme.conf"
        rmdir "${XDG_CONFIG_HOME:-$HOME/.config}/tmux" 2>/dev/null || true
        if [ -d "$INSTALL_DIR" ]; then
            rm -rf "$INSTALL_DIR"
        fi
        # If ~/.tmux.conf was purely managed by dotfiles/dock, remove it on purge
        if [ -f "$CONFIG_FILE" ] && grep -q "@session-dock" "$CONFIG_FILE" 2>/dev/null; then
            rm -f "$CONFIG_FILE"
            log_ok "Removed managed $CONFIG_FILE"
        fi
        log_ok "Purged state, cache, themes, and installation directory."
    fi

    # 4. Detach the running server (sessions survive) and stop dock processes.
    detach_live_server
    kill_dock_processes

    # 5. Optional, explicit: restart-clean by killing the tmux server. Only on
    # request, only with confirmation (or --yes), never when nobody can see
    # the prompt (non-interactive stdin) - an uninstall driven by another
    # script must not take the user's sessions down.
    if [ "$kill_server" -eq 1 ] && tmux list-sessions >/dev/null 2>&1; then
        local sessions
        sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ' ')"
        if [ "$assume_yes" -eq 1 ]; then
            tmux kill-server 2>/dev/null || true
            log_ok "tmux server terminated (--kill-server --yes). Sessions ended: ${sessions:-none}"
        elif [ -t 0 ]; then
            printf '%b' "${YELLOW}This ends every tmux session (${sessions:-none}). Kill the tmux server? [y/N] ${NC}"
            local answer=""
            read -r answer || true
            case "$answer" in
                y|Y|yes|YES)
                    tmux kill-server 2>/dev/null || true
                    log_ok "tmux server terminated. Sessions ended: ${sessions:-none}"
                    ;;
                *) log_info "Kept the tmux server running." ;;
            esac
        else
            log_warn "--kill-server ignored: no interactive terminal to confirm. Re-run with --yes to end the tmux server (sessions: ${sessions:-none})."
        fi
    fi
    log_ok "Uninstallation complete. Zero residual hooks."
}

# Auto-dispatch based on invocation filename
INVOKED_AS="$(basename "${0:-setup.sh}")"
if [ "$INVOKED_AS" = "install.sh" ] && [ $# -eq 0 ]; then
    set -- "install"
elif [ "$INVOKED_AS" = "uninstall.sh" ] && [ $# -eq 0 ]; then
    set -- "uninstall"
fi

CMD="${1:-install}"
shift || true

# --ref applies to every command; strip it before the per-command parsers.
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --ref)   REF="${2:-}"; shift 2 || shift; continue ;;
        --ref=*) REF="${1#--ref=}"; shift; continue ;;
    esac
    ARGS+=("$1"); shift
done
set -- "${ARGS[@]}"

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
