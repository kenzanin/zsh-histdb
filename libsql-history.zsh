# libsql-history.zsh — Core engine for zsh-histdb with sqld (libsql) via Hrana3
#
# Uses sqld's Hrana3 over HTTP (POST /v3/pipeline) for all SQL operations.
# Replaces the old rqlite HTTP API transport with Hrana3 over HTTP.

which curl >/dev/null 2>&1 || return
which jq >/dev/null 2>&1 || return

zmodload zsh/datetime

autoload -U add-zsh-hook

typeset -g HISTDB_LIBSQL_URL="${HISTDB_LIBSQL_URL:-http://127.100.1.2:8080}"
typeset -g HISTDB_SESSION=""
typeset -g HISTDB_HOST=""
typeset -g HISTDB_INSTALLED_IN="${(%):-%N}"

sql_escape() {
    print -r -- "${@//\'/\'\'}"
}

# ------------------------------------------------------------------
# _histdb_query — Central dispatcher for SQL statements
#   Parses common flags, then delegates to _histdb_query_curl.
#   Signature matches the old interface so all callers work unchanged.
# ------------------------------------------------------------------
_histdb_query() {
    local url="${HISTDB_LIBSQL_URL}"
    local separator=$'\t'
    local header=0
    local sql=""

    local -a args
    args=("$@")
    local i=1
    while (( i <= $#args )); do
        case "${args[$i]}" in
            -separator) separator="${args[$((i+1))]}"; i=$((i+2)) ;;
            -header) header=1; i=$((i+1)) ;;
            -noheader) header=0; i=$((i+1)) ;;
            -batch) i=$((i+1)) ;;
            -cmd) i=$((i+2)) ;;
            *)
                if [[ "${args[$i]}" != "${HISTDB_FILE}" ]]; then
                    sql="${args[$i]}"
                fi
                i=$((i+1))
                ;;
        esac
    done

    if [[ -z "$sql" ]]; then sql="$(cat)"; fi
    [[ -z "$sql" ]] && return 0

    _histdb_query_curl "$sql" "$separator" "$header"
}

