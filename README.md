# ZSH History Database

## News

- **06/06/26**: Silent failure when sqld is unreachable (no more jq error spam on every prompt). Default port changed to `51777` to avoid collision with gateway services. Backslash-safe data piping — `echo` replaced with `printf`/`print -r` throughout, fixing history corruption for commands containing backslash-space sequences.

- **05/06/26**: Core engine rewritten from rqlite to **sqld (libSQL) via Hrana3** (`POST /v3/pipeline`). 62 unit tests across 8 test files. Expanded coverage: Hrana3 wire format, argument parsing, history hooks, database init, multi-field search, duration stats.

- **04/06/26**: Added `histdb-info` diagnostics, `histdb-dedup` dedup, sqlean extensions (regexp, stats, etc.), covering indexes on `start_time`, `--regex` search flag, Ctrl-K delete shortcut. Plugin now bundles 14 SQLite extensions in `extension/`.

- **04/05/26**: Added fuzzy history search with `histdb-peco` function (requires peco). Supports Enter to select commands and shows command metadata inline.

## What is this

A zsh plugin that stores shell history into a **sqld database** (libSQL server via Hrana3).

It improves on normal history by storing, for each command:

- Start and stop times
- Working directory
- Hostname
- Per-host session ID (no cross-session confusion)
- Exit status

## Motivation

