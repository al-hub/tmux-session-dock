#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"
load_launcher_functions

# The tmux stub answers capture-pane with TEST_CAPTURE and rejects the
# pane_activity display-message query, so the fingerprint uses the cached pane
# activity signature when present and falls back to 0 otherwise.
fingerprint_for()
{
    TEST_CAPTURE="$1"
    session_ai_fingerprint_for_pane '%1'
}

test_fingerprint_combines_activity_and_capture()
{
    cached_pane_activity=()
    fp="$(fingerprint_for $'header\nbody')"

    assert_contains "$fp" 'act:0:cap:' 'fingerprint layout without activity signature'

    cached_pane_activity['%1']='1700000000:12:3:4'
    fp="$(fingerprint_for $'header\nbody')"
    cached_pane_activity=()

    assert_contains "$fp" 'act:1700000000:12:3:4:cap:' 'fingerprint carries pane activity signature'
}

test_body_change_updates_fingerprint()
{
    first="$(fingerprint_for $'header\nbody one\nprompt')"
    second="$(fingerprint_for $'header\nbody two\nprompt')"

    assert_ne "$first" "$second" 'body fingerprint change'
}

test_in_place_redraw_updates_fingerprint()
{
    # Full-screen AI CLIs redraw a spinner line in place without touching
    # pane_activity; the capture part of the fingerprint must observe it.
    first="$(fingerprint_for $'header\nbody\n⠋ thinking')"
    second="$(fingerprint_for $'header\nbody\n⠙ thinking')"

    assert_ne "$first" "$second" 'in-place last line redraw'
}

test_blank_lines_and_trailing_space_do_not_change_fingerprint()
{
    first="$(fingerprint_for $'header\n\nbody\nprompt')"
    second="$(fingerprint_for $'header  \nbody\n\n\nprompt\r')"

    assert_eq "$first" "$second" 'blank line and trailing whitespace normalization'
}

test_empty_capture_yields_no_fingerprint()
{
    fp="$(fingerprint_for $'\n   \n')"

    assert_eq '' "$fp" 'empty capture fingerprint'
}

run_test 'fingerprint combines pane activity signature and capture' test_fingerprint_combines_activity_and_capture
run_test 'fingerprint changes with captured body' test_body_change_updates_fingerprint
run_test 'fingerprint changes on in-place last line redraw' test_in_place_redraw_updates_fingerprint
run_test 'fingerprint ignores blank lines and trailing whitespace' test_blank_lines_and_trailing_space_do_not_change_fingerprint
run_test 'fingerprint is empty for an empty capture' test_empty_capture_yields_no_fingerprint
finish_tests
