# AGENT.md — zsh-histdb

## Project Context
Zsh plugin that stores shell history in a distributed rqlite database. Uses ZLE widgets for interactive history search (fzf) and lazy autoload for tool functions.

## Project Structure
```
├── rqlite-history.zsh              # Core (always loaded)
├── rqlite-history-fzf.zsh          # ZLE widgets (histdb-fzf, top-widget)
├── rqlite-history-autosuggest.zsh  # zsh-autosuggestions strategy
├── functions/                      # Autoloaded on first use
│   ├── histdb, histdb-top, histdb-sync
│   ├── histdb-stats, histdb-export
│   ├── histdb-merge, histdb-search
│   └── histdb-import-sqlite
└── zsh-histdb.plugin.zsh          # Entry point
```

## Tooling & Quality Control
- **Linter:** `shellcheck -s bash file.zsh` (use `-s bash` to avoid zsh-ism false positives; still flags real issues)
- **Formatter:** `shfmt -i 4 -w file.zsh` (4-space indent — match project style)
  - Known issue: `shfmt` chokes on zsh `${~var}` glob syntax. Fix those lines manually after formatting.
- **Test:** No test framework exists yet. Verify with `zsh -n file.zsh` for syntax, and `source file.zsh; function_name` for runtime.

## Shell Behavior & Performance
- **Lazy autoload:** Non-ZLE functions go in `functions/` dir, registered with `autoload -Uz funcname`. They load on first call, not at shell startup.
- **ZLE widgets:** Functions bound to keys need `zle -N funcname` at source time. Keep them in sourced files (not autoload).
- **Command hashing:** The plugin re-detects `rlite` at query time (not just init time). Call `rehash` after installing new tools for zsh to find them.
- **Built-ins over externals:** Favor `[[ ]]`, `print -r --`, zsh array ops over `[ ]`, `echo`, external commands.
- **Shebang:** Plugin files are sourced, not executed — omit shebang.

## Syntax Preferences
- `add-zsh-hook` for lifecycle hooks (precmd, zshaddhistory, etc.)
- `local` scoping in every function; avoid global `$options` pollution
- `readonly` for constants (e.g., `HISTDB_SESSION`)
- `typeset -g` for module-level globals (e.g., `typeset -gA HISTDB_CACHE`)
- `sql_escape()` is the canonical quoting function for SQL values
- `zle -N` to register ZLE widgets (must happen at source time, not lazily)

## Development Workflow
1. **Edit:** Changes go in the appropriate file (core vs. fzf vs. functions/)
2. **Syntax check:** `zsh -n file.zsh`
3. **Format:** `shfmt -i 4 -w file.zsh` then manually fix `${~var}` lines if needed
4. **Load test:** `source zsh-histdb.plugin.zsh && histdb-stats` (triggers autoload)
5. **Lint:** `shellcheck -s bash file.zsh`
6. **Commit:** One logical change per commit, descriptive message
