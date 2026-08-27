#!/usr/bin/env bash
# Public attached-PTY contract: a one-step selection is actionable via Enter.
set -euo pipefail

SCENARIO_NAME=keyboard-one-step-switch-contract

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TEST_DIR/test-interactive-common.sh"

setup_interactive_test
tmuxc rename-session -t '=interactive-anchor:' a
tmuxc rename-session -t '=interactive-peer:' b
tmuxc new-session -d -s c -c "$REPO_ROOT" 'sleep 300'
wait_until "three short session rows" "[ -n \"\$(sidebar_row_for a)\" ] && [ -n \"\$(sidebar_row_for b)\" ] && [ -n \"\$(sidebar_row_for c)\" ]"
focus_sidebar

# The fixture fixes a -> b -> c ordering. The Down/Up barrier proves the
# target marker came from this PTY input path before Enter activates it.
wait_for_stable_sidebar_selection a
navigate_sidebar_once $'\033[B' b
navigate_sidebar_once $'\033[B' c
navigate_sidebar_once $'\033[A' b
send_keys $'\r'
wait_until "client switched to b" "wait_session b"
b_window="$(tmuxc display-message -p -t '=b:' '#{window_id}')"
wait_for_settled_presenter_screen "$b_window" b

echo 'PASS: one-step navigation and Enter selected b with a settled Presenter'
