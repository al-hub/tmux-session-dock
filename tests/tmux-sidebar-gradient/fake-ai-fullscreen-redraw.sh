#!/usr/bin/env bash
set -euo pipefail

control_file="$1"
frame="${2:-0}"

while true; do
    case "$(cat "$control_file" 2>/dev/null || printf 'exit')" in
        active)
            case $((frame % 4)) in
                0) spinner='⠋' ;;
                1) spinner='⠙' ;;
                2) spinner='⠹' ;;
                3) spinner='⠸' ;;
            esac
            if [ "$frame" -eq 0 ]; then
                printf 'opencode working'
            fi
            printf '\r%s opencode working %04d' "$spinner" "$frame"
            frame=$((frame + 1))
            sleep 0.1
            ;;
        exit)
            exit 0
            ;;
        *)
            sleep 0.1
            ;;
    esac
done
