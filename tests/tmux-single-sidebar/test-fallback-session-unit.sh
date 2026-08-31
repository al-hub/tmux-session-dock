#!/usr/bin/env bash
# Unit test for fallback session resolution during session delete
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Source domain helpers
source "$SCRIPT_DIR/scripts/lib/sidebar_domain.sh"

# Extract fallback_session function from scripts/tmux-session-dock
eval "$(sed -n '/^fallback_session()/,/^}/p' "$SCRIPT_DIR/scripts/tmux-session-dock")"

# Test Case 1: Infrastructure session 'dotfiles-subpane-hub' should NOT be chosen as fallback
tmux() {
    if [ "$1" = "list-sessions" ]; then
        printf 'dotfiles-subpane-hub\nalpha\nbeta\n'
    fi
}

res="$(fallback_session "alpha")"
if [ "$res" != "beta" ]; then
    echo "FAIL: fallback_session with subpane-hub expected 'beta', but got '$res'"
    exit 1
fi

# Test Case 2: When only deleting session and infrastructure session exist, fallback should be empty
tmux() {
    if [ "$1" = "list-sessions" ]; then
        printf 'dotfiles-subpane-hub\nalpha\n'
    fi
}

res="$(fallback_session "alpha")"
if [ -n "$res" ]; then
    echo "FAIL: fallback_session expected empty when only infra session remains, but got '$res'"
    exit 1
fi

# Test Case 3: Normal session fallback when no infra session is at top
tmux() {
    if [ "$1" = "list-sessions" ]; then
        printf 'alpha\nbeta\ngamma\n'
    fi
}

res="$(fallback_session "alpha")"
if [ "$res" != "beta" ]; then
    echo "FAIL: fallback_session normal case expected 'beta', got '$res'"
    exit 1
fi

echo "PASS: fallback_session unit tests"
