#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"
load_launcher_functions

declare -gA TEST_FINGERPRINT_BY_PANE=()

session_ai_fingerprint_for_pane()
{
    printf '%s\n' "${TEST_FINGERPRINT_BY_PANE[$1]:-}"
}

test_running_state_tracks_observed_ai_activity()
{
    set_single_ai_session test %1 codex
    TEST_FINGERPRINT_BY_PANE['%1']='fp-a'

    collect_sessions
    assert_eq running "${session_cli_state[0]}" 'initial AI activity state'
    assert_eq true "${session_animate[0]}" 'initial animation state'

    collect_sessions
    assert_eq running "${session_cli_state[0]}" 'single stable sample AI activity state'
    assert_eq true "${session_animate[0]}" 'single stable sample animation state'

    collect_sessions
    assert_eq running "${session_cli_state[0]}" 'stable fingerprint remains running inside grace'
    assert_eq true "${session_animate[0]}" 'stable fingerprint retains gradient inside grace'

    TEST_FINGERPRINT_BY_PANE['%1']='fp-b'
    collect_sessions false test
    assert_eq running "${session_cli_state[0]}" 'changed fingerprint AI activity state'
    assert_eq true "${session_animate[0]}" 'changed fingerprint animation state'
}

test_shell_only_session_is_gone()
{
    set_single_ai_session test %1 bash
    collect_sessions

    assert_eq gone "${session_cli_state[0]}" 'shell-only AI activity state'
    assert_eq false "${session_animate[0]}" 'shell-only animation state'
}

run_test 'running state tracks observed AI activity without waiting' test_running_state_tracks_observed_ai_activity
run_test 'shell-only session has no tracked AI activity' test_shell_only_session_is_gone
finish_tests