# ------------------------------------------------------------------
# _histdb_query_curl — Single-statement Hrana3 execute via POST /v3/pipeline
#
# Sends one execute request and parses the result.
# Outputs tab-separated rows (and optional header) matching the old format.
# Errors go to stderr, nothing on stdout for mutations.
# ------------------------------------------------------------------
_histdb_query_curl() {
    local sql="$1" separator="$2" header="$3"
    local url="${HISTDB_LIBSQL_URL}/v3/pipeline"

    local body response
    body=$(jq -n \
        --arg sql "$sql" \
        '{
            "baton": null,
            "requests": [
                {"type": "execute", "stmt": {"sql": $sql, "args": [], "want_rows": true}}
            ]
        }') || return 0

    response=$(curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body") || return 0

    # Check for pipeline/statement-level error
    local err_type err_msg
    err_type=$(print -r -- "$response" | jq -r '.results[0].type // "ok"')
    if [[ "$err_type" == "error" ]]; then
        err_msg=$(print -r -- "$response" | jq -r '.results[0].error.message // "unknown error"')
        echo "error in ${sql}: ${err_msg}" >&2
        return
    fi

    # Extract result
    local result_json
    result_json=$(print -r -- "$response" | jq '.results[0].response.result')
    [[ -z "$result_json" || "$result_json" == "null" ]] && return 0

    # Print header if requested
    if (( header )); then
        print -r -- "$result_json" | jq -r --arg sep "$separator" \
            '[.cols[] | .name // ""] | join($sep)'
    fi

    # Print rows — convert Hrana3 Value objects to plain text
    print -r -- "$result_json" | jq -r --arg sep "$separator" '
        .rows[] | [
            .[] |
            if .type == "null" then ""
            elif .type == "integer" then .value
            elif .type == "text" then .value
            elif .type == "float" then (.value | tostring)
            elif .type == "blob" then .base64
            else ""
            end
        ] | join($sep)'
}

# ------------------------------------------------------------------
# _histdb_query_curl_sequence — Multi-statement Hrana3 sequence request
#
# For batch operations (multiple semicolon-separated SQLs).
# Rows are ignored — only error checking.
# ------------------------------------------------------------------
_histdb_query_curl_sequence() {
    local sql="$1"
    local url="${HISTDB_LIBSQL_URL}/v3/pipeline"

    local body response
    body=$(jq -n \
        --arg sql "$sql" \
        '{
            "baton": null,
            "requests": [
                {"type": "sequence", "sql": $sql}
            ]
        }') || return 0

    response=$(curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body") || return 0

    local err_type err_msg
    err_type=$(print -r -- "$response" | jq -r '.results[0].type // "ok"')
    if [[ "$err_type" == "error" ]]; then
        err_msg=$(print -r -- "$response" | jq -r '.results[0].error.message // "unknown error"')
        echo "error in sequence: ${err_msg}" >&2
    fi
}

# ------------------------------------------------------------------
# _histdb_query_batch — Batch operation (reads SQL from stdin)
#   Delegates to _histdb_query_curl_sequence for multi-statement support.
# ------------------------------------------------------------------
_histdb_query_batch() {
    local sql
    sql="$(cat)"
    [[ -z "$sql" ]] && return 0
    _histdb_query_curl_sequence "$sql"
}

# ------------------------------------------------------------------
# _histdb_init — Idempotent database initialisation
# ------------------------------------------------------------------
_histdb_init() {
    [[ -n "${HISTDB_SESSION}" ]] && return

    local exists=$(_histdb_query "SELECT name FROM sqlite_master WHERE type='table' AND name='history'")
    if [[ -z "$exists" ]]; then
        _histdb_query <<-EOF
create table commands (id integer primary key autoincrement, argv text, unique(argv) on conflict ignore);
create table places   (id integer primary key autoincrement, host text, dir text, unique(host, dir) on conflict ignore);
create table history  (id integer primary key autoincrement,
                       session int,
                       command_id int references commands (id),
                       place_id int references places (id),
                       exit_status int,
                       start_time int,
                       duration int);
PRAGMA user_version = 2;
EOF
    fi

    if [[ -z "${HISTDB_SESSION}" ]]; then
        HISTDB_HOST=${HISTDB_HOST:-"'$(sql_escape ${HOST})'"}
        HISTDB_SESSION=$(_histdb_query "select 1+max(session) from history inner join places on places.id=history.place_id where places.host = ${HISTDB_HOST}")
        HISTDB_SESSION="${HISTDB_SESSION:-0}"
        readonly HISTDB_SESSION
    fi

    _histdb_query "create index if not exists hist_time on history(start_time)"
    _histdb_query "create index if not exists place_dir on places(dir)"
    _histdb_query "create index if not exists place_host on places(host)"
    _histdb_query "create index if not exists history_command_place on history(command_id, place_id)"
    _histdb_query "create index if not exists hist_time_cmd on history(start_time DESC, command_id)"
    _histdb_query "create index if not exists hist_time_place on history(start_time DESC, place_id)"
}

typeset -ga _BORING_PREFIX
_BORING_PREFIX=(" " "histdb" "ls" "cd")

if [[ -z "${HISTDB_TABULATE_CMD[*]:-}" ]]; then
    declare -ga HISTDB_TABULATE_CMD
    HISTDB_TABULATE_CMD=(column -t -s $'\x1f')
fi

_histdb_update_outcome() {
    local retval=$?
    local finished=$EPOCHSECONDS
    [[ -z "${HISTDB_SESSION}" ]] && return
    _histdb_query_batch <<EOF &|
update history set
      exit_status = ${retval},
      duration = ${finished} - start_time
where id = (select max(id) from history) and
      session = ${HISTDB_SESSION} and
      exit_status is NULL;
EOF
}

_histdb_addhistory() {
    local cmd="${1[0, -2]}"
    if [[ -o histignorespace && "$cmd" =~ "^ " ]]; then return 0; fi
    if [[ ${cmd} == ${~HISTORY_IGNORE} ]]; then return 0; fi
    for boring in "${_BORING_PREFIX[@]}"; do
        if [[ "$cmd" == "$boring"* ]]; then return 0; fi
    done

    local cmd="'$(sql_escape $cmd)'"
    local pwd="'$(sql_escape ${PWD})'"
    local started=$EPOCHSECONDS
    _histdb_init

    if [[ "$cmd" != "''" ]]; then
        _histdb_query_batch <<EOF &|
insert into commands (argv) values (${cmd});
insert into places   (host, dir) values (${HISTDB_HOST}, ${pwd});
insert into history
  (session, command_id, place_id, start_time)
select
  ${HISTDB_SESSION},
  commands.id,
  places.id,
  ${started}
from
  commands, places
where
  commands.argv = ${cmd} and
  places.host = ${HISTDB_HOST} and
  places.dir = ${pwd}
;
EOF
    fi
    return 0
}

add-zsh-hook zshaddhistory _histdb_addhistory
add-zsh-hook precmd _histdb_update_outcome

# ============================================================
# Up/Down prefix search via histdb
# Replaces zsh's up-line-or-beginning-search / down-line-or-beginning-search
# Bind with:
#   bindkey '^[[A' _histdb-up-line-or-beginning-search
#   bindkey '^[[B' _histdb-down-line-or-beginning-search
# ============================================================
typeset -g HISTDB_PREFIX_QUERY=""
typeset -ga HISTDB_PREFIX_RESULTS
typeset -gi HISTDB_PREFIX_INDEX=-1

_histdb-up-line-or-beginning-search() {
    local prefix="$BUFFER"

    if (( ${#HISTDB_PREFIX_RESULTS[@]} > 0 )) && [[ "$prefix" == "$HISTDB_PREFIX_QUERY"* ]]; then
        local n=$(( ${#HISTDB_PREFIX_RESULTS[@]} - 1 ))
        (( HISTDB_PREFIX_INDEX < n )) && HISTDB_PREFIX_INDEX=$(( HISTDB_PREFIX_INDEX + 1 )) || HISTDB_PREFIX_INDEX=0
        BUFFER="${HISTDB_PREFIX_RESULTS[$((HISTDB_PREFIX_INDEX + 1))]}"
        CURSOR=${#BUFFER}
        zle reset-prompt
        return
    fi

    HISTDB_PREFIX_QUERY="$prefix"
    HISTDB_PREFIX_INDEX=-1
    HISTDB_PREFIX_RESULTS=()

    _histdb_init

    local sql
    if [[ -z "$prefix" ]]; then
        sql="SELECT commands.argv FROM history
             JOIN commands ON history.command_id = commands.id
             JOIN places ON history.place_id = places.id
             WHERE places.host = '$(sql_escape $HOST)'
             GROUP BY commands.argv
             ORDER BY MAX(history.start_time) DESC
             LIMIT 2000"
    else
        sql="SELECT commands.argv FROM history
             JOIN commands ON history.command_id = commands.id
             JOIN places ON history.place_id = places.id
             WHERE commands.argv LIKE '$(sql_escape "$prefix")%'
             GROUP BY commands.argv
             ORDER BY MAX(CASE WHEN places.host = '$(sql_escape "$HOST")' THEN 1 ELSE 0 END) DESC,
                      MAX(history.start_time) DESC
             LIMIT 2000"
    fi

    local result line
    result=$(_histdb_query "$sql" 2>/dev/null)
    HISTDB_PREFIX_RESULTS=()
    for line in "${(@f)result}"; do
        [[ -z "$line" ]] && continue
        HISTDB_PREFIX_RESULTS+=("$line")
    done

    if (( ${#HISTDB_PREFIX_RESULTS[@]} > 0 )); then
        HISTDB_PREFIX_INDEX=0
        BUFFER="${HISTDB_PREFIX_RESULTS[1]}"
        CURSOR=${#BUFFER}
    fi

    zle reset-prompt
}

_histdb-down-line-or-beginning-search() {
    if (( HISTDB_PREFIX_INDEX > 0 )); then
        HISTDB_PREFIX_INDEX=$(( HISTDB_PREFIX_INDEX - 1 ))
        BUFFER="${HISTDB_PREFIX_RESULTS[$((HISTDB_PREFIX_INDEX + 1))]}"
        CURSOR=${#BUFFER}
    elif (( HISTDB_PREFIX_INDEX == 0 )); then
        HISTDB_PREFIX_INDEX=-1
        BUFFER="$HISTDB_PREFIX_QUERY"
        CURSOR=${#BUFFER}
    fi
    zle reset-prompt
}

zle -N _histdb-up-line-or-beginning-search
zle -N _histdb-down-line-or-beginning-search
