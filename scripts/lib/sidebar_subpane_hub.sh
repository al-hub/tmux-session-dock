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
        local init_pane
        init_pane="$(sidebar_tmux_cmd list-panes -t "=$hub_sess:" -F '#{pane_id}' 2>/dev/null | head -n 1 || true)"
        if [ -n "$init_pane" ]; then
            sidebar_tmux_cmd set-option -p -q -t "$init_pane" @dotfiles_subpane_hub_pane 1 2>/dev/null || true
            sidebar_tmux_cmd set-option -p -q -t "$init_pane" @dotfiles_sidebar_subpane 1 2>/dev/null || true
            sidebar_tmux_cmd set-option -p -q -t "$init_pane" @dotfiles_subpane_slot 1 2>/dev/null || true
            sidebar_tmux_cmd set-option -p -q -t "$init_pane" allow-rename off 2>/dev/null || true
            sidebar_tmux_cmd select-pane -t "$init_pane" -T "${SIDEBAR_SUBPANE_TITLE:-dotfiles-sidebar-subpane}-1" 2>/dev/null || true
        fi
    fi
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
    # If slot > 1 not found, lazily create it in hub session on-demand
    if subpane_hub_is_alive; then
        local hub_sess cmd
        hub_sess="$(subpane_hub_session_name)"
        cmd="$(subpane_hub_default_command)"
        pane_id="$(sidebar_tmux_cmd new-window -d -t "=$hub_sess:" -P -F '#{pane_id}' "$cmd" 2>/dev/null || true)"
        if [ -n "$pane_id" ]; then
            sidebar_tmux_cmd set-option -p -q -t "$pane_id" @dotfiles_subpane_hub_pane 1 2>/dev/null || true
            sidebar_tmux_cmd set-option -p -q -t "$pane_id" @dotfiles_sidebar_subpane 1 2>/dev/null || true
            sidebar_tmux_cmd set-option -p -q -t "$pane_id" @dotfiles_subpane_slot "$slot" 2>/dev/null || true
            sidebar_tmux_cmd set-option -p -q -t "$pane_id" allow-rename off 2>/dev/null || true
            sidebar_tmux_cmd select-pane -t "$pane_id" -T "${SIDEBAR_SUBPANE_TITLE:-dotfiles-sidebar-subpane}-$slot" 2>/dev/null || true
            printf '%s\n' "$pane_id"
            return 0
        fi
    fi
    return 1
}

subpane_hub_get_window_subpanes() {
    local target_win="${1:-}"
    [ -n "$target_win" ] || target_win="$(sidebar_tmux_cmd display-message -p '#{window_id}' 2>/dev/null || true)"
    [ -n "$target_win" ] || return 0

    sidebar_tmux_cmd list-panes -t "$target_win" -F '#{pane_id}|#{@dotfiles_sidebar_subpane}|#{@dotfiles_subpane_slot}' 2>/dev/null |
        awk -F '|' '$2 == "1" { print ($3 ? $3 : 1) "|" $1 }' |
        sort -n -t '|' -k 1 |
        cut -d '|' -f 2
}

subpane_hub_swap_stack_position() {
    local target_win="${1:-}"
    [ -n "$target_win" ] || target_win="$(sidebar_tmux_cmd display-message -p '#{window_id}' 2>/dev/null || true)"
    [ -n "$target_win" ] || return 1

    local launcher_pane
    launcher_pane="$(sidebar_window_pane "$target_win" 2>/dev/null || true)"
    [ -n "$launcher_pane" ] || return 1

    local panes=()
    local heights=()
    local p_id
    while IFS= read -r p_id; do
        [ -n "$p_id" ] || continue
        panes+=("$p_id")
        local p_h
        p_h="$(sidebar_tmux_cmd display-message -p -t "$p_id" '#{pane_height}' 2>/dev/null || echo 6)"
        [ "$p_h" -ge 4 ] 2>/dev/null || p_h=6
        heights+=("$p_h")
    done < <(subpane_hub_get_window_subpanes "$target_win")

    [ "${#panes[@]}" -gt 0 ] || return 0

    local cur_pos
    cur_pos="$(sidebar_subpane_get_position)"
    local new_pos="top"
    if [ "$cur_pos" = "top" ]; then
        new_pos="bottom"
    fi
    sidebar_subpane_set_position "$new_pos"

    local pos_flag=""
    if [ "$new_pos" = "top" ]; then
        pos_flag="-b"
    fi

    local hub_sess
    hub_sess="$(subpane_hub_session_name)"
    if ! subpane_hub_is_alive; then
        subpane_hub_ensure_session
    fi

    # 1. Temporarily park all subpanes to hub session (clean detach)
    for p_id in "${panes[@]}"; do
        sidebar_tmux_cmd join-pane -d -s "$p_id" -t "=$hub_sess:" 2>/dev/null || true
    done

    # 2. Sequentially re-join all subpanes as an atomic stack in the new direction
    local last_attached="$launcher_pane"
    local idx=0
    for p_id in "${panes[@]}"; do
        local slot_h="${heights[$idx]:-6}"
        local slot_pos_flag=""
        if [ "$idx" -eq 0 ] && [ "$new_pos" = "top" ]; then
            slot_pos_flag="-b"
        fi
        if ! sidebar_tmux_cmd join-pane -d $slot_pos_flag -s "$p_id" -t "$last_attached" -v -l "$slot_h" 2>/dev/null; then
            sidebar_tmux_cmd join-pane -d $slot_pos_flag -s "$p_id" -t "$last_attached" -v 2>/dev/null || true
        fi
        sidebar_tmux_cmd resize-pane -t "$p_id" -y "$slot_h" 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$p_id" @dotfiles_subpane_hub_pane 1 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$p_id" @dotfiles_sidebar_subpane 1 2>/dev/null || true
        sidebar_tmux_cmd set-option -p -q -t "$p_id" @dotfiles_subpane_slot "$((idx + 1))" 2>/dev/null || true

        last_attached="$p_id"
        idx=$((idx + 1))
    done

    # Maintain focus on launcher pane
    sidebar_tmux_cmd select-pane -t "$launcher_pane" 2>/dev/null || true
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

    local sub_pos="bottom"
    if declare -f sidebar_subpane_get_position >/dev/null 2>&1; then
        sub_pos="$(sidebar_subpane_get_position 2>/dev/null || echo bottom)"
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
        local slot_pos_flag=""
        if [ "$slot" -eq 1 ] && [ "$sub_pos" = "top" ]; then
            slot_pos_flag="-b"
        fi

        if [ "$current_win" != "$target_win" ]; then
            if ! sidebar_tmux_cmd join-pane -d $slot_pos_flag -s "$slot_pane" -t "$last_attached_pane" -v -l "$slot_h" 2>/dev/null; then
                sidebar_tmux_cmd join-pane -d $slot_pos_flag -s "$slot_pane" -t "$last_attached_pane" -v 2>/dev/null || true
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
