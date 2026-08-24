#!/usr/bin/env bash
# SubpaneHubManager: Global Singleton Subpane Session & Mirror Management
set -euo pipefail

SUBPANE_HUB_SESSION="dotfiles-subpane-hub"
SUBPANE_LEASE_OPTION="@dotfiles_subpane_lease_window"
SUBPANE_COUNT_OPTION="@session-dock-subpane-count"

subpane_hub_get_count() {
    local cnt
    cnt="$(sidebar_tmux_cmd show-option -gqv "$SUBPANE_COUNT_OPTION" 2>/dev/null || true)"
    case "$cnt" in
        2|3) printf '%s\n' "$cnt" ;;
        *)   printf '1\n' ;;
    esac
}

subpane_hub_set_count() {
    local cnt="${1:-1}"
    case "$cnt" in
        2|3) sidebar_tmux_cmd set-option -gq "$SUBPANE_COUNT_OPTION" "$cnt" 2>/dev/null || true ;;
        *)   sidebar_tmux_cmd set-option -gq "$SUBPANE_COUNT_OPTION" 1 2>/dev/null || true ;;
    esac
}

subpane_hub_get_lease_holder() {
    sidebar_tmux_cmd show-option -gqv "$SUBPANE_LEASE_OPTION" 2>/dev/null || true
}

subpane_hub_acquire_lease() {
    local target_win="${1:-}"
    [ -n "$target_win" ] || return 1
    sidebar_tmux_cmd set-option -gq "$SUBPANE_LEASE_OPTION" "$target_win" 2>/dev/null || true
}

subpane_hub_release_lease() {
    local target_win="${1:-}"
    local current_holder
    current_holder="$(subpane_hub_get_lease_holder)"
    if [ -z "$target_win" ] || [ "$current_holder" = "$target_win" ]; then
        sidebar_tmux_cmd set-option -gu "$SUBPANE_LEASE_OPTION" 2>/dev/null || true
    fi
}

subpane_hub_session_name() {
    printf '%s\n' "$SUBPANE_HUB_SESSION"
}

subpane_hub_default_command() {
    local zdot="${HOME}/.cache/dotfiles"
    if [ -x "/bin/zsh" ]; then
        printf 'exec env ZDOTDIR="%s" /bin/zsh\n' "$zdot"
    else
        printf 'exec env ZDOTDIR="%s" %s\n' "$zdot" "${SHELL:-/bin/bash}"
    fi
}

