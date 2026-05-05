# ZSH History Database

## News

- **05/05/26**: Refactored into modular files with zsh lazy autoload. Core (~90 lines) always loaded; tools (`histdb`, `histdb-stats`, etc.) autoloaded on first use for faster shell startup. Added rlite C client support for faster queries.

- **04/05/26**: Added fuzzy history search with `histdb-fzf` function (requires fzf). Supports Enter to select commands and Ctrl-J to jump to the command's directory. Added systemd user service setup for rqlite. Converted README from org to Markdown. Fixed various syntax errors and optimized code.
- **13/10/21**: Thanks to Aloxaf some subshell invocations have been removed which should make things quicker. Thanks to m42e (again) `histdb-sync` uses the remote database IDs as the canonical ones which should make syncing a bit less thrashy. Thanks to Chad Transtrum we use `builtin which` rather than `which`, for systems which have an unusual which (?!), and an improvement to examples below in the README. Thanks to Klaus Ethgen the invocation of `sqlite3` is now unaffected by some potential confusions in your sqlite rc files.
- **30/06/20**: Thanks to rolandwalker, add-zsh-hook is used so histdb is a better citizen. Thanks to GreenArchon and phiresky the sqlite helper process is terminated on exit better, and the WAL is truncated before doing histdb sync. This should make things behave a bit better. Thanks to gabreal (and others, I think), some things have been changed to `declare -ga` which helps when using antigen or somesuch? Thanks to sheperdjerred and fuero there is now a file which might make antigen and oh-my-zsh work.

  There is a *breaking change*, which is that you no longer need to `add-zsh-hook precmd histdb-update-outcome` in your rc file. This now happens when you source `sqlite-history.zsh`.
