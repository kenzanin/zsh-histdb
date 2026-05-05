which curl >/dev/null 2>&1 || return
which jq >/dev/null 2>&1 || return

zmodload zsh/datetime

autoload -U add-zsh-hook

typeset -g HISTDB_RQLITE_URL="${HISTDB_RQLITE_URL:-http://127.1.1.1:50001}"
typeset -g HISTDB_QUERY=""
typeset -g HISTDB_SESSION=""
typeset -g HISTDB_HOST=""
typeset -g HISTDB_INSTALLED_IN="${(%):-%N}"

# Cache
typeset -gA HISTDB_CACHE
typeset -gi HISTDB_CACHE_MAX=100

_histdb_cache_get() {
    echo "${HISTDB_CACHE[$1]:-}"
}

_histdb_cache_set() {
    if [[ ${#HISTDB_CACHE[@]} -ge $HISTDB_CACHE_MAX ]]; then
        HISTDB_CACHE=()
    fi
    HISTDB_CACHE[$1]="$2"
}

# Detect rlite at init time, re-check at query time
typeset -g HISTDB_RLITE_BIN=""
if which rlite >/dev/null 2>&1; then
    HISTDB_RLITE_BIN="$(which rlite)"
fi

sql_escape() {
    print -r -- "${@//\'/\'\'}"
}

_histdb_query() {
    local url="${HISTDB_RQLITE_URL}"
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

    # Re-check for rlite (supports rehash)
    if [[ -z "$HISTDB_RLITE_BIN" ]] && which rlite >/dev/null 2>&1; then
        HISTDB_RLITE_BIN="$(which rlite)"
    fi

    if [[ -n "$HISTDB_RLITE_BIN" ]]; then
        _histdb_query_rlite "$sql" "$separator" "$header"
    else
        _histdb_query_curl "$sql" "$separator" "$header"
    fi
}

_histdb_query_rlite() {
    if [[ "$3" == "1" ]]; then
        "$HISTDB_RLITE_BIN" "$HISTDB_RQLITE_URL" "$1" | awk -F'|' 'BEGIN{OFS=FS} NR==1{print; next} {print}' | sed "s/|/$2/g"
    else
        "$HISTDB_RLITE_BIN" "$HISTDB_RQLITE_URL" "$1" | tail -n +2 | sed "s/|/$2/g"
    fi
}

_histdb_query_curl() {
    local sql="$1" separator="$2" header="$3" endpoint="query"
    local first_word="${${sql##[[:space:]]##}%%[[:space:]]*}"
    case "${(L)first_word}" in
        insert|update|delete|create|drop|replace|alter) endpoint="execute" ;;
        pragma)
            if [[ $sql == *"="* ]]; then endpoint="execute"; fi
            ;;
    esac

    if [[ "$endpoint" == "query" ]]; then
        curl -s -G "${HISTDB_RQLITE_URL}/db/query?pretty=false" --data-urlencode "q=${sql}" | \
            jq -r --arg sep "$separator" --arg header "$header" '
                if .results[0].error then "ERROR: " + .results[0].error
                else .results[0] |
                    (if $header == "1" then .columns | join($sep) else empty end),
                    (if .values then .values[] | map(if . == null then "" else . end) | join($sep) else empty end)
                end' | while read -r line; do
            if [[ $line == "ERROR: "* ]]; then
                echo "error in ${sql}: ${line#ERROR: }" >&2
            else
                print -r -- "$line"
            fi
        done
    else
        curl -s -X POST "${HISTDB_RQLITE_URL}/db/execute?pretty=false" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg sql "$sql" '[$sql]')" | \
            jq -r 'if .results[0].error then "ERROR: " + .results[0].error else empty end' | while read -r line; do
            if [[ $line == "ERROR: "* ]]; then
                echo "error in ${sql}: ${line#ERROR: }" >&2
            fi
        done
    fi
}

_histdb_stop_sqlite_pipe() { return 0 }
_histdb_start_sqlite_pipe() { return 0 }
add-zsh-hook zshexit _histdb_stop_sqlite_pipe

_histdb_query_batch() { _histdb_query "$(cat)" }

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

    _histdb_query_batch >/dev/null <<EOF
create index if not exists hist_time on history(start_time);
create index if not exists place_dir on places(dir);
create index if not exists place_host on places(host);
create index if not exists history_command_place on history(command_id, place_id);
EOF
}

declare -ga _BORING_COMMANDS
_BORING_COMMANDS=("^ls$" "^cd$" "^ " "^histdb" "^top$" "^htop$")

if [[ -z "${HISTDB_TABULATE_CMD[*]:-}" ]]; then
    declare -ga HISTDB_TABULATE_CMD
    HISTDB_TABULATE_CMD=(column -t -s $'\x1f')
fi

_histdb_update_outcome() {
    local retval=$?
    local finished=$EPOCHSECONDS
    [[ -z "${HISTDB_SESSION}" ]] && return
    _histdb_init
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
    for boring in "${_BORING_COMMANDS[@]}"; do
        if [[ "$cmd" =~ $boring ]]; then return 0; fi
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

_histdb_batch_insert() {
    local entries=("$@")
    if [[ ${#entries[@]} -eq 0 ]]; then
        entries=("${(@f)$(cat)}")
    fi

    local sql="BEGIN TRANSACTION;"
    for entry in "${entries[@]}"; do
        local argv="$(echo "$entry" | cut -d'|' -f1)"
        local dir="$(echo "$entry" | cut -d'|' -f2)"
        local exit_status="$(echo "$entry" | cut -d'|' -f3)"
        local start_time="$(echo "$entry" | cut -d'|' -f4)"

        sql="${sql} INSERT OR IGNORE INTO commands (argv) VALUES ('$(sql_escape "$argv")');"
        sql="${sql} INSERT OR IGNORE INTO places (host, dir) VALUES (${HISTDB_HOST}, '$(sql_escape "$dir")');"
        sql="${sql} INSERT INTO history (session, command_id, place_id, exit_status, start_time) SELECT ${HISTDB_SESSION}, c.id, p.id, $exit_status, $start_time FROM commands c, places p WHERE c.argv='$(sql_escape "$argv")' AND p.host=${HISTDB_HOST} AND p.dir='$(sql_escape "$dir")';"
    done
    sql="${sql} COMMIT;"

    _histdb_query "$sql"
}

add-zsh-hook zshaddhistory _histdb_addhistory
add-zsh-hook precmd _histdb_update_outcome
