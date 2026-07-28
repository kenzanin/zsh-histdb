# zsh-histdb

Zsh plugin that stores shell history in a sqld (libSQL server) database. Uses ZLE widgets for interactive history search (skim) and lazy autoload for tool functions.

## Files

```
zsh-histdb.plugin.zsh          # Entry point
libsql-history.zsh             # Core engine (always loaded)
libsql-history-skim.zsh        # ZLE widgets (histdb-skim, top-widget)
libsql-history-autosuggest.zsh # zsh-autosuggestions strategy
functions/                     # Autoloaded CLI functions
tests/                         # ZUnit tests
```

## Architecture

- `_histdb_query()` — central query function, routes via Hrana3 HTTP to sqld
- Database: `commands`, `places`, `history` tables
- All queries go through sqld Hrana3 API (POST /v3/pipeline)