- **11/03/20**: Thanks to phiresky ([https://github.com/phiresky](https://github.com/phiresky)) history appends within a shell session are performed through a single long-running sqlite process rather than by starting a new process per history append. This reduces contention between shells that are trying to write, as sqlite always fsyncs on exit.
- **29/05/19**: Thanks to Matthias Bilger ([https://github.com/m42e/](https://github.com/m42e/)) a bug has been removed which would have broken the database if the vacuum command were used. Turns out, you can't use rowid as a foreign key unless you've given it a name. As a side-effect your database will need updating, in a non-backwards compatible way, so you'll need to update on all your installations at once if you share a history file.

  Also, it's not impossible that this change will make a problem for someone somewhere, so be careful with this update.

  Also thanks to Matthias, the exit status of long-running commands is handled better.
- **05/04/18**: I've done a bit of work to make a replacement reverse-isearch function, which is in a usable state now.

  If you want to use it, see the [Reverse isearch](#reverse-isearch) section below which now covers it.

- **09/09/17**: If you have already installed and you want to get the right timings in the database, see the installation section again. Fix to issue #18.

## What is this

This is an experimental version of zsh-histdb that uses rqlite instead of a local SQLite file.
It stores your history into a distributed rqlite database.
It improves on the normal history by storing, for each history command:

- The start and stop times of the command
- The working directory where the command was run
- The hostname of the machine
- A unique per-host session ID, so history from several sessions is not confused
- The exit status of the command

## Project Structure

```
zsh-histdb/
├── rqlite-history.zsh              # Core (always loaded): query, init, hooks, cache
├── rqlite-history-fzf.zsh          # ZLE widgets: histdb-fzf, histdb-top-widget
├── rqlite-history-autosuggest.zsh  # zsh-autosuggestions integration
├── functions/                      # Autoloaded on first use (faster startup)
│   ├── histdb                     # histdb command with all filters
│   ├── histdb-top                 # Most frequent commands
│   ├── histdb-sync                # Sync placeholder
│   ├── histdb-stats               # Statistics
│   ├── histdb-export              # Export to text/JSON
│   ├── histdb-merge               # Merge from another instance
│   ├── histdb-search              # Advanced search
│   └── histdb-import-sqlite       # Import SQLite3 db
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

When you install `rqlite` (or any binary) while zsh is running:

```zsh
# Without rehash:
which rqlite    # → not found (cached from PATH)

# Fix:
rehash          # rebuild command hash table
which rqlite    # → /home/kenzanin/.local/bin/rqlite
```

The plugin re-checks for `rlite` at query time, so you don't need to restart your shell after installing it.

## Features

### Fuzzy History Search (`histdb-fzf`)

Press **Enter** to insert command, **Ctrl-J** to jump to directory, **Ctrl-D** to delete entry, **Ctrl-R** to cycle through history.

### History Statistics (`histdb-stats`)

View total commands, unique commands, most active hosts/directories, and activity by hour.

### Export & Search

- `histdb-export [format] [output_file]` - Export to text or JSON
- `histdb-search --date=YYYY-MM-DD --exit=0 --duration=>5 --host=name --dir=/path search_term` - Advanced search

### Integration

- **tmux**: `histdb-fzf-tmux` - Opens fzf in tmux popup
- **zsh-autosuggestions**: Use `histdb_advanced` strategy for context-aware suggestions
- **ZLE widgets**: `histdb-top-widget` - browse top commands interactively

## Installation

You will need a running `rqlite` cluster. For querying, the plugin supports two methods:

- **Preferred — `rlite` C client** (faster): Install from https://github.com/rqlite/rlite
- **Fallback — `curl` + `jq`**: Used automatically when `rlite` is not available

Optional: `fzf` for interactive history search.

Default rqlite URL is `http://localhost:4001`. You can change it by setting `HISTDB_RQLITE_URL`.

It is also possible to merge multiple history databases together without conflict, so long as all your machines have different hostnames.

### Quick Install

Example for installing in `$HOME/.oh-my-zsh/custom/plugins/zsh-histdb` (note that `oh-my-zsh` is not required):

```zsh
mkdir -p $HOME/.oh-my-zsh/custom/plugins/
git clone -b experimental https://github.com/larkery/zsh-histdb $HOME/.oh-my-zsh/custom/plugins/zsh-histdb
```

Add this to your `$HOME/.zshrc`:

```zsh
source $HOME/.oh-my-zsh/custom/plugins/zsh-histdb/rqlite-history.zsh
autoload -Uz add-zsh-hook

 # Optional: Bind histdb-fzf to Ctrl+R for fuzzy history search
bindkey '^R' histdb-fzf
```

### Running rqlite as a systemd User Service

Create a systemd user service file at `~/.config/systemd/user/zshdb.service`:

```ini
[Unit]
Description=zshdb server (rqlite)
After=network.target

[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/zshdb_data
ExecStart=%h/.local/bin/rqlited -http-addr 127.1.1.1:50001 -raft-addr 127.1.1.1:50002 %h/.local/share/zshdb_data
Restart=on-failure
RestartSec=5
WorkingDirectory=%h/.local/share/zshdb_data

[Install]
WantedBy=default.target
```

**Note:** Make sure the path to `rqlited` is correct. Check with:
```zsh
which rqlited  # e.g., /home/kenzanin/.local/bin/rqlited
```

Then enable and start the service:

```zsh
systemctl --user daemon-reload
systemctl --user enable --now zshdb.service
```

This will:

- Automatically start rqlite on boot (user login)
- Restart on failure
- Store data in `~/.local/share/zshdb_data`
- Listen on `127.1.1.1:50001` (HTTP API) and `127.1.1.1:50002` (raft protocol)

**Note:** The systemd service and `HISTDB_RQLITE_URL` are independent. If you change the port in the systemd service, you must manually update `HISTDB_RQLITE_URL` in your `~/.zshrc` to match:

```zsh
export HISTDB_RQLITE_URL="http://127.1.1.1:50001"
```

The default URL is already set to `http://127.1.1.1:50001` in `rqlite-history.zsh`, so you only need to set `HISTDB_RQLITE_URL` if you use a different port or remote server.

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
source /home/kenzanin/.local/share/zap/plugins/zsh-histdb/rqlite-history.zsh
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
source ${0:A:h}/rqlite-history.zsh
autoload -Uz add-zsh-hook
bindkey '^R' histdb-fzf
# Optional: histdb-top widget
zle -N histdb-top-widget
bindkey '^[t' histdb-top-widget
```

**prezto**:
```zsh
source $PREZTO/runcoms/zshrc
source ${0:A:h}/rqlite-history.zsh
bindkey '^R' histdb-fzf
```

**Basic zsh**:
```zsh
source ~/.local/share/zap/plugins/zsh-histdb/rqlite-history.zsh
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

## Reverse isearch

If you want a history-reverse-isearch type feature there is one defined in `histdb-interactive.zsh`. If you source that file you will get a new widget called `_histdb-isearch` which you can bind to a key, e.g.

```sh
source histdb-interactive.zsh
bindkey '^r' _histdb-isearch
```

This is like normal `history-reverse-isearch` except:

- The search will start with the buffer contents automatically
- The editing keys are all standard (because it does not really use the minibuffer).

  This means pressing `C-a` or `C-e` or similar will not exit the search like normal `history-reverse-isearch`
- The accept key (`RET`) does not cause the command to run immediately but instead lets you edit it

There are also a few extra keybindings:

- `M-j` will `cd` to the directory for the history entry you're looking at.
  This means you can search for ./run-this-command and then `M-j` to go to the right directory before running.
- `M-h` will toggle limiting the search to the current host's history.
- `M-d` will toggle limiting the search to the current directory and subdirectories' histories

## Fuzzy History Search with fzf

There's also a fuzzy history search function `histdb-fzf` defined in `rqlite-history.zsh`. This provides a better interactive history search experience using fzf.

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
- **Ctrl-C** - Cancel without selecting

The fzf interface shows:

- Command history with preview
- Host information
- Directory where command was run
- Timestamp of execution

### Requirements

- `fzf` must be installed and available in your PATH
- Works as a ZLE widget (must be bound to a key, cannot be run as a command)

## Database schema

The database lives in your rqlite cluster.
You can look in it easily by running `_histdb_query "sql..."`.

For inspiration you can also use `histdb` with the `-d` argument and it will print the SQL it's running.

## Troubleshooting

### rqlite connection issues

If you get connection errors:

1. Check if rqlite is running:
   ```zsh
   curl -s http://127.1.1.1:50001/status | jq
   ```

2. Verify the URL is correct:
   ```zsh
   echo $HISTDB_RQLITE_URL
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

rqlite handles synchronization automatically between nodes in the cluster.
There is no need for manual git-based synchronization of the database file.

## Completion

None, and I've used the names with underscores to mean something else.

## Pull requests / missing features

Happy to look at changes.
I did at one point have a reverse-isearch thing in here for searching the database interactively, but it didn't really make my life any better so I deleted it.
