# Enhanced zsh-autosuggestions integration
#
# Queries single `cmd` table — no JOINs, no GROUP BY.

_zsh_autosuggest_strategy_histdb_advanced() {
    local query=""
    local current_dir="$PWD"
    local search="$1"

    # First try: exact match in current directory
    query="SELECT argv FROM cmd
        WHERE argv LIKE '$(sql_escape "$search")%'
        AND last_dir = '$(sql_escape "$current_dir")'
        ORDER BY count DESC, wtime DESC
        LIMIT 1"

    suggestion=$(_histdb_query "$query")

    # Fallback: any directory
    if [[ -z "$suggestion" ]]; then
        query="SELECT argv FROM cmd
            WHERE argv LIKE '$(sql_escape "$search")%'
            ORDER BY count DESC, wtime DESC
            LIMIT 1"
        suggestion=$(_histdb_query "$query")
    fi
}

# To use: ZSH_AUTOSUGGEST_STRATEGY=histdb_advanced
