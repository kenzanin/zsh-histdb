# zsh-histdb plugin entry point

# Core: always loaded (query, init, hooks)
source "${0:A:h}/rqlite-history.zsh"

# FZF ZLE widgets: always loaded (needs zle -N at source time)
source "${0:A:h}/rqlite-history-fzf.zsh"

# Autosuggest integration: always loaded (needs to be available for ZSH_AUTOSUGGEST_STRATEGY)
source "${0:A:h}/rqlite-history-autosuggest.zsh"

# Autoloaded functions: loaded on first use (not at shell startup)
fpath+=( "${0:A:h}/functions" )
autoload -Uz histdb histdb-top histdb-sync histdb-stats histdb-export histdb-merge histdb-search histdb-import-sqlite histdb-dedup histdb-info
