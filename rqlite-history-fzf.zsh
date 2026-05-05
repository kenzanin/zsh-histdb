# fzf-based ZLE widgets

histdb-fzf() {
    which fzf >/dev/null 2>&1 || { echo "fzf not found"; return 1 }
    _histdb_init

    local sep=$'\t'
    local query="SELECT argv, host, dir, time, MAX(duration) as duration FROM (
        SELECT commands.argv as argv, places.host as host, places.dir as dir,
            history.start_time as start_time,
            strftime('%Y-%m-%d %H:%M', history.start_time, 'unixepoch', 'localtime') as time,
            history.duration as duration,
            CASE WHEN places.dir LIKE '$(sql_escape "$PWD")%' THEN 0 ELSE 1 END as _sort_dir
        FROM history
        JOIN commands ON history.command_id = commands.id
        JOIN places ON history.place_id = places.id
    )
    GROUP BY argv, dir
    ORDER BY MIN(_sort_dir), MAX(start_time) DESC
    LIMIT 2000"

    local output
    output=$(_histdb_query -separator "$sep" "$query" | \
        fzf --height 60% \
            --reverse \
            --tiebreak=index \
            --delimiter "$sep" \
            --with-nth 1 \
            --preview "echo -e 'Command: {1}\nHost: {2}\nDirectory: {3}\nTime: {4}\nDuration: {5}s' && which bat >/dev/null 2>&1 && echo '{1}' | bat --plain --language bash --color=always 2>/dev/null || echo ''" \
            --preview-window down:8:wrap \
            --expect=ctrl-j,ctrl-r,ctrl-d \
            --query "$LBUFFER")

    local lines=("${(f)output}")
    if [[ ${#lines[@]} -eq 0 ]]; then
        zle reset-prompt
        return 0
    fi

    local key=""
    local selection=""

    if [[ ${#lines[@]} -eq 1 ]]; then
        selection="${lines[1]}"
    else
        key="${lines[1]}"
        selection="${lines[2]}"
    fi

    if [[ -n "$selection" ]]; then
        case "$key" in
            "ctrl-j")
                local dir=$(echo "$selection" | cut -f3)
                if [[ -n "$dir" && -d "$dir" ]]; then
                    cd "$dir" || return
                fi
                LBUFFER=""
                ;;
            "ctrl-r")
                LBUFFER="${selection%%$sep*}"
                histdb-fzf
                return
                ;;
            "ctrl-d")
                local cmd_to_delete=$(echo "$selection" | cut -f1)
                local dir_to_delete=$(echo "$selection" | cut -f3)
                if [[ -n "$cmd_to_delete" ]]; then
                    _histdb_query "DELETE FROM history WHERE id IN (SELECT h.id FROM history h JOIN commands c ON h.command_id = c.id JOIN places p ON h.place_id = p.id WHERE c.argv='$(sql_escape "$cmd_to_delete")' AND p.dir='$(sql_escape "$dir_to_delete")' LIMIT 1)"
                    zle -M "Deleted: $cmd_to_delete"
                fi
                ;;
            *)
                LBUFFER="${selection%%$sep*}"
                ;;
        esac
    fi

    zle reset-prompt
    return 0
}
zle -N histdb-fzf

histdb-top-widget() {
    _histdb_init
    local sep=$'\t'
    local query="SELECT argv, count FROM (
        SELECT commands.argv as argv, count(*) as count
        FROM history
        JOIN commands ON history.command_id = commands.id
        GROUP BY commands.argv
        ORDER BY count DESC
        LIMIT 1000
    )"

    local selected
    selected=$(_histdb_query -separator "$sep" "$query" | \
        fzf --height 60% \
            --reverse \
            --tiebreak=index \
            --delimiter "$sep" \
            --with-nth 1 \
            --preview "echo -e 'Command: {1}\nExecuted: {2} times'" \
            --query "$LBUFFER")

    if [[ -n "$selected" ]]; then
        LBUFFER="${selected%%$sep*}"
    fi
    zle reset-prompt
    return 0
}
zle -N histdb-top-widget

histdb-fzf-tmux() {
    if [[ -n "$TMUX" ]]; then
        tmux popup -d '#{pane_current_path}' -w 80% -h 60% -E \
            "zsh -c 'source ${0:A:h}/rqlite-history.zsh && histdb-fzf'"
    else
        histdb-fzf
    fi
}
zle -N histdb-fzf-tmux
