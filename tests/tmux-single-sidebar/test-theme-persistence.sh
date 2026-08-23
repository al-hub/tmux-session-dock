#!/usr/bin/env bash
# test-theme-persistence.sh
# Validates theme loading and persistence across tmux restarts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOCKET="test-theme-$$"
TMP_XDG="$(mktemp -d)"

cleanup() {
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_XDG"
}
trap cleanup EXIT

echo "=== [1/3] Verifying saved theme persistence via theme.conf ==="
mkdir -p "$TMP_XDG/tmux"
cp "$SCRIPT_DIR/themes/open-tokyonight.conf" "$TMP_XDG/tmux/theme.conf"

tmux -L "$SOCKET" new-session -d -s test-theme 'sleep 60'
tmux -L "$SOCKET" run-shell "XDG_CONFIG_HOME='$TMP_XDG' bash '$SCRIPT_DIR/session-dock.tmux'"

# Tokyonight sets status-style bg='#16161e'
status_style="$(tmux -L "$SOCKET" show-option -gqv status-style)"
if [[ "$status_style" == *"#16161e"* ]]; then
    echo "PASS: Saved theme.conf loaded into new tmux session."
else
    echo "FAIL: Expected status-style to contain #16161e, got: $status_style"
    exit 1
fi
tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true

echo "=== [2/3] Verifying fallback to @session-dock-theme option ==="
rm -f "$TMP_XDG/tmux/theme.conf"

tmux -L "$SOCKET" new-session -d -s test-theme 'sleep 60'
tmux -L "$SOCKET" set-option -g @session-dock-theme 'cyberpunk-neon'
tmux -L "$SOCKET" run-shell "XDG_CONFIG_HOME='$TMP_XDG' bash '$SCRIPT_DIR/session-dock.tmux'"

# Cyberpunk neon sets status-style bg='#171221'
status_style="$(tmux -L "$SOCKET" show-option -gqv status-style)"
if [[ "$status_style" == *"#171221"* ]]; then
    echo "PASS: @session-dock-theme loaded successfully when theme.conf is absent."
else
    echo "FAIL: Expected status-style to contain #171221, got: $status_style"
    exit 1
fi
tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true

echo "=== [3/3] Verifying theme.conf takes priority over @session-dock-theme ==="
cp "$SCRIPT_DIR/themes/open-tokyonight.conf" "$TMP_XDG/tmux/theme.conf"

tmux -L "$SOCKET" new-session -d -s test-theme 'sleep 60'
tmux -L "$SOCKET" set-option -g @session-dock-theme 'cyberpunk-neon'
tmux -L "$SOCKET" run-shell "XDG_CONFIG_HOME='$TMP_XDG' bash '$SCRIPT_DIR/session-dock.tmux'"

status_style="$(tmux -L "$SOCKET" show-option -gqv status-style)"
if [[ "$status_style" == *"#16161e"* ]]; then
    echo "PASS: Saved theme.conf takes priority over default option."
else
    echo "FAIL: Expected status-style to contain #16161e (tokyonight), got: $status_style"
    exit 1
fi

echo "=========================================================================="
echo "ALL TESTS PASS: Theme persistence & option handling 100% verified!"
echo "=========================================================================="