subpane_hub_is_alive() {
    if sidebar_tmux_cmd has-session -t "=$(subpane_hub_session_name):" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

subpane_hub_ensure_session() {
    local hub_sess
    hub_sess="$(subpane_hub_session_name)"
    if ! subpane_hub_is_alive; then
        local zdot="${HOME}/.cache/dotfiles"
        mkdir -p "$zdot" 2>/dev/null || true
        if [ ! -f "$zdot/.zshrc" ]; then
            cat <<'EOF' > "$zdot/.zshrc" 2>/dev/null || true
PROMPT='$ '
RPROMPT=''
autoload -Uz compinit 2>/dev/null || true
compinit -u 2>/dev/null || true
EOF
        fi
        local cmd
        cmd="$(subpane_hub_default_command)"
        sidebar_tmux_cmd new-session -d -s "$hub_sess" -n "hub" -x 30 -y 12 "$cmd" 2>/dev/null || true
        sidebar_tmux_cmd set-option -t "=$hub_sess:" remain-on-exit off 2>/dev/null || true
        sidebar_tmux_cmd set-option -s -t "$hub_sess" @dotfiles_sidebar_managed 0 2>/dev/null || true
        sidebar_tmux_cmd set-hook -t "$hub_sess" -u window-linked 2>/dev/null || true
        sidebar_tmux_cmd set-hook -t "$hub_sess" -u window-unlinked 2>/dev/null || true
        sidebar_tmux_cmd set-hook -t "$hub_sess" -u session-created 2>/dev/null || true
        sidebar_tmux_cmd set-hook -t "$hub_sess" -u client-session-changed 2>/dev/null || true
        sleep 0.2
    fi

    # Ensure slot panes (1..3) exist in hub session or server
    local slot
    for slot in 1 2 3; do
        local slot_pane
        slot_pane="$( (sidebar_tmux_cmd list-panes -a -F '#{pane_id}|#{@dotfiles_subpane_slot}' 2>/dev/null || true) | awk -F '|' -v s="$slot" '$2 == s { print $1; exit }')"
        if [ -z "$slot_pane" ]; then
            if [ "$slot" -eq 1 ]; then
                slot_pane="$(sidebar_tmux_cmd list-panes -t "=$hub_sess:" -F '#{pane_id}' 2>/dev/null | head -n 1 || true)"
            else
                local cmd
                cmd="$(subpane_hub_default_command)"
                slot_pane="$(sidebar_tmux_cmd new-window -d -t "=$hub_sess:" -P -F '#{pane_id}' "$cmd" 2>/dev/null || true)"
            fi
            if [ -n "$slot_pane" ]; then
                sidebar_tmux_cmd set-option -p -q -t "$slot_pane" @dotfiles_subpane_hub_pane 1 2>/dev/null || true
                sidebar_tmux_cmd set-option -p -q -t "$slot_pane" @dotfiles_sidebar_subpane 1 2>/dev/null || true
                sidebar_tmux_cmd set-option -p -q -t "$slot_pane" @dotfiles_subpane_slot "$slot" 2>/dev/null || true
                sidebar_tmux_cmd set-option -p -q -t "$slot_pane" allow-rename off 2>/dev/null || true
                sidebar_tmux_cmd select-pane -t "$slot_pane" -T "${SIDEBAR_SUBPANE_TITLE:-dotfiles-sidebar-subpane}-$slot" 2>/dev/null || true
            fi
        fi
    done
}

subpane_hub_get_pane() {
    local slot="${1:-1}"
    local pane_id
    # Search for specific slot pane across server
    pane_id="$( (sidebar_tmux_cmd list-panes -a -F '#{pane_id}|#{@dotfiles_subpane_slot}' 2>/dev/null || true) | awk -F '|' -v s="$slot" '$2 == s { print $1; exit }')"
    if [ -n "$pane_id" ]; then
        printf '%s\n' "$pane_id"
        return 0
    fi
    # Fallback to general hub pane
    pane_id="$( (sidebar_tmux_cmd list-panes -a -F '#{pane_id}|#{@dotfiles_subpane_hub_pane}' 2>/dev/null || true) | awk -F '|' '$2 == "1" { print $1; exit }')"
    if [ -n "$pane_id" ]; then
        printf '%s\n' "$pane_id"
        return 0
    fi
    return 1
}

subpane_hub_relocate_pane_atomic() {
    local sub_pane="${1:-}" target_launcher="${2:-}" height="${3:-}"
    [ -n "$sub_pane" ] && [ -n "$target_launcher" ] || return 1
    local sub_title="${SIDEBAR_SUBPANE_TITLE:-dotfiles-sidebar-subpane}"

    if [ -z "$height" ] || ! [ "$height" -ge 4 ] 2>/dev/null; then
        local saved_h
        if declare -f sidebar_subpane_get_height >/dev/null 2>&1; then
            saved_h="$(sidebar_subpane_get_height || true)"
        else
            local opt="${SIDEBAR_SUBPANE_HEIGHT_OPTION:-@dotfiles_sidebar_subpane_height}"
            saved_h="$(sidebar_tmux_cmd show-option -gqv "$opt" 2>/dev/null || true)"
        fi
        if [ -n "$saved_h" ] && [ "$saved_h" -ge 4 ] 2>/dev/null; then
            height="$saved_h"
        else
            height=12
        fi
    fi
    local target_win
    target_win="$(sidebar_tmux_cmd display-message -p -t "$target_launcher" '#{window_id}' 2>/dev/null || true)"
    [ -n "$target_win" ] && subpane_hub_acquire_lease "$target_win"

    if [ -z "$height" ]; then
        local saved_h
        if declare -f sidebar_subpane_get_height >/dev/null 2>&1; then
            saved_h="$(sidebar_subpane_get_height 2>/dev/null || true)"
        fi
        if [ -n "$saved_h" ] && [ "$saved_h" -ge 4 ] 2>/dev/null; then
            height="$saved_h"
        else
            height=12
        fi
    fi

    local sub_pos="bottom" pos_flag=""
    if declare -f sidebar_subpane_get_position >/dev/null 2>&1; then
        sub_pos="$(sidebar_subpane_get_position 2>/dev/null || echo bottom)"
    fi
    if declare -f sidebar_subpane_calc_pos_flag >/dev/null 2>&1; then
        pos_flag="$(sidebar_subpane_calc_pos_flag "$sub_pos")"
    elif [ "$sub_pos" = "top" ]; then
        pos_flag="-b"
    fi

    local join_l="$height"
    if declare -f sidebar_subpane_calc_join_length >/dev/null 2>&1; then
        join_l="$(sidebar_subpane_calc_join_length "$sub_pos" "$height")"
    elif [ "$pos_flag" = "-b" ]; then
        join_l="$((height + 1))"
    fi

    if ! sidebar_tmux_cmd join-pane -d $pos_flag -s "$sub_pane" -t "$target_launcher" -v -l "$join_l" 2>/dev/null; then
        sidebar_tmux_cmd join-pane -d $pos_flag -s "$sub_pane" -t "$target_launcher" -v 2>/dev/null || return 1
    fi

    if [ -n "$height" ] && [ "$height" -ge 4 ] 2>/dev/null; then
        sidebar_tmux_cmd resize-pane -t "$sub_pane" -y "$join_l" 2>/dev/null || true
    fi

    # Keep role tags immutable
    sidebar_tmux_cmd set-option -p -q -t "$sub_pane" @dotfiles_subpane_hub_pane 1 2>/dev/null || true
    sidebar_tmux_cmd set-option -p -q -t "$sub_pane" @dotfiles_sidebar_subpane 1 2>/dev/null || true
    return 0
}

subpane_hub_acquire_pane() {
    local target_launcher="$1" height="${2:-}" sub_title="${3:-dotfiles-sidebar-subpane}"
    [ -n "$target_launcher" ] || return 1

    local max_count
    max_count="$(subpane_hub_get_count)"
    [ -n "$max_count" ] || max_count=1

    if [ -z "$height" ]; then
        local saved_h
        if declare -f sidebar_subpane_get_height >/dev/null 2>&1; then
            saved_h="$(sidebar_subpane_get_height 2>/dev/null || true)"
        fi
        if [ -n "$saved_h" ] && [ "$saved_h" -ge 4 ] 2>/dev/null; then
            height="$saved_h"
        else
            height=14
        fi
    fi

    subpane_hub_ensure_session

    local target_win
    target_win="$(sidebar_tmux_cmd display-message -p -t "$target_launcher" '#{window_id}' 2>/dev/null || true)"
    [ -n "$target_win" ] || return 1

    local sub_pos="bottom" pos_flag=""
    if declare -f sidebar_subpane_get_position >/dev/null 2>&1; then
        sub_pos="$(sidebar_subpane_get_position 2>/dev/null || echo bottom)"
    fi
    if [ "$sub_pos" = "top" ]; then
        pos_flag="-b"
    fi

    # Calculate proportional height per slot
    local slot_h
    slot_h="$((height / max_count))"
    [ "$slot_h" -ge 4 ] || slot_h=4

    local slot last_attached_pane="$target_launcher" first_pane=""
    for ((slot=1; slot<=max_count; slot++)); do
        local slot_pane
        slot_pane="$(subpane_hub_get_pane "$slot" || true)"
        if [ -z "$slot_pane" ]; then
            subpane_hub_ensure_session
            slot_pane="$(subpane_hub_get_pane "$slot" || true)"
        fi
        [ -n "$slot_pane" ] || continue

        local current_win
        current_win="$(sidebar_tmux_cmd display-message -p -t "$slot_pane" '#{window_id}' 2>/dev/null || true)"
        if [ "$current_win" != "$target_win" ]; then
            if ! sidebar_tmux_cmd join-pane -d $pos_flag -s "$slot_pane" -t "$last_attached_pane" -v -l "$slot_h" 2>/dev/null; then
                sidebar_tmux_cmd join-pane -d $pos_flag -s "$slot_pane" -t "$last_attached_pane" -v 2>/dev/null || true
            fi
        fi

        sidebar_tmux_cmd resize-pane -t "$slot_pane" -y "$slot_h" 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$slot_pane" allow-rename off 2>/dev/null || true
        sidebar_tmux_cmd select-pane -t "$slot_pane" -T "${sub_title}-$slot" 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$slot_pane" @dotfiles_subpane_hub_pane 1 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$slot_pane" @dotfiles_sidebar_subpane 1 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$slot_pane" @dotfiles_subpane_slot "$slot" 2>/dev/null || true

        [ -z "$first_pane" ] && first_pane="$slot_pane"
        last_attached_pane="$slot_pane"
    done

    # Maintain focus on target launcher
    sidebar_tmux_cmd select-pane -t "$target_launcher" 2>/dev/null || true
    local client_tty
    while IFS= read -r client_tty; do
        [ -n "$client_tty" ] || continue
        sidebar_tmux_cmd select-pane -t "$target_launcher" -c "$client_tty" 2>/dev/null || true
    done < <(sidebar_tmux_cmd list-clients -F '#{client_tty}' 2>/dev/null || true)

    subpane_hub_acquire_lease "$target_win"
    printf '%s\n' "${first_pane:-$target_launcher}"
}

subpane_hub_release_pane() {
    local sub_pane="${1:-}"
    local target_win=""
    if [ -n "$sub_pane" ]; then
        target_win="$(sidebar_tmux_cmd display-message -p -t "$sub_pane" '#{window_id}' 2>/dev/null || true)"
    fi
    [ -n "$target_win" ] || target_win="$(sidebar_tmux_cmd display-message -p '#{window_id}' 2>/dev/null || true)"
    [ -n "$target_win" ] && subpane_hub_release_lease "$target_win"

    local hub_sess
    hub_sess="$(subpane_hub_session_name)"
    if ! subpane_hub_is_alive; then
        subpane_hub_ensure_session
    fi

    # Find all subpanes in the target window or server and return to hub
    local p_id p_win p_sess
    while IFS='|' read -r p_id p_win p_sess; do
        [ -n "$p_id" ] || continue
        [ "$p_sess" != "$hub_sess" ] || continue
        sidebar_tmux_cmd set-option -p -q -t "$p_id" @dotfiles_subpane_hub_pane 1 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$p_id" @dotfiles_sidebar_subpane 1 2>/dev/null || true
        sidebar_tmux_cmd join-pane -d -s "$p_id" -t "=$hub_sess:" 2>/dev/null || true
    done < <(sidebar_tmux_cmd list-panes -a -F '#{pane_id}|#{window_id}|#{session_name}|#{@dotfiles_sidebar_subpane}' 2>/dev/null | awk -F '|' '$4 == "1" { print $1"|"$2"|"$3 }')
}

subpane_hub_destroy() {
    local slot
    for slot in 1 2 3; do
        local slot_pane
        slot_pane="$(subpane_hub_get_pane "$slot" || true)"
        if [ -n "$slot_pane" ]; then
            sidebar_tmux_cmd kill-pane -t "$slot_pane" 2>/dev/null || true
        fi
    done
    if subpane_hub_is_alive; then
        sidebar_tmux_cmd kill-session -t "=$(subpane_hub_session_name):" 2>/dev/null || true
    fi
}
