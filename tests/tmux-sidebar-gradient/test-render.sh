#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"
load_launcher_functions

test_gradient_changes_by_frame()
{
    SIDEBAR_ANIMATION_ENABLED=true
    animation_frame=0
    frame_zero="$(print_session_name 'alpha' 8 true 0)"
    animation_frame=1
    frame_one="$(print_session_name 'alpha' 8 true 0)"

    assert_ne "$frame_zero" "$frame_one" 'gradient frame output'
    assert_contains "$frame_zero" $'\033[38;5;' 'gradient ANSI prefix'
    assert_contains "$frame_zero" $'\033[0m' 'gradient ANSI reset'
}

test_idle_name_has_no_gradient()
{
    SIDEBAR_ANIMATION_ENABLED=true
    animation_frame=0
    output="$(print_session_name 'alpha' 8 false 0)"

    assert_eq 'alpha   ' "$output" 'plain padded session name'
    assert_not_contains "$output" $'\033[' 'plain name ANSI sequence'
}

test_animation_can_be_disabled_globally()
{
    # The environment variable is the default the effective configuration is
    # derived from when @session-dock-gradient is unset; sidebar_gradient_apply
    # with two empty values is exactly that case.
    SIDEBAR_ANIMATION_ENABLED=false
    sidebar_gradient_apply '' ''
    animation_frame=0
    output="$(print_session_name 'alpha' 5 true 0)"

    assert_eq 'alpha' "$output" 'globally disabled gradient'
    assert_not_contains "$output" $'\033[' 'disabled gradient ANSI sequence'
}

test_gradient_option_overrides_the_environment_default()
{
    SIDEBAR_ANIMATION_ENABLED=false
    sidebar_gradient_apply 'on' ''
    animation_frame=0
    output="$(print_session_name 'alpha' 8 true 0)"
    assert_contains "$output" $'\033[38;5;' 'option on overrides a disabled default'

    SIDEBAR_ANIMATION_ENABLED=true
    sidebar_gradient_apply 'off' ''
    output="$(print_session_name 'alpha' 5 true 0)"
    assert_eq 'alpha' "$output" 'option off overrides an enabled default'
}

test_animated_cell_matches_static_row_in_narrow_sidebar()
{
    SIDEBAR_ANIMATION_ENABLED=true
    sidebar_gradient_apply '' ''
    animation_frame=0
    scroll_offset=0
    cached_pane_width=15
    cached_pane_height=10
    session_names=(sw1)
    session_created=(100)
    session_status=(idle)
    session_cli_state=(running)
    session_animate=(true)
    session_animation_seed=(0)
    selected_index=0
    selected_session=sw1

    format_row 0
    static_plain="$(strip_ansi <<< "$row_render_result")"
    animated_plain="$(render_animated_name_cells | strip_ansi)"

    assert_contains "$static_plain" 'sw1' 'static compact row shows full name'
    assert_contains "$animated_plain" 'sw1' 'animated cell keeps full name at width 15'

    cached_pane_width=35
    animated_plain="$(render_animated_name_cells | strip_ansi)"
    assert_contains "$animated_plain" 'sw1' 'animated cell keeps full name at width 35'
}

strip_ansi()
{
    sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g'
}

run_test 'renderer changes ANSI colors between frames' test_gradient_changes_by_frame
run_test 'animated name cell matches static row width in narrow sidebar' test_animated_cell_matches_static_row_in_narrow_sidebar
run_test 'renderer omits gradient for idle state' test_idle_name_has_no_gradient
run_test 'renderer respects global animation disable' test_animation_can_be_disabled_globally
run_test 'gradient option overrides the environment default' test_gradient_option_overrides_the_environment_default
finish_tests
