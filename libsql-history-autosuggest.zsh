# Enhanced zsh-autosuggestions integration

_zsh_autosuggest_strategy_histdb_advanced() {
    local query=""
    local current_dir="$PWD"
    local search="$1"

    # First try: exact match in current directory
    query="SELECT commands.argv FROM history
        LEFT JOIN commands ON history.command_id = commands.id
        LEFT JOIN places ON history.place_id = places.id
        WHERE commands.argv LIKE '$(sql_escape "$search")%'
        AND places.dir = '$(sql_escape "$current_dir")'
        GROUP BY commands.argv
        ORDER BY count(*) DESC
        LIMIT 1"

    suggestion=$(_histdb_query "$query")

    # Fallback: any directory
    if [[ -z "$suggestion" ]]; then
        query="SELECT commands.argv FROM history
            LEFT JOIN commands ON history.command_id = commands.id
            WHERE commands.argv LIKE '$(sql_escape "$search")%'
            GROUP BY commands.argv
            ORDER BY count(*) DESC
            LIMIT 1"
        suggestion=$(_histdb_query "$query")
    fi
}

# To use: ZSH_AUTOSUGGEST_STRATEGY=histdb_advanced