Fork of [larkery/zsh-histdb](https://github.com/larkery/zsh-histdb) by Tom Hinton — the best zsh history plugin. The original uses a local SQLite file. Rock solid, but single-machine only.

I wanted **shared** history — same history across laptops, desktops, servers. Started with rqlite (distributed SQLite via Raft), later migrated to **sqld** (libSQL server via Hrana3). Then AI agents happened. Sat down with Opencode and deepseek-v4 and just built it. They wrote the code, I drank coffee and pressed Ctrl+R.

This plugin is ~90% AI-generated. I'm the human in the loop with an obsession for good shell history.

## Project Structure

```
zsh-histdb/
├── libsql-history.zsh              # Core (always loaded): query, init, hooks
├── libsql-history-peco.zsh         # ZLE widgets: histdb-peco, histdb-top-widget
├── libsql-history-autosuggest.zsh  # zsh-autosuggestions integration
├── extension/                      # SQLite extensions (sqlean: regexp, stats, ...)
├── functions/                      # Autoloaded on first use (faster startup)
│   ├── histdb                     # histdb command with all filters
│   ├── histdb-top                 # Most frequent commands
│   ├── histdb-sync                # Sync placeholder
│   ├── histdb-stats               # Statistics (median, p95, etc.)
│   ├── histdb-export              # Export to text/JSON
│   ├── histdb-merge               # Merge from another instance
│   ├── histdb-search              # Advanced search (supports --regex)
│   ├── histdb-import-sqlite       # Import SQLite3 db
│   ├── histdb-dedup               # Remove duplicate history entries
│   └── histdb-info                # System diagnostics
├── systemd/
│   └── zshdb.service              # sqld systemd user service
└── zsh-histdb.plugin.zsh          # Entry point (source this)
```

### Zsh Lazy Autoload

Functions in `functions/` are loaded on first use, not at shell startup:

```zsh
# At shell startup: ~90 lines of core code loaded
# First `histdb-stats` call → zsh loads `functions/histdb-stats` from fpath
```

Faster startup — you don't pay for features you don't use.

### Zsh Rehash

When you install a binary while zsh is running:

```zsh
# Without rehash:
which sqld      # → not found (cached from PATH)
# ...
which sqld      # → /home/kenzanin/.local/bin/sqld
```

### Diagnostics

```zsh
histdb-info
```

Shows full system status: plugin path, database records, sqld version/port/status, installed client tools (curl, jq, peco, bat), loaded SQLite extensions, and environment variables.

### History Statistics

```zsh
histdb-stats
```

Total commands, unique commands, most active hosts/directories, duration stats (avg, median, p95, p99).

### Export, Search & Dedup

- `histdb-export [format] [output_file]` — Export to text or JSON
- `histdb-search --date=YYYY-MM-DD --exit=0 --duration=5 --host=name --dir=/path term` — Advanced search
- `histdb-search --regex '^docker\s+(ps|compose)'` — Regex search (requires sqlean extensions)
- `histdb-dedup` — Remove duplicate history entries (same command+dir)
- `histdb-dedup --dry-run` — Preview duplicates without deleting
- `histdb-import-sqlite ~/.histdb/zsh-history.db` — Import from SQLite3 database

### Query Performance

All queries go through **sqld Hrana3 HTTP API** (`POST /v3/pipeline`).

### Integration

- **tmux**: `histdb-peco-tmux` — Opens peco in tmux popup
- **zsh-autosuggestions**: Use `histdb_advanced` strategy for context-aware suggestions
- **ZLE widgets**: `histdb-top-widget` — Browse top commands interactively

## Installation

Requires a running `sqld` server. All queries use **Hrana3 over HTTP** (`curl` + `jq`).

Default sqld URL is `http://127.100.1.2:51777`. Override by setting `HISTDB_LIBSQL_URL`.

Can merge multiple history databases without conflict (as long as machines have different hostnames).

### Quick Install

Install in `$HOME/.oh-my-zsh/custom/plugins/zsh-histdb` (oh-my-zsh not required):

```zsh
git clone -b sqld https://github.com/kenzanin/zsh-histdb \
  $HOME/.oh-my-zsh/custom/plugins/zsh-histdb
```

Add to `~/.zshrc`:

```zsh
source $HOME/.oh-my-zsh/custom/plugins/zsh-histdb/libsql-history.zsh
autoload -Uz add-zsh-hook

# Bind Ctrl+R for fuzzy history search
bindkey '^R' histdb-peco
```

### Running sqld as a systemd User Service

The plugin ships with a systemd user service template at `systemd/zshdb.service`.

Copy it:

```zsh
cp systemd/zshdb.service ~/.config/systemd/user/
```

Then enable and start:

```zsh
systemctl --user daemon-reload
systemctl --user enable --now zshdb.service
```

The service:
- Creates the data directory on startup
- Starts sqld with Hrana3 HTTP on port **51777**
- Loads SQLite extensions from `extension/` (requires `trusted.lst`)
- Restarts on failure
- Starts on login

If you change the port in the service, update `HISTDB_LIBSQL_URL` in `~/.zshrc`:

```zsh
export HISTDB_LIBSQL_URL="http://127.100.1.2:51777"
```

### OS X Note

Add this before sourcing `libsql-history.zsh`:

```zsh
HISTDB_TABULATE_CMD=(sed -e $'s/\x1f/\t/g')
```

### Importing Old History

[go-histdbimport](https://github.com/drewis/go-histdbimport) and [ts-histdbimport](https://github.com/phiresky/ts-histdbimport) are useful tools. Note imported history lacks metadata (working directory, exit status), so `--in DIR` queries won't work.

**Import from SQLite3:**

```zsh
source /path/to/libsql-history.zsh
histdb-import-sqlite ~/.histdb/zsh-history.db
```

Imports: commands (argv), places (host, directory), history entries (timestamps, exit status, duration). Handles NULL values and special characters.

## Configuration

Standard zsh options:

- [HISTORY_IGNORE](https://zsh.sourceforge.io/Doc/Release/Parameters.html#index-HISTORY_005fIGNORE): Glob pattern for commands to ignore (not saved to database). Example: `(ls|cd|top|htop)`.

### Configuration Examples

**oh-my-zsh:**

```zsh
source $ZSH/oh-my-zsh.sh
source ${0:A:h}/libsql-history.zsh
autoload -Uz add-zsh-hook
bindkey '^R' histdb-peco
# Optional: histdb-top widget
zle -N histdb-top-widget
bindkey '^[t' histdb-top-widget
```

**prezto:**

```zsh
source $PREZTO/runcoms/zshrc
source ${0:A:h}/libsql-history.zsh
bindkey '^R' histdb-peco
```

**Basic zsh:**

```zsh
source ~/.local/share/zap/plugins/zsh-histdb/libsql-history.zsh
autoload -Uz add-zsh-hook
bindkey '^R' histdb-peco
```

## Querying History

`histdb` with no args prints one screenful of history on the current host.

Arguments are concatenated and matched. Use `%` as wildcard (like `*`):

```zsh
histdb this%that   # matches "this" followed by "that" with any chars between
```

See `histdb --help` for filtering by host, directory, session, time.

`histdb-top` shows most frequent commands. `histdb-top dir` shows favourite directory.

### Example

```text
$ histdb strace
time   ses  dir  cmd
17/03  438  ~    strace conkeror
22/03  522  ~    strace apropos cake
22/03  522  ~    strace -e trace=file s
22/03  522  ~    strace -e trace=file ls
22/03  522  ~    strace -e trace=file cat temp/people.vcf
22/03  522  ~    strace -e trace=file cat temp/gammu.log
22/03  522  ~    run-help strace
24/03  547  ~    man strace
```

Use `--limit 1000` for more results. `ses` column is the session number — all `522` rows are from one shell session.

### Integration with zsh-autosuggestions

Configure [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) to search histdb:

```sh
_zsh_autosuggest_strategy_histdb_top_here() {
    local query="select commands.argv from
  history left join commands on history.command_id = commands.rowid
  left join places on history.place_id = places.rowid
  where places.dir LIKE '$(sql_escape $PWD)%'
  and commands.argv LIKE '$(sql_escape $1)%'
  group by commands.argv order by count(*) desc limit 1"
    suggestion=$(_histdb_query "$query")
}

ZSH_AUTOSUGGEST_STRATEGY=histdb_top_here
```

This finds the most frequent command in the current directory/subdirectory. Alternative — prefer exact directory, then fall back to global:

```sh
_zsh_autosuggest_strategy_histdb_top() {
    local query="
        select commands.argv from history
        left join commands on history.command_id = commands.rowid
        left join places on history.place_id = places.rowid
        where commands.argv LIKE '$(sql_escape $1)%'
        group by commands.argv, places.dir
        order by places.dir != '$(sql_escape $PWD)', count(*) desc
        limit 1
    "
    suggestion=$(_histdb_query "$query")
}

ZSH_AUTOSUGGEST_STRATEGY=histdb_top
```

## Fuzzy History Search with peco

`histdb-peco` — fuzzy finder over sqld history database. Replaces traditional reverse-isearch.

### Setup

```zsh
bindkey '^R' histdb-peco   # Ctrl+R for fuzzy search
# or
bindkey '^[r' histdb-peco  # Alt+R to keep default Ctrl+R
```

### Usage

- **Enter** — Insert command into buffer
- **Ctrl-C** — Cancel

Shows: command with host, directory, timestamp inline.

### Requirements

- `peco` installed and in PATH
- Must be bound as a ZLE widget (not run directly)

## Up/Down Prefix Search

`_histdb-up-line-or-beginning-search` / `_histdb-down-line-or-beginning-search` replace zsh's default prefix search. Type a prefix (`ssh`) and press Up — queries sqld for matching commands, sorted by recency (current host first).

### Setup

```zsh
bindkey '^[[A' _histdb-up-line-or-beginning-search
bindkey '^[[B' _histdb-down-line-or-beginning-search
```

### Behavior

- **Up** — Query histdb for commands matching buffer prefix; press repeatedly to cycle
- **Down** — Cycle back to newer matches; restores original prefix at start
- **Empty buffer + Up** — Shows most recent commands from current host
- **Prefix match** — Queries across all hosts, prefers current host
- **Cached cycling** — Results cached after first query; Up/Down cycles without re-querying

## SQLite Extensions

sqld loads SQLite extensions via `--extensions-path` (requires `trusted.lst`).

| Extension | Feature | Used by |
|---|---|---|
| **regexp** | Regular expression search | `histdb-search --regex` |
| **stats** | Median, percentile | `histdb-stats` |
| **fuzzy** | Fuzzy string matching | Search |
| **text** | String functions | Import/export |
| **uuid** | Unique ID generation | Session management |

Extensions bundle in `extension/`. Restart sqld to load:

```zsh
systemctl --user restart zshdb.service
```

Usage:

```zsh
# regex search
histdb-search --regex '^docker\s+(ps|compose)'

# stats with median/percentile
histdb-stats
```

## Database Schema

Data lives in your sqld server. Query directly:

```zsh
_histdb_query "SELECT name FROM sqlite_master WHERE type='table'"
```

Or pass `-d` to `histdb` to print the SQL it's running.

## Troubleshooting

### sqld connection issues

1. Check if sqld is running:
   ```zsh
   curl -s -o /dev/null -w "%{http_code}" http://127.100.1.2:51777/v3/pipeline \
     -X POST -H "Content-Type: application/json" -d '{}'
   ```

2. Verify the URL:
   ```zsh
   echo $HISTDB_LIBSQL_URL
   ```

3. Check systemd service:
   ```zsh
   systemctl --user status zshdb.service
   ```

### jq errors on every prompt

If you see `jq: error` spam after every command, sqld is unreachable. The plugin now handles this gracefully (errors suppressed), but history won't record. Fix the server.

### histdb-peco not working

1. Check peco:
   ```zsh
   which peco
   ```

2. Verify keybinding:
   ```zsh
   bindkey | grep histdb
   ```

3. Test the widget:
   ```zsh
   zle -l histdb-peco
   ```

### Database issues

1. Check tables exist:
   ```zsh
   _histdb_query "SELECT name FROM sqlite_master WHERE type='table'"
   ```

2. Reinitialize if needed:
   ```zsh
   unset HISTDB_SESSION
   _histdb_init
   ```

## Synchronising History

sqld handles data persistence in standalone mode. No git-based sync needed.

## Completion

None, and the underscores mean something else.

## Pull Requests / Missing Features

Happy to look at changes.
