#!/usr/bin/env bash
# ==============================================================================
# sidebar_ime.sh - Cross-platform IME Control Module for tmux-session-dock
# Deep Module: Tiny interface, asynchronous non-blocking execution, silent fallback
# ==============================================================================
set -euo pipefail

SIDEBAR_IME_STATE_DIR="/dev/shm/tmux_session_dock_ime_${UID:-$(id -u)}"
SIDEBAR_IME_BACKEND_CACHE=""

# ------------------------------------------------------------------------------
# 1. Detect Available IME CLI Backend (Cached)
# ------------------------------------------------------------------------------
sidebar_ime_detect_backend() {
    [ -n "$SIDEBAR_IME_BACKEND_CACHE" ] && { echo "$SIDEBAR_IME_BACKEND_CACHE"; return 0; }

    # 1) WSL2 / Windows environment
    if grep -qi "microsoft" /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
        if command -v im-select.exe >/dev/null 2>&1; then
            SIDEBAR_IME_BACKEND_CACHE="wsl-im-select"
            echo "$SIDEBAR_IME_BACKEND_CACHE"
            return 0
        elif [ -x "$HOME/.local/bin/im-select.exe" ]; then
            SIDEBAR_IME_BACKEND_CACHE="wsl-im-select-local"
            echo "$SIDEBAR_IME_BACKEND_CACHE"
            return 0
        fi
    fi

    # 2) macOS
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        if command -v im-select >/dev/null 2>&1; then
            SIDEBAR_IME_BACKEND_CACHE="mac-im-select"
            echo "$SIDEBAR_IME_BACKEND_CACHE"
            return 0
        elif command -v macism >/dev/null 2>&1; then
            SIDEBAR_IME_BACKEND_CACHE="mac-macism"
            echo "$SIDEBAR_IME_BACKEND_CACHE"
            return 0
        fi
    fi

    # 3) Linux Native (fcitx5 / fcitx / ibus)
    if command -v fcitx5-remote >/dev/null 2>&1; then
        SIDEBAR_IME_BACKEND_CACHE="linux-fcitx5"
        echo "$SIDEBAR_IME_BACKEND_CACHE"
        return 0
    elif command -v fcitx-remote >/dev/null 2>&1; then
        SIDEBAR_IME_BACKEND_CACHE="linux-fcitx"
        echo "$SIDEBAR_IME_BACKEND_CACHE"
        return 0
    elif command -v ibus >/dev/null 2>&1; then
        SIDEBAR_IME_BACKEND_CACHE="linux-ibus"
        echo "$SIDEBAR_IME_BACKEND_CACHE"
        return 0
    fi

    SIDEBAR_IME_BACKEND_CACHE="none"
    echo "$SIDEBAR_IME_BACKEND_CACHE"
}

# ------------------------------------------------------------------------------
# 2. Get Current IME State
# ------------------------------------------------------------------------------
sidebar_ime_get_current() {
    local backend
    backend="$(sidebar_ime_detect_backend)"

    case "$backend" in
        wsl-im-select)
            im-select.exe 2>/dev/null || echo "1033"
            ;;
        wsl-im-select-local)
            "$HOME/.local/bin/im-select.exe" 2>/dev/null || echo "1033"
            ;;
        mac-im-select)
            im-select 2>/dev/null || echo "com.apple.keylayout.ABC"
            ;;
        mac-macism)
            macism 2>/dev/null || echo "com.apple.keylayout.ABC"
            ;;
        linux-fcitx5)
            fcitx5-remote 2>/dev/null || echo "1"
            ;;
        linux-fcitx)
            fcitx-remote 2>/dev/null || echo "1"
            ;;
        linux-ibus)
            ibus engine 2>/dev/null || echo "xkb:us::eng"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 3. Check if currently in English mode (Fast-path helper)
# ------------------------------------------------------------------------------
sidebar_ime_is_english() {
    local current
    current="$(sidebar_ime_get_current)"

    case "$current" in
        "1033"|"com.apple.keylayout.ABC"|"com.apple.keylayout.US"|"1"|"xkb:us::eng"|"unknown")
            return 0
            ;;
        *)
            # Non-English (e.g. Korean IME active)
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 4. Asynchronously Switch to English (Only when non-English)
# ------------------------------------------------------------------------------
sidebar_ime_switch_to_english() {
    local context="${1:-default}"
    local backend
    backend="$(sidebar_ime_detect_backend)"
    [ "$backend" = "none" ] && return 0

    # Execute detached subshell (Double fork) to ensure 0ms blocking
    (
        local current
        current="$(sidebar_ime_get_current)"

        # If already English, skip immediately!
        case "$current" in
            "1033"|"com.apple.keylayout.ABC"|"com.apple.keylayout.US"|"1"|"xkb:us::eng"|"unknown")
                exit 0
                ;;
        esac

        # Save previous state in RAM disk for future restore readiness
        mkdir -p "$SIDEBAR_IME_STATE_DIR" 2>/dev/null || true
        echo "$current" > "$SIDEBAR_IME_STATE_DIR/${context}.state" 2>/dev/null || true

        # Switch to English
        case "$backend" in
            wsl-im-select)
                im-select.exe 1033 >/dev/null 2>&1 || true
                ;;
            wsl-im-select-local)
                "$HOME/.local/bin/im-select.exe" 1033 >/dev/null 2>&1 || true
                ;;
            mac-im-select)
                im-select com.apple.keylayout.ABC >/dev/null 2>&1 || true
                ;;
            mac-macism)
                macism com.apple.keylayout.ABC >/dev/null 2>&1 || true
                ;;
            linux-fcitx5|linux-fcitx)
                fcitx-remote -c >/dev/null 2>&1 || fcitx5-remote -c >/dev/null 2>&1 || true
                ;;
            linux-ibus)
                ibus engine "xkb:us::eng" >/dev/null 2>&1 || true
                ;;
        esac
    ) >/dev/null 2>&1 &
}

# ------------------------------------------------------------------------------
# 5. Restore Previous IME State (Prepared for future bidirectional option)
# ------------------------------------------------------------------------------
sidebar_ime_restore() {
    local context="${1:-default}"
    local backend
    backend="$(sidebar_ime_detect_backend)"
    [ "$backend" = "none" ] && return 0

    local state_file="$SIDEBAR_IME_STATE_DIR/${context}.state"
    [ -f "$state_file" ] || return 0

    (
        local saved_state
        saved_state="$(cat "$state_file" 2>/dev/null || true)"
        rm -f "$state_file" 2>/dev/null || true
        [ -n "$saved_state" ] || exit 0

        case "$backend" in
            wsl-im-select)
                im-select.exe "$saved_state" >/dev/null 2>&1 || true
                ;;
            wsl-im-select-local)
                "$HOME/.local/bin/im-select.exe" "$saved_state" >/dev/null 2>&1 || true
                ;;
            mac-im-select)
                im-select "$saved_state" >/dev/null 2>&1 || true
                ;;
            mac-macism)
                macism "$saved_state" >/dev/null 2>&1 || true
                ;;
            linux-fcitx5|linux-fcitx)
                [ "$saved_state" = "2" ] && { fcitx-remote -o >/dev/null 2>&1 || fcitx5-remote -o >/dev/null 2>&1 || true; }
                ;;
            linux-ibus)
                ibus engine "$saved_state" >/dev/null 2>&1 || true
                ;;
        esac
    ) >/dev/null 2>&1 &
}
