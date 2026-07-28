# peco-based ZLE widgets
#
# Queries single `cmd` table — no JOINs, no GROUP BY.
# Since peco has no preview or --expect, metadata is inlined into each line.

histdb-peco() {
    which peco > /dev/null 2>&1 || {
        echo "peco not found"
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
            printf '%s\t[host: %s] [dir: %s] [time: %s] [count: %s] [status: %s]\n' \
                "$argv" "$host" "$dir" "$time" "$count" "$status"
        done |
        peco --layout=bottom-up --query "$LBUFFER")

    if [[ -z "$output" ]]; then
        zle reset-prompt
        return 0
    fi

    LBUFFER="$(_histdb_peco_extract_cmd "$output" "$sep")"
    zle reset-prompt
    return 0
}
zle -N histdb-peco

histdb-top-widget() {
    which peco > /dev/null 2>&1 || {
        echo "peco not found"
        return 1
    }
    _histdb_init
    local sep=$'\t'
    local query="SELECT argv, count FROM cmd ORDER BY count DESC LIMIT 1000"

    local selected
    selected=$(_histdb_query -separator "$sep" "$query" |
        while IFS="$sep" read -r argv count; do
            printf '%s\t[executed: %s times]\n' "$argv" "$count"
        done |
        peco --layout=bottom-up --query "$LBUFFER")

    if [[ -n "$selected" ]]; then
        LBUFFER="$(_histdb_peco_extract_cmd "$selected" "$sep")"
    fi
    zle reset-prompt
    return 0
}
zle -N histdb-top-widget

histdb-peco-tmux() {
    if [[ -n "$TMUX" ]]; then
        tmux popup -d '#{pane_current_path}' -w 80% -h 60% -E \
            "zsh -c 'source ${0:A:h}/zsh-histdb.plugin.zsh && histdb-peco'"
    else
        histdb-peco
    fi
}
zle -N histdb-peco-tmux
