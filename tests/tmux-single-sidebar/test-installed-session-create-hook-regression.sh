#!/usr/bin/env bash
set -euo pipefail

# Reproduce the installed-runtime path: create sessions via c/New/Enter on an
# attached PTY and detect asynchronous session-hook failures.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALLED_LAUNCHER="${TMUX_INSTALLED_LAUNCHER:-/home/al-hub/.local/share/tmux-session-dock/dist/tmux-session-dock}"
[ -r "$INSTALLED_LAUNCHER" ] || {
    printf 'SKIP: installed launcher not found: %s\n' "$INSTALLED_LAUNCHER"
    exit 0
}

exec env \
    TMUX_KEYBOARD_E2E_LAUNCHER="$INSTALLED_LAUNCHER" \
    TMUX_KEYBOARD_E2E_HOOK_WRAPPER="$TEST_DIR/test-session-hook-exit-wrapper.sh" \
    TMUX_KEYBOARD_E2E_SCENARIO=session-create-latency \
    TMUX_KEYBOARD_E2E_ANCHOR_SESSION=installed-runtime-anchor \
    TMUX_KEYBOARD_E2E_TRANSPORT="${TMUX_KEYBOARD_E2E_TRANSPORT:-bridge}" \
    TMUX_SESSION_LAUNCHER_TRACE=1 \
    TMUX_SESSION_LAUNCHER_DEBUG=1 \
    bash "$TEST_DIR/test-keyboard-e2e.sh" "$@"
