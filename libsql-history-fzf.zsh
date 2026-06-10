# fzf-based ZLE widgets
#
# Queries single `cmd` table — no JOINs, no GROUP BY.
# Ctrl+K deletes the row from cmd (removes command entirely).

histdb-fzf() {
    which fzf > /dev/null 2>&1 || {
        echo "fzf not found"
        return 1
    }
    _histdb_init

    local sep=$'\t'
    local query="SELECT argv, last_host as host, last_dir as dir,
        strftime('%Y-%m-%d %H:%M', wtime, 'unixepoch', 'localtime') as time,
        count, status
    FROM cmd
    $(_histdb_order_sort)
    LIMIT 2000"

    local output
    output=$(_histdb_query -separator "$sep" "$query" |
        fzf --height 90% \
            --no-sort \
            --reverse \
            --tiebreak=index \
            --delimiter "$sep" \
            --with-nth 1 \
            --preview "echo -e 'Directory: {3}\nTime: {4}\nCount: {5}\nStatus: {6}' && echo "{1}" | bat --language bash --plain --color=always 2>/dev/null || true" \
            --preview-window down:6:wrap \
            --expect=ctrl-j,ctrl-r,ctrl-k \
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
            local dir
            dir=$(_histdb_fzf_extract_field "$selection" "$sep" 3)
            if [[ -n "$dir" && -d "$dir" ]]; then
                cd "$dir" || return
            fi
            LBUFFER=""
            ;;
        "ctrl-r")
            LBUFFER="$(_histdb_fzf_extract_cmd "$selection" "$sep")"
            histdb-fzf
            return
            ;;
        "ctrl-k")
            local cmd_to_delete
            cmd_to_delete=$(_histdb_fzf_extract_cmd "$selection" "$sep")
            if [[ -n "$cmd_to_delete" ]]; then
                _histdb_query "DELETE FROM cmd WHERE argv = '$(sql_escape "$cmd_to_delete")'" > /dev/null 2>&1
                zle -M "Deleted: $cmd_to_delete"
            fi
            ;;
        *)
            LBUFFER="$(_histdb_fzf_extract_cmd "$selection" "$sep")"
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
    local query="SELECT argv, count FROM cmd ORDER BY count DESC LIMIT 1000"

    local selected
    selected=$(_histdb_query -separator "$sep" "$query" |
        fzf --height 60% \
            --reverse \
            --tiebreak=index \
            --delimiter "$sep" \
            --with-nth 1 \
            --preview "echo -e 'Command: {1}\nExecuted: {2} times'" \
            --query "$LBUFFER")

    if [[ -n "$selected" ]]; then
        LBUFFER="$(_histdb_fzf_extract_cmd "$selected" "$sep")"
    fi
    zle reset-prompt
    return 0
}
zle -N histdb-top-widget

histdb-fzf-tmux() {
    if [[ -n "$TMUX" ]]; then
        tmux popup -d '#{pane_current_path}' -w 80% -h 60% -E \
            "zsh -c 'source ${0:A:h}/libsql-history.zsh && histdb-fzf'"
    else
        histdb-fzf
    fi
}
zle -N histdb-fzf-tmux
