# ZSH History Database

## News

- **06/05/26**: Added `histdb-info` diagnostics, `histdb-dedup` dedup, sqlean extensions (regexp, stats, etc.), covering indexes on `start_time`, `--regex` search flag, Ctrl-K delete shortcut. Plugin now bundles 14 SQLite extensions in `extension/`.

- **04/05/26**: Added fuzzy history search with `histdb-fzf` function (requires fzf). Supports Enter to select commands and Ctrl-J to jump to the command's directory. Added systemd user service setup for rqlite. Converted README from org to Markdown.

## What is this
This is a zsh plugin that stores shell history into a sqld database (libSQL server via Hrana3).

It stores your history into a sqld database.
It improves on the normal history by storing, for each history command:

- The start and stop times of the command
- The working directory where the command was run
- The hostname of the machine
- A unique per-host session ID, so history from several sessions is not confused
- The exit status of the command

## Motivation

This is a fork of [larkery/zsh-histdb](https://github.com/larkery/zsh-histdb) by Tom Hinton — the best zsh history plugin out there. The original uses a local SQLite file. Rock solid, but single-machine only.

I wanted something **shared** — same history across laptops, desktops, servers. Started with rqlite (distributed SQLite via Raft), later migrated to sqld (libSQL server via Hrana3). Then AI agents happened. So I sat down with Opencode and Deepseek/deepseek-v4-flash and just built it. They wrote the code, I drank coffee and pressed Ctrl+R.

This plugin is 90% AI-generated. I'm just the human in the loop with an obsession for good shell history.

## Project Structure

```
zsh-histdb/
├── libsql-history.zsh              # Core (always loaded): query, init, hooks, cache
├── libsql-history-fzf.zsh          # ZLE widgets: histdb-fzf, histdb-top-widget
├── libsql-history-autosuggest.zsh  # zsh-autosuggestions integration
├── extension/                      # SQLite extensions (sqlean: regexp, stats, etc.)
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
│   └── histdb-info                # System diagnostics & info
└── zsh-histdb.plugin.zsh          # Entry point (source this)
```

### Zsh Lazy Autoload

Functions in `functions/` are **loaded on first use**, not at shell startup:

```zsh
# At shell startup: only ~90 lines of core code loaded
# When you first type `histdb-stats` → zsh loads `functions/histdb-stats` from fpath
```

This means faster shell startup - you don't pay for features you don't use.

### Zsh Rehash

When you install a binary while zsh is running:

```zsh
# Without rehash:
which sqld      # → not found (cached from PATH)
...
which sqld      # → /home/kenzanin/.local/bin/sqld
```

All queries go through sqld Hrana3 HTTP API (`POST /v3/pipeline`) — no direct SQLite access needed.

Shows full system status: plugin path, database records, sqld version/port/status, installed client tools (curl, jq, fzf, bat), loaded SQLite extensions, and environment variables.

```zsh
histdb-info
```

### History Statistics (`histdb-stats`)

View total commands, unique commands, most active hosts/directories, and duration stats (avg, median, p95, p99).

```zsh
histdb-stats
```

### Export, Search & Dedup

- `histdb-export [format] [output_file]` - Export to text or JSON
- `histdb-search --date=YYYY-MM-DD --exit=0 --duration=5 --host=name --dir=/path term` - Advanced search
- `histdb-search --regex '^docker\s+(ps|compose)'` - Regex search (requires sqlean extensions)
- `histdb-dedup` - Remove duplicate history entries (same command+dir)
- `histdb-dedup --dry-run` - Preview duplicates without deleting
- `histdb-import-sqlite ~/.histdb/zsh-history.db` - Import from SQLite3 database

### Query Performance

All queries go through **sqld Hrana3 HTTP API** (`POST /v3/pipeline`).

### Integration

- **tmux**: `histdb-fzf-tmux` - Opens fzf in tmux popup
- **zsh-autosuggestions**: Use `histdb_advanced` strategy for context-aware suggestions
- **ZLE widgets**: `histdb-top-widget` - browse top commands interactively

## Installation

You will need a running `sqld` server. All queries use **Hrana3 over HTTP**:

- **`curl` + `jq`** — sends `POST /v3/pipeline` with JSON body

Default sqld URL is `http://127.100.1.2:8080`. Change it by setting `HISTDB_LIBSQL_URL`.

It is also possible to merge multiple history databases together without conflict, so long as all your machines have different hostnames.

### Quick Install

Example for installing in `$HOME/.oh-my-zsh/custom/plugins/zsh-histdb` (note that `oh-my-zsh` is not required):

```zsh
mkdir -p $HOME/.oh-my-zsh/custom/plugins/
git clone -b experimental https://github.com/kenzanin/zsh-histdb $HOME/.oh-my-zsh/custom/plugins/zsh-histdb
```

Add this to your `$HOME/.zshrc`:

```zsh
source $HOME/.oh-my-zsh/custom/plugins/zsh-histdb/libsql-history.zsh
autoload -Uz add-zsh-hook

 # Optional: Bind histdb-fzf to Ctrl+R for fuzzy history search
bindkey '^R' histdb-fzf
```

### Running sqld as a systemd User Service

Create `~/.config/systemd/user/zshdb.service`:

```ini
[Unit]
Description=zshdb server (sqld)
After=network.target

[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/zshdb_data
ExecStart=%h/.local/bin/sqld \
    -d %h/.local/share/zshdb_data/sqld.db \
    --http-listen-addr 127.100.1.2:8080 \
    --extensions-path %h/.local/share/zap/plugins/zsh-histdb/extension
Restart=on-failure
RestartSec=5
WorkingDirectory=%h/.local/share/zshdb_data

[Install]
WantedBy=default.target
```

Then enable and start:

```bash
systemctl --user daemon-reload
systemctl --user enable --now zshdb.service
```

**Note:** Make sure the path to `sqld` is correct. Check with:

```bash
which sqld  # e.g., /home/kenzanin/.local/bin/sqld
```

This service will:
- Create the data directory on startup
- Start sqld with Hrana3 HTTP on port 8080
- Load SQLite extensions from the plugin's extension directory (requires `trusted.lst`)
- Automatically restart on failure
- Automatically start sqld on boot (user login)

**Note:** The systemd service and `HISTDB_LIBSQL_URL` are independent. If you change the port in the systemd service, you must manually update `HISTDB_LIBSQL_URL` in your `~/.zshrc` to match:

```bash
export HISTDB_LIBSQL_URL="http://127.100.1.2:8080"
```

The default URL is already set to `http://127.100.1.2:8080` in `libsql-history.zsh`, so you only need to set `HISTDB_LIBSQL_URL` if you use a different port or remote server.

### Note for OS X users

Add the following line before you source `sqlite-history.zsh`. See [https://github.com/larkery/zsh-histdb/pull/31](https://github.com/larkery/zsh-histdb/pull/31) for details.

```zsh
HISTDB_TABULATE_CMD=(sed -e $'s/\x1f/\t/g')
```

### Importing your old history

[go-histdbimport](https://github.com/drewis/go-histdbimport) and [ts-histdbimport](https://github.com/phiresky/ts-histdbimport) are useful tools for doing this! Note that the imported history will not include metadata such as the working directory or the exit status, since that is not stored in the normal history file format, so queries using `--in DIR`, etc. will not work as expected.

**Import from SQLite3:**

If you have an existing `~/.histdb/zsh-history.db` (or other SQLite database), use the built-in import function:

```zsh
source /home/kenzanin/.local/share/zap/plugins/zsh-histdb/libsql-history.zsh
histdb-import-sqlite ~/.histdb/zsh-history.db
```

This imports:
- Commands (argv)
- Places (host, directory)
- History entries (with timestamps, exit status, duration)

The import handles NULL values and escapes special characters properly.

## Configuration

histdb can be configured exactly as zsh:
- [HISTORY_IGNORE](https://zsh.sourceforge.io/Doc/Release/Parameters.html#index-HISTORY_005fIGNORE): If set, is treated as a single glob pattern to match the commands that should be ignored. Ignored commands are not saved to the database. Example: `(ls|cd|top|htop)`.

### Configuration Examples

**oh-my-zsh**:
```zsh
source $ZSH/oh-my-zsh.sh
source ${0:A:h}/libsql-history.zsh
autoload -Uz add-zsh-hook
bindkey '^R' histdb-fzf
# Optional: histdb-top widget
zle -N histdb-top-widget
bindkey '^[t' histdb-top-widget
```

**prezto**:
```zsh
source $PREZTO/runcoms/zshrc
source ${0:A:h}/libsql-history.zsh
bindkey '^R' histdb-fzf
```

**Basic zsh**:
```zsh
source ~/.local/share/zap/plugins/zsh-histdb/libsql-history.zsh
autoload -Uz add-zsh-hook
bindkey '^R' histdb-fzf
```

## Querying history

You can query the history with the `histdb` command.
With no arguments it will print one screenful of history on the current host.

With arguments, it will print history lines matching their concatenation.

For wildcards within a history line, you can use the `%` character, which is like the shell glob `*`, so `histdb this%that` will match any history line containing `this` followed by `that` with zero or more characters in-between.

To search on particular hosts, directories, sessions, or time periods, see the help with `histdb --help`.

You can also run `histdb-top` to see your most frequent commands, and `histdb-top dir` to show your favourite directory for running commands in, but these commands are really a bit useless.

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

These are all the history entries involving `strace` in my history.
If there was more than one screenful, I would need to say `--limit 1000` or some other large number.
The command does not warn you if you haven't seen all the results.
The `ses` column contains a unique session number, so all the `522` rows are from the same shell session.

To see all hosts, add `--host` /after/ the query terms.
To see a specific host, add `--host hostname`.
To see all of a specific session say e.g. `-s 522 --limit 10000`.

### Integration with `zsh-autosuggestions`

If you use [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) you can configure it to search the history database instead of the zsh history file thus:

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

This query will find the most frequently issued command that is issued in the current directory or any subdirectory. You can get other behaviours by changing the query, for example:

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

This will find the most frequently issued command issued exactly in this directory, or if there are no matches it will find the most frequently issued command in any directory. You could use other fields like the hostname to restrict to suggestions on this host, etc.

## Fuzzy History Search with fzf

The main interactive history search is `histdb-fzf` — a fuzzy finder over your sqld history database. It replaces traditional reverse-isearch.

### Setup

Add this to your `~/.zshrc`:

```zsh
bindkey '^R' histdb-fzf  # Use Ctrl+R for fuzzy history search
```

Or if you want to keep the default Ctrl+R for normal history search:

```zsh
bindkey '^[r' histdb-fzf  # Use Alt+R instead
```

### Usage

- **Enter** - Inserts the selected command into the command line
- **Ctrl-J** - Jumps (cd) to the directory where that command was run
- **Ctrl-K** - Delete the selected entry from history
- **Ctrl-C** - Cancel without selecting

The fzf interface shows:

- Command history with preview
- Host information
- Directory where command was run
- Timestamp of execution

### Requirements

- `fzf` must be installed and available in your PATH
- Works as a ZLE widget (must be bound to a key, cannot be run as a command)

## Up/Down Prefix History Search

The `_histdb-up-line-or-beginning-search` and `_histdb-down-line-or-beginning-search` widgets replace zsh's default `up-line-or-beginning-search` / `down-line-or-beginning-search`. When you type a prefix (like `ssh`) and press Up, they query the sqld database for commands starting with that prefix, sorted by recency (current host first).

### Setup

Bind to Up/Down arrows in your `~/.zshrc`:

```zsh
bindkey '^[[A' _histdb-up-line-or-beginning-search
bindkey '^[[B' _histdb-down-line-or-beginning-search
```

### Behavior

- **Up** — Query histdb for commands matching the current buffer prefix; press repeatedly to cycle older matches
- **Down** — Cycle back to newer matches; at the start, restore the original prefix text
- **Empty buffer + Up** — Shows most recent commands from current host
- **Prefix match** — Queries across all hosts, but prefers current host results first
- **Cached cycling** — Once results are fetched, Up/Down cycles the cached set without re-querying

## SQLite Extensions

sqld supports loading SQLite extensions via the `--extensions-path` flag (requires `trusted.lst`). Prebuilt extensions enhance search and statistics:

| Extension | Feature | Used by |
|---|---|---|
| **regexp** | Regular expression search | `histdb-search --regex` |
| **stats** | Median, percentile, etc. | `histdb-stats` |
| **fuzzy** | Fuzzy string matching | Search |
| **text** | String functions | Import/export |
| **uuid** | Unique ID generation | Session management |

To install (included in plugin):
```zsh
# Extensions are already in <plugin-dir>/extension/
systemctl --user restart zshdb.service
```

Usage:
```zsh
# regex search
histdb-search --regex '^docker\s+(ps|compose)'

# stats with median/percentile
histdb-stats
```

## Database schema

The database lives in your sqld server.
You can look in it easily by running `_histdb_query "sql..."`.

For inspiration you can also use `histdb` with the `-d` argument and it will print the SQL it's running.

## Troubleshooting

### sqld connection issues

If you get connection errors:

1. Check if sqld is running:
   ```zsh
   curl -s -o /dev/null -w "%{http_code}" http://127.100.1.2:8080/v3
   ```

2. Verify the URL is correct:
   ```zsh
   echo $HISTDB_LIBSQL_URL
   ```

3. Check systemd service status:
   ```zsh
   systemctl --user status zshdb.service
   ```

### histdb-fzf not working

1. Make sure fzf is installed:
   ```zsh
   which fzf
   ```

2. Verify the keybinding is set:
   ```zsh
   bindkey | grep histdb
   ```

3. Test the function directly:
   ```zsh
   zle -l histdb-fzf
   ```

### Database issues

1. Check if tables exist:
   ```zsh
   _histdb_query "SELECT name FROM sqlite_master WHERE type='table'"
   ```

2. Reinitialize if needed:
   ```zsh
   unset HISTDB_SESSION
   _histdb_init
   ```

## Synchronising history

sqld handles data persistence automatically in standalone mode.
There is no need for manual git-based synchronization of the database file.

## Completion

None, and I've used the names with underscores to mean something else.

## Pull requests / missing features

Happy to look at changes.
I did at one point have a reverse-isearch thing in here for searching the database interactively, but it didn't really make my life any better so I deleted it.
