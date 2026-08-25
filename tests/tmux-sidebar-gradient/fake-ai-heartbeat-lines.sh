#!/usr/bin/env bash
set -euo pipefail

control_file="$1"
heartbeat_file="$2"
frame=0

while true; do
    mode="$(cat "$control_file" 2>/dev/null || printf 'exit')"
    case "$mode" in
        active)
            printf '%s\n' "$(date +%s%N)" > "$heartbeat_file"
            printf 'working %04d thinking\n' "$frame"
            frame=$((frame + 1))
            sleep 0.1
            ;;
        waiting) sleep 0.1 ;;
        exit) exit 0 ;;
        *) exit 2 ;;
    esac
done
