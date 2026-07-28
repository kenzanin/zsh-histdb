# zsh-histdb Codebase Exploration

## Overview

Fork of [larkery/zsh-histdb](https://github.com/larkery/zsh-histdb) by Tom Hinton, modified to use **sqld** (libSQL server via Hrana3 over HTTP). Stores shell history with metadata: timestamps, working directory, hostname, session ID, exit status, duration.

## Project Structure

```
zsh-histdb/
├── zsh-histdb.plugin.zsh              # Entry point (sources all other files)
├── libsql-history.zsh                  # Core engine (always loaded)
├── libsql-history-peco.zsh # peco ZLE widgets
├── libsql-history-autosuggest.zsh      # zsh-autosuggestions integration
├── functions/                          # Autoloaded CLI functions (faster startup)
│   ├── histdb                         # Query history with filters
│   ├── histdb-dedup                   # Remove duplicate entries
│   ├── histdb-export                  # Export to text/JSON
│   ├── histdb-import-sqlite           # Import from SQLite3 file
│   ├── histdb-info                    # System diagnostics
│   ├── histdb-merge                   # Merge from another sqld node
│   ├── histdb-search                  # Advanced search (--regex support)
│   ├── histdb-stats                   # Statistics (median, p95, p99)
│   ├── histdb-sync                    # Sync placeholder
│   └── histdb-top                     # Most frequent commands/dirs
├── extension/                         # 14 prebuilt SQLite .so extensions
├── tests/                             # ZUnit test framework
│   ├── _support/bootstrap
│   ├── search.zunit
│   ├── sql_escape.zunit
│   └── stats.zunit
└── logs/                              # Runtime logs
```

## Architecture

### Core Engine (`libsql-history.zsh`)
- **`_histdb_query`** — Central query dispatcher. Routes SQL via Hrana3 HTTP (POST /v3/pipeline with curl+jq).
- **`_histdb_query_curl`** — Single-statement Hrana3 execute. Sends `{"type":"execute","stmt":{"sql":"..."}}` via pipeline. Converts Hrana3 tagged Value objects to plain text output.
- **`_histdb_query_curl_sequence`** — Multi-statement Hrana3 sequence request. For batch INSERT/UPDATE operations.
- **`_histdb_init`** — Idempotent DB init. Creates tables (`commands`, `places`, `history`) on first run. Assigns unique per-host session ID.
- **`_histdb_addhistory`** — `zshaddhistory` hook. Saves each command with start_time, host, PWD. Filters out boring prefixes (`ls`, `cd`, `histdb`, space). Runs async (`&|`).
- **`_histdb_update_outcome`** — `precmd` hook. Updates exit_status and duration for the most recent history entry. Runs async.
- **`_histdb-up-line-or-beginning-search`** — ZLE widget for Up arrow. Queries sqld for commands matching buffer prefix (or all commands if buffer empty). Caches results for cycling.
- **`_histdb-down-line-or-beginning-search`** — ZLE widget for Down arrow. Cycles back through cached results.

### Database Schema
```sql
commands (id INTEGER PK, argv TEXT UNIQUE)
places   (id INTEGER PK, host TEXT, dir TEXT, UNIQUE(host, dir))
history  (id INTEGER PK, session INT, command_id FK, place_id FK,
          exit_status INT, start_time INT, duration INT)
```

### Query Patterns
| Pattern | SQL | Used By |
|---------|-----|---------|
| Prefix LIKE | `WHERE argv LIKE 'prefix%'` | Up/Down, autosuggest |
| Group by argv | `GROUP BY argv ORDER BY MAX(start_time) DESC` | Up/Down, peco |
| Current host first | `ORDER BY MAX(CASE WHEN host='X'...` | Up/Down |
| Current dir first | `ORDER BY CASE WHEN dir LIKE 'PWD%'...` | peco |

## Bug Fix: Up Arrow Caching (2026-06-03)

**File:** `libsql-history.zsh`

**Problem:** The Up arrow caching condition checked `-n "$HISTDB_PREFIX_QUERY"` which is false for empty strings. When pressing Up on an empty prompt:
1. First Up → queries all history → caches → sets `prefix=""` → shows first result
2. Second Up → `-n ""` is false → cache **skipped** → re-queries with current buffer as prefix → only matches the single result → stuck on 1 item

**Fix:**
```zsh
# Before (broken):
if [[ -n "$HISTDB_PREFIX_QUERY" && "$prefix" == "$HISTDB_PREFIX_QUERY"* ]]; then

# After (fixed):
if (( ${#HISTDB_PREFIX_RESULTS[@]} > 0 )) && [[ "$prefix" == "$HISTDB_PREFIX_QUERY"* ]]; then
```

Changed the gate from "is the query string non-empty?" to **"do we have cached results?"**.

## Database (sqld)
- **URL:** `http://127.100.1.2:8080` (default)
- **Daemon:** `sqld` running via systemd user service `zshdb.service`
- **Data dir:** `~/.local/share/zshdb_data/sqld.db/`
- **Stats:** ~1500 commands, ~1900 history entries, ~130 places
- **Mode:** standalone (single node, no replication)
- **Protocol:** Hrana3 over HTTP (`POST /v3/pipeline`)
- **Extensions:** 14 SQLite extensions loaded via `trusted.lst` (regexp, stats, fuzzy, uuid, etc.)

## Key Bindings (configured in `.zshrc`)
- **Ctrl+R** — `histdb-peco` (fuzzy interactive history search)
- **Up arrow** — `_histdb-up-line-or-beginning-search` (prefix-based history cycling)
- **Down arrow** — `_histdb-down-line-or-beginning-search` (cycle back)

## Shell Hooks
- `zshaddhistory` → `_histdb_addhistory` (save command to sqld)
- `precmd` → `_histdb_update_outcome` (record exit status + duration)

## Notable Details
- Commands starting with `ls`, `cd`, `histdb`, or space are **not saved** by default (configurable via `_BORING_PREFIX`)
- All queries go through Hrana3 HTTP API (`POST /v3/pipeline`) — no local SQLite file access
- History is saved **asynchronously** (`&|`) — never blocks the prompt
- SQL errors are mostly suppressed (`2>/dev/null`)
- Autoloaded functions in `functions/` load on first use, not at shell startup
- 14 SQLite extensions bundled in `extension/` for regex, stats, fuzzy matching, etc.
