#!/usr/bin/env bash
set -euo pipefail

control_file="$1"
frame=0

while true; do
    mode="$(cat "$control_file" 2>/dev/null || printf 'exit')"
    case "$mode" in
        active)
            case $((frame % 4)) in
                0) spinner='⠋' ;;
                1) spinner='⠙' ;;
                2) spinner='⠹' ;;
                3) spinner='⠸' ;;
            esac
            printf 'thinking update %04d\n' "$frame"
            printf '\r%s thinking…' "$spinner"
            frame=$((frame + 1))
            sleep 0.1
            ;;
        waiting)
            sleep 0.1
            ;;
        exit)
            exit 0
            ;;
        *)
            printf '\nunknown control mode: %s\n' "$mode" >&2
            exit 2
            ;;
    esac
done
