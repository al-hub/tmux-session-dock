#!/usr/bin/env bash
set -euo pipefail

# Read-only diagnostic for a live tmux server.  It is intentionally excluded
# from run.sh: unlike the isolated E2E suites, it asserts the user's current
# live Codex session rather than creating a fixture.

TARGET_SESSION="${TMUX_SESSION_GRADIENT_SESSION:-$(tmux display-message -p '#S')}"
SAMPLE_SECONDS="${TMUX_SESSION_GRADIENT_SAMPLE_SECONDS:-12}"

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

sidebar="$(tmux list-panes -t "=$TARGET_SESSION:" -F '#{pane_id}|#{pane_title}' |
    awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }')"
[ -n "$sidebar" ] || fail_test "no sidebar pane in session $TARGET_SESSION"

ai_pane="$(tmux list-panes -t "=$TARGET_SESSION:" -F '#{pane_id}|#{pane_current_command}|#{pane_title}' |
    awk -F'|' '$2 == "node" && $3 != "dotfiles-session-sidebar" { print $1; exit }')"
[ -n "$ai_pane" ] || fail_test "no node-based Codex pane in session $TARGET_SESSION"

deadline=$(( $(date +%s) + SAMPLE_SECONDS ))
previous_screen=""
screen_changed=false
gradient_seen=false
session_row_seen=false
while [ "$(date +%s)" -lt "$deadline" ]; do
    screen="$(tmux capture-pane -p -J -t "$ai_pane" -S -8 | cksum | awk '{print $1}')"
    [ -n "$previous_screen" ] && [ "$screen" != "$previous_screen" ] && screen_changed=true
    previous_screen="$screen"

    frame="$(tmux capture-pane -e -p -t "$sidebar")"
    session_row="$(printf '%s\n' "$frame" | awk -v session="$TARGET_SESSION" '$0 ~ session { print; exit }')"
    if [ -n "$session_row" ]; then
        session_row_seen=true
        if printf '%s' "$session_row" | grep -Fq '38;5;'; then
            gradient_seen=true
            break
        fi
    fi
    sleep 1
done

[ "$screen_changed" = true ] || fail_test "node-based Codex pane $ai_pane did not redraw during ${SAMPLE_SECONDS}s"
[ "$session_row_seen" = true ] || fail_test "sidebar $sidebar never rendered the $TARGET_SESSION row"
[ "$gradient_seen" = true ] || fail_test "redrawing node-based Codex pane $ai_pane never received gradient ANSI output"

printf 'PASS: live node-based Codex pane redraws with sidebar gradient\n'
