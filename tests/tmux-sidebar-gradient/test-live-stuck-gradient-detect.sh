#!/usr/bin/env bash
set -euo pipefail

# Read-only diagnostic for a live tmux server. It detects an observer state
# that remains animated after the corresponding AI pane has stopped changing.
# This is excluded from run.sh because it intentionally examines an existing
# user session rather than an isolated fixture.

PRESENTER_SESSION="${TMUX_SESSION_GRADIENT_PRESENTER_SESSION:-tmux-sessiondock}"
STALE_SESSION="${TMUX_SESSION_GRADIENT_STALE_SESSION:-bbbbbbbbbb}"
SETTLE_SECONDS="${TMUX_SESSION_GRADIENT_SETTLE_SECONDS:-12}"
VERIFY_SECONDS="${TMUX_SESSION_GRADIENT_VERIFY_SECONDS:-4}"

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

sidebar="$(tmux list-panes -t "=$PRESENTER_SESSION:" -F '#{pane_id}|#{pane_title}' |
    awk -F'|' '$2 == "dotfiles-session-sidebar" { print $1; exit }')"
[ -n "$sidebar" ] || fail_test "no sidebar pane in presenter session $PRESENTER_SESSION"

ai_pane="$(tmux list-panes -t "=$STALE_SESSION:" -F '#{pane_id}|#{pane_current_command}|#{pane_title}' |
    awk -F'|' '$2 ~ /^(codex|claude|gemini|opencode|ollama|agy)$/ && $3 != "dotfiles-session-sidebar" { print $1; exit }')"
[ -n "$ai_pane" ] || fail_test "no AI CLI pane in stale session $STALE_SESSION"

deadline=$(( $(date +%s) + SETTLE_SECONDS ))
previous_screen=""
screen_changed=false
while [ "$(date +%s)" -lt "$deadline" ]; do
    screen="$(tmux capture-pane -p -J -t "$ai_pane" -S -8 | cksum | awk '{print $1}')"
    [ -n "$previous_screen" ] && [ "$screen" != "$previous_screen" ] && screen_changed=true
    previous_screen="$screen"

    sleep 1
done

[ "$screen_changed" = false ] || fail_test "AI pane $ai_pane changed during the idle observation window"

# The production observer's idle grace is ten seconds.  Once the unchanged
# pane has settled beyond that period, any remaining gradient is stale state.
for sample in $(seq 1 "$VERIFY_SECONDS"); do
    frame="$(tmux capture-pane -e -p -t "$sidebar")"
    stale_row="$(printf '%s\n' "$frame" | awk -v session="$STALE_SESSION" '$0 ~ session { print; exit }')"
    if printf '%s' "$stale_row" | grep -Fq '38;5;'; then
        fail_test "idle AI pane $ai_pane retained gradient after ${SETTLE_SECONDS}s idle grace"
    fi
    sleep 1
done

printf 'PASS: idle AI pane does not retain a stuck sidebar gradient\n'
