#!/usr/bin/env bash
set -euo pipefail
SCENARIO_NAME=rename-roundtrip
export SCENARIO_NAME
source "$(dirname -- "$BASH_SOURCE")/test-interactive-common.sh"

setup_interactive_test
tmuxc rename-session -t '=interactive-anchor:' a
tmuxc rename-session -t '=interactive-peer:' b
tmuxc new-session -d -s c -c "$REPO_ROOT" 'sleep 300'
wait_until "three short session rows" "[ -n \"\$(sidebar_row_for a)\" ] && [ -n \"\$(sidebar_row_for b)\" ] && [ -n \"\$(sidebar_row_for c)\" ]"
focus_sidebar
wait_for_stable_sidebar_selection a
navigate_sidebar_once $'\033[B' b
navigate_sidebar_once $'\033[B' c
navigate_sidebar_once $'\033[A' b
send_keys $'\r'
wait_until "client switched to b" "wait_session b"
before_sidebar="$(sidebar_pane_id)"

send_keys r
wait_prompt Rename:
send_keys 'renamed-b'
send_keys $'\r'
wait_until "renamed-b exists" "wait_session_exists 'renamed-b'"
wait_until "old b removed" "wait_session_absent b"
wait_until "renamed client session" "wait_session 'renamed-b'"
renamed_window="$(tmuxc display-message -p -t '=renamed-b:' '#{window_id}')"
wait_for_settled_presenter_screen "$renamed_window" renamed-b
[ "$(sidebar_pane_id)" = "$before_sidebar" ]
echo "PASS: attached-PTY one-step switch renamed b with a settled Presenter"
