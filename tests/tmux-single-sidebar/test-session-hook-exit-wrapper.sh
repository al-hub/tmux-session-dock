#!/usr/bin/env bash
set -u

session_name="${1:-}"
launcher="${TMUX_KEYBOARD_E2E_HOOK_LAUNCHER:-}"
log_file="${TMUX_KEYBOARD_E2E_HOOK_LOG:-}"
start_ms="$(date +%s%3N)"

if [ -z "$session_name" ] || [ -z "$launcher" ] || [ -z "$log_file" ]; then
    exit 64
fi

"$launcher" --ensure-sidebar-session "$session_name" >/dev/null 2>"$log_file.stderr"
rc=$?
end_ms="$(date +%s%3N)"
printf '%s\t%s\t%s\t%s\n' "$start_ms" "$session_name" "$rc" "$end_ms" >> "$log_file"
exit "$rc"
