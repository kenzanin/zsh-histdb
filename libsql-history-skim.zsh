# skim-based ZLE widgets
#
# Queries single `cmd` table — no JOINs, no GROUP BY.
# Uses skim (fzf-compatible) for preview window, delimiter, and multi-key bindings.

histdb-skim() {
    which sk > /dev/null 2>&1 || {
        echo "sk (skim) not found"
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
        while IFS="$sep" read -r argv host dir time count status; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$argv" "$host" "$dir" "$time" "$count" "$status"
        done |
        sk --no-sort --reverse --tiebreak=index --height 90% \
           --delimiter "$sep" --with-nth 1 \
           --preview "echo -e 'Directory: {3}\nTime: {4}\nCount: {5}\nStatus: {6}' && echo \"{1}\" | bat --language bash --plain --color=always 2>/dev/null || true" \
           --preview-window down:6:wrap \
           --expect=ctrl-j,ctrl-r,ctrl-k \
           --query "$LBUFFER")

    if [[ -z "$output" ]]; then
        zle reset-prompt
        return 0
    fi

    # --expect prepends the key pressed as the first line
    local key="${output%%$'\n'*}"
    local selection="${output#*$'\n'}"

    case "$key" in
        ctrl-j)
            # Directory picker: second skim showing directory field
            local dir_out
            dir_out=$(_histdb_query -separator "$sep" "$query" |
                while IFS="$sep" read -r argv host dir time count status; do
                    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                        "$argv" "$host" "$dir" "$time" "$count" "$status"
                done |
                sk --no-sort --reverse --tiebreak=index --height 90% \
                   --delimiter "$sep" --with-nth 3 \
                   --preview "echo -e 'Directory: {3}\nTime: {4}\nCount: {5}\nStatus: {6}' && echo \"{1}\" | bat --language bash --plain --color=always 2>/dev/null || true" \
                   --preview-window down:6:wrap \
                   --expect=ctrl-j,ctrl-r,ctrl-k \
                   --query "")
            local dir_key="${dir_out%%$'\n'*}"
            local dir_sel="${dir_out#*$'\n'}"
            if [[ -n "$dir_sel" ]]; then
                LBUFFER="$(_histdb_skim_extract_cmd "$dir_sel" "$sep")"
            fi
            ;;
        ctrl-k)
            # Delete command from history
            local cmd
            cmd="$(_histdb_skim_extract_cmd "$selection" "$sep")"
            _histdb_query "DELETE FROM cmd WHERE argv = '$(sql_escape "$cmd")'"
            ;;
        *)
            # Default (Enter, ctrl-r, etc.): insert the command
            LBUFFER="$(_histdb_skim_extract_cmd "$selection" "$sep")"
            ;;
    esac
    zle reset-prompt
    return 0
}
zle -N histdb-skim

histdb-top-widget() {
    which sk > /dev/null 2>&1 || {
        echo "sk (skim) not found"
        return 1
    }
    _histdb_init
    local sep=$'\t'
    local query="SELECT argv, count FROM cmd ORDER BY count DESC LIMIT 1000"

    local selected
    selected=$(_histdb_query -separator "$sep" "$query" |
        while IFS="$sep" read -r argv count; do
            printf '%s\t%s\n' "$argv" "$count"
        done |
        sk --no-sort --reverse --height 90% \
           --delimiter "$sep" --with-nth 1 \
           --preview "echo 'Count: {2}' && echo \"{1}\" | bat --language bash --plain --color=always 2>/dev/null || true" \
           --preview-window down:4:wrap \
           --query "$LBUFFER")

    if [[ -n "$selected" ]]; then
        LBUFFER="$(_histdb_skim_extract_cmd "$selected" "$sep")"
    fi
    zle reset-prompt
    return 0
}
zle -N histdb-top-widget

histdb-skim-tmux() {
    if [[ -n "$TMUX" ]]; then
        tmux popup -d '#{pane_current_path}' -w 80% -h 60% -E \
            "zsh -c 'source ${0:A:h}/zsh-histdb.plugin.zsh && histdb-skim'"
    else
        histdb-skim
    fi
}
zle -N histdb-skim-tmux
