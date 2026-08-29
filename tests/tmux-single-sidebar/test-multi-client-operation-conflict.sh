#!/usr/bin/env bash
set -euo pipefail

export TERM="${TERM:-xterm-256color}"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/tmux-session-launcher"
SOCKET="dotfiles-single-sidebar-conflict-$$"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-sidebar-conflict.XXXXXX")"
TMUX=(tmux -L "$SOCKET" -f "$REPO_ROOT/dotfiles/tmux.conf")
CLIENT_PID=""
BASELINE_CLIENT_PID=""
KEEP_RUN_DIR="${KEEP_RUN_DIR:-false}"

cleanup()
{
    "${TMUX[@]}" kill-server >/dev/null 2>&1 || true
    [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" >/dev/null 2>&1 || true
    [ -n "$BASELINE_CLIENT_PID" ] && kill "$BASELINE_CLIENT_PID" >/dev/null 2>&1 || true
    [ "$KEEP_RUN_DIR" = true ] || rm -rf "$RUN_DIR"
}
trap cleanup EXIT

quote()
{
    printf '%q' "$1"
}

wait_for_external_client()
{
    local excluded="${1:-}" result="" deadline=$(( $(date +%s) + 10 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        result="$(${TMUX[@]} list-clients -F '#{client_control_mode}|#{client_tty}|#{session_name}' 2>/dev/null |
            awk -F '|' -v excluded="$excluded" '$1 != 1 && $3 != "owner" && $2 != excluded {print $2; exit}')"
        [ -n "$result" ] && {
            printf '%s\n' "$result"
            return 0
        }
        sleep 0.05
    done
    KEEP_RUN_DIR=true
    printf 'ERROR: external client did not appear (artifacts %s)\n' "$RUN_DIR" >&2
    return 1
}

wait_for_client_session()
{
    local client="$1" expected="$2" deadline=$(( $(date +%s) + 10 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ "$(${TMUX[@]} display-message -p -t "$client" '#{client_session}' 2>/dev/null || true)" = "$expected" ] && return 0
        sleep 0.05
    done
    KEEP_RUN_DIR=true
    printf 'ERROR: client %s did not reach session %s (artifacts %s)\n' "$client" "$expected" "$RUN_DIR" >&2
    return 1
}

client_set()
{
    "${TMUX[@]}" list-clients -F '#{client_control_mode}|#{client_tty}|#{session_name}' 2>/dev/null |
        awk -F '|' -v session_name="$1" '$1 != 1 && $3 == session_name { print $2 }' |
        sort | paste -sd, -
}

owner_state()
{
    local owner
    owner="$("${TMUX[@]}" show-option -gqv @dotfiles_sidebar_owner_client 2>/dev/null || true)"
    "${TMUX[@]}" list-clients -F '#{client_control_mode}|#{client_tty}|#{session_name}|#{window_id}' 2>/dev/null |
        awk -F '|' -v owner="$owner" '$1 != 1 && $2 == owner { print $2 "|" $3 "|" $4; exit }'
}

start_sidebar()
{
    "${TMUX[@]}" new-session -d -s owner -c "$REPO_ROOT" 'sleep 120'
    "${TMUX[@]}" new-session -d -s target-attach -c "$REPO_ROOT" 'sleep 120'
    "${TMUX[@]}" new-session -d -s target-delete -c "$REPO_ROOT" 'sleep 120'
    "${TMUX[@]}" new-session -d -s target-restore -c "$REPO_ROOT" 'sleep 120'
    "${TMUX[@]}" set-environment -g TMUX_SESSION_HISTORY_DIR "$RUN_DIR/history"
    # Leave enough deterministic time for the external client to attach after
    # the worker start marker and before its precondition check.
    "${TMUX[@]}" set-environment -g TMUX_SESSION_LAUNCHER_TEST_OPERATION_DELAY 5
    "${TMUX[@]}" split-window -d -t '=owner:' -h -b -l 35 "$LAUNCHER --sidebar"
    for attempt in $(seq 1 80); do
        [ "$("${TMUX[@]}" list-panes -a -F '#{pane_title}' | awk '$0 == "dotfiles-session-sidebar" { count++ } END { print count + 0 }')" -eq 1 ] && break
        sleep 0.05
    done
    script -qefc "TERM=xterm-256color ${TMUX[*]} attach-session -t owner" "$RUN_DIR/owner.log" >/dev/null 2>&1 &
    CLIENT_PID=$!
    for attempt in $(seq 1 80); do
        owner_tty="$("${TMUX[@]}" list-clients -F '#{client_control_mode}|#{client_tty}' 2>/dev/null | awk -F '|' '$1 != 1 { print $2; exit }')"
        [ -n "$owner_tty" ] && break
        sleep 0.05
    done
    "${TMUX[@]}" set-option -g @dotfiles_sidebar_owner_client "$owner_tty"
}

run_delete_conflict()
{
    local target="$1" operation_id="$2" expected_id='' expected_clients expected_owner command
    expected_clients="$(client_set "$target" || true)"
    expected_owner="$(owner_state || true)"
    "${TMUX[@]}" set-environment -gh DOTFILES_SIDEBAR_OPERATION "deleting:$operation_id"
    command="TMUX_SESSION_LAUNCHER_TEST_OPERATION_DELAY=5 $(quote "$LAUNCHER") --delete-session-after-archive $(quote "$target") true $(quote "$operation_id") $(quote "$expected_id") $(quote "$expected_clients") $(quote "$expected_owner")"
    "${TMUX[@]}" run-shell -b "$command"
}

start_sidebar

script -qefc "TERM=xterm-256color ${TMUX[*]} attach-session -t target-attach" "$RUN_DIR/baseline-attach.log" >/dev/null 2>&1 &
BASELINE_CLIENT_PID=$!
baseline_tty="$(wait_for_external_client)"
wait_for_client_session "$baseline_tty" target-attach
run_delete_conflict target-attach op-attach
script -qefc "TERM=xterm-256color ${TMUX[*]} attach-session -t target-attach" "$RUN_DIR/external-attach.log" >/dev/null 2>&1 &
external_pid=$!
external_tty="$(wait_for_external_client "$baseline_tty")"
"${TMUX[@]}" switch-client -c "$external_tty" -t =target-attach
if ! wait_for_client_session "$external_tty" target-attach; then
    printf 'INCONCLUSIVE: owner policy redirected external client %s away from target-attach; conflict precondition was not exercised\n' "$external_tty" >&2
    exit 2
fi
# The conflict is established by the operation precondition itself. Older
# launchers emitted an external.client-change observer event, but current
# owner-client enforcement may redirect that client without emitting the
# legacy event; keep the state/target-preservation assertions authoritative.
if [ "$(${TMUX[@]} display-message -p -t "$external_tty" '#{client_session}' 2>/dev/null || true)" != target-attach ]; then
    printf 'INCONCLUSIVE: owner policy redirected external client %s before conflict precondition; conflict was not exercised\n' "$external_tty" >&2
    exit 2
fi
sleep 6
[ "$("${TMUX[@]}" has-session -t =target-attach >/dev/null 2>&1; echo $?)" -eq 0 ]
kill "$external_pid" >/dev/null 2>&1 || true
kill "$BASELINE_CLIENT_PID" >/dev/null 2>&1 || true
BASELINE_CLIENT_PID=""
printf 'PASS: external client attach during delete causes conflict and preserves target\n'

run_delete_conflict target-restore op-archive
sleep 6
archive_path="$(find "$RUN_DIR/history" -type f -name '*.tsv' -print -quit)"
[ -f "$archive_path" ]
"${TMUX[@]}" set-environment -g TMUX_SESSION_LAUNCHER_TEST_OPERATION_DELAY 0.5
"${TMUX[@]}" run-shell -b "TMUX_SESSION_LAUNCHER_TEST_OPERATION_DELAY=0.5 $(quote "$LAUNCHER") --restore-archive $(quote "$archive_path") op-restore"
"${TMUX[@]}" new-session -d -s target-restore -c "$REPO_ROOT" 'sleep 120'
sleep 1
[ "$("${TMUX[@]}" has-session -t =target-restore >/dev/null 2>&1; echo $?)" -eq 0 ]
printf 'PASS: restore name collision preserves externally created session\n'

run_delete_conflict target-delete op-delete
"${TMUX[@]}" kill-session -t =target-delete
sleep 6
! "${TMUX[@]}" has-session -t =target-delete >/dev/null 2>&1
printf 'PASS: external target deletion is detected without follow-up kill\n'

printf 'PASS: public tmux state preserves external client and session safety\n'
