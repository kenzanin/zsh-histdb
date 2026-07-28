# libsql-history-shared.zsh — Shared utilities for zsh-histdb
#
# Extracted duplicate patterns:
#   - curl Hrana3 request pipeline (POST + validate + error check)
#   - ORDER BY sort fragment (dir-first → wtime → count → rowid)
#   - peco tab-separated output parsing

# ------------------------------------------------------------------
# _histdb_curl_send — POST JSON body to Hrana3 pipeline, validate, check errors
#
# Args:
#   $1 — JSON body to POST
#   $2 — Error context label (for error messages, default: "sql")
#
# Returns: response JSON string via stdout, empty on error
#   Exit 0 on success, 1 on failure
# ------------------------------------------------------------------
_histdb_curl_send() {
    local body="$1"
    local error_context="${2:-sql}"
    local url="${HISTDB_LIBSQL_URL}/v3/pipeline"

    local response
    response=$(curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body") || return 1

    ! print -r -- "$response" | jq . >/dev/null 2>&1 && return 1

    local err_type err_msg
    err_type=$(print -r -- "$response" | jq -r '.results[0].type // "ok"' 2>/dev/null)
    if [[ "$err_type" == "error" ]]; then
        err_msg=$(print -r -- "$response" | jq -r '.results[0].error.message // "unknown error"' 2>/dev/null)
        printf '%s\n' "error in ${error_context}: ${err_msg}" >&2
        return 1
    fi

    print -r -- "$response"
}

# ------------------------------------------------------------------
# _histdb_order_sort — Returns ORDER BY SQL fragment
#
# Sort priority:
#   1. Current directory first (last_dir = $PWD)
#   2. Most recent first (wtime DESC)
#   3. Most frequent first (count DESC)
#   4. Deterministic tiebreaker (rowid DESC)
# ------------------------------------------------------------------
_histdb_order_sort() {
    local dir
    dir=$(sql_escape "${PWD}")
    printf '%s\n' "ORDER BY
    CASE WHEN last_dir = '${dir}' THEN 0 ELSE 1 END,
    wtime DESC,
    count DESC,
    rowid DESC"
}

# ------------------------------------------------------------------
# _histdb_peco_extract_cmd — Extract command from peco tab-separated output
#
# Lines have tab-separated fields. First field is argv (quoted from SQL).
# Strips surrounding quotes.
# ------------------------------------------------------------------
_histdb_peco_extract_cmd() {
    local selection="$1" sep="$2"
    local cmd="${selection%%$sep*}"
    cmd="${cmd#\"}"
    cmd="${cmd%\"}"
    print -r -- "$cmd"
}

# ------------------------------------------------------------------
# _histdb_peco_extract_field — Extract Nth field (1-based) from peco output
# ------------------------------------------------------------------
_histdb_peco_extract_field() {
    local selection="$1" sep="$2" field="$3"
    local i=1 part="$selection"
    while (( i < field )); do
        part="${part#*$sep}"
        i=$((i+1))
    done
    printf '%s' "${part%%$sep*}"
}
