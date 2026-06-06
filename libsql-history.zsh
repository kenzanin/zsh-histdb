# libsql-history.zsh — Core engine for zsh-histdb with sqld (libsql) via Hrana3
#
# Schema: single `cmd` table with (argv, count, wtime, status, last_dir, last_host)
# One row per unique command. No history table, no sessions, no JOINs.

which curl >/dev/null 2>&1 || return
which jq >/dev/null 2>&1 || return

zmodload zsh/datetime

autoload -U add-zsh-hook

typeset -g HISTDB_LIBSQL_URL="${HISTDB_LIBSQL_URL:-http://127.100.1.2:51777}"
typeset -g HISTDB_HOST="${HISTDB_HOST:-${HOST}}"
typeset -g HISTDB_INSTALLED_IN="${(%):-%N}"

sql_escape() {
    print -r -- "${@//\'/\'\'}"
}

# ------------------------------------------------------------------
# _histdb_query — Central dispatcher for SQL statements
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

    ! print -r -- "$response" | jq . >/dev/null 2>&1 && return 0

    local err_type err_msg
    err_type=$(print -r -- "$response" | jq -r '.results[0].type // "ok"' 2>/dev/null)
    if [[ "$err_type" == "error" ]]; then
        err_msg=$(print -r -- "$response" | jq -r '.results[0].error.message // "unknown error"' 2>/dev/null)
        printf '%s\n' "error in ${sql}: ${err_msg}" >&2
        return
    fi

    local result_json
    result_json=$(print -r -- "$response" | jq '.results[0].response.result' 2>/dev/null)
    [[ -z "$result_json" || "$result_json" == "null" ]] && return 0

    if (( header )); then
        print -r -- "$result_json" | jq -r --arg sep "$separator" \
            '[.cols[] | .name // ""] | join($sep)' 2>/dev/null
    fi

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
        ] | join($sep)' 2>/dev/null
}

# ------------------------------------------------------------------
# _histdb_query_curl_sequence — Multi-statement Hrana3 sequence request
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

    ! print -r -- "$response" | jq . >/dev/null 2>&1 && return

    local err_type err_msg
    err_type=$(print -r -- "$response" | jq -r '.results[0].type // "ok"' 2>/dev/null)
    if [[ "$err_type" == "error" ]]; then
        err_msg=$(print -r -- "$response" | jq -r '.results[0].error.message // "unknown error"' 2>/dev/null)
        printf '%s\n' "error in sequence: ${err_msg}" >&2
    fi
}

# ------------------------------------------------------------------
# _histdb_query_batch — Batch operation (reads SQL from stdin)
# ------------------------------------------------------------------
_histdb_query_batch() {
    local sql
    sql="$(cat)"
    [[ -z "$sql" ]] && return 0
    _histdb_query_curl_sequence "$sql"
}

# ------------------------------------------------------------------
# _histdb_init — Idempotent database initialisation
#   Creates single `cmd` table if missing + indexes.
# ------------------------------------------------------------------
typeset -g _HISTDB_INITIALIZED=""

_histdb_init() {
    [[ -n "$_HISTDB_INITIALIZED" ]] && return

    _histdb_query "CREATE TABLE IF NOT EXISTS cmd (
        argv TEXT UNIQUE,
        count INT DEFAULT 1,
        wtime INT,
        status INT,
        last_dir TEXT,
        last_host TEXT
    )"
    _histdb_query "CREATE INDEX IF NOT EXISTS cmd_wtime ON cmd(wtime)"
    _histdb_query "CREATE INDEX IF NOT EXISTS cmd_argv ON cmd(argv)"
    _histdb_query "CREATE INDEX IF NOT EXISTS cmd_count ON cmd(count)"

    _HISTDB_INITIALIZED=1
}

typeset -ga _BORING_PREFIX
_BORING_PREFIX=(" " "histdb" "ls" "cd")

if [[ -z "${HISTDB_TABULATE_CMD[*]:-}" ]]; then
    declare -ga HISTDB_TABULATE_CMD
    HISTDB_TABULATE_CMD=(column -t -s $'\x1f')
fi

# ------------------------------------------------------------------
# _histdb_addhistory — zshaddhistory hook (runs BEFORE command executes)
#   UPSERT into cmd: increments count, updates wtime/dir/host.
# ------------------------------------------------------------------
typeset -g _HISTDB_LAST_CMD=""

_histdb_addhistory() {
    local cmd="${1[0, -2]}"
    if [[ -o histignorespace && "$cmd" =~ "^ " ]]; then
        _HISTDB_LAST_CMD=""
        return 0
    fi
    for boring in "${_BORING_PREFIX[@]}"; do
        if [[ "$cmd" == "$boring"* ]]; then
            _HISTDB_LAST_CMD=""
            return 0
        fi
    done

    _HISTDB_LAST_CMD="$cmd"
    local started=$EPOCHSECONDS
    _histdb_init

    if [[ -n "$cmd" ]]; then
        _histdb_query_batch <<EOF
INSERT INTO cmd (argv, count, wtime, last_dir, last_host)
VALUES ('$(sql_escape "$cmd")', 1, ${started}, '$(sql_escape "${PWD}")', '$(sql_escape "${HOST}")')
ON CONFLICT(argv) DO UPDATE SET
    count = count + 1,
    wtime = excluded.wtime,
    last_dir = excluded.last_dir,
    last_host = excluded.last_host;
EOF
    fi
    return 0
}

# ------------------------------------------------------------------
# _histdb_update_outcome — precmd hook (runs AFTER command finishes)
#   Updates exit status for the last command.
# ------------------------------------------------------------------
_histdb_update_outcome() {
    local retval=$?
    [[ -z "$_HISTDB_LAST_CMD" ]] && return
    _histdb_query_batch <<EOF
UPDATE cmd SET status = ${retval}
WHERE argv = '$(sql_escape "$_HISTDB_LAST_CMD")';
EOF
}

add-zsh-hook zshaddhistory _histdb_addhistory
add-zsh-hook precmd _histdb_update_outcome

# ============================================================
# Up/Down prefix search via histdb
#   Bind with:
#     bindkey '^[[A' _histdb-up-line-or-beginning-search
#     bindkey '^[[B' _histdb-down-line-or-beginning-search
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
        sql="SELECT argv FROM cmd
             WHERE last_host = '$(sql_escape ${HOST})'
             ORDER BY wtime DESC
             LIMIT 2000"
    else
        sql="SELECT argv FROM cmd
             WHERE argv LIKE '$(sql_escape "$prefix")%'
             ORDER BY wtime DESC
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
