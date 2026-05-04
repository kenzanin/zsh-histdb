which curl >/dev/null 2>&1 || return;
which jq >/dev/null 2>&1 || return;

zmodload zsh/datetime # for EPOCHSECONDS

autoload -U add-zsh-hook

typeset -g HISTDB_RQLITE_URL="${HISTDB_RQLITE_URL:-http://127.1.1.1:50001}"
typeset -g HISTDB_QUERY=""
typeset -g HISTDB_SESSION=""
typeset -g HISTDB_HOST=""
typeset -g HISTDB_INSTALLED_IN="${(%):-%N}"

sql_escape () {
    print -r -- ${${@//\'/\'\'}//$'\x00'}
}

_histdb_query () {
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
    [[ -z "$sql" ]] && return

    # rqlite endpoint detection
    local endpoint="query"
    local first_word="${${sql##[[:space:]]##}%%[[:space:]]*}"
    case "${(L)first_word}" in
        insert|update|delete|create|drop|replace|alter)
            endpoint="execute"
            ;;
        pragma)
            if [[ $sql == *"="* ]]; then
                endpoint="execute"
            else
                endpoint="query"
            fi
            ;;
    esac

    if [[ "$endpoint" == "query" ]]; then
        local jq_script='
            if .results[0].error then 
                "ERROR: " + .results[0].error 
            else 
                .results[0] | 
                (if $header == "1" then .columns | join($sep) else empty end), 
                (if .values then .values[] | map(if . == null then "" else . end) | join($sep) else empty end) 
            end'
        curl -s -G "${url}/db/query?pretty=false" --data-urlencode "q=${sql}" | jq -r --arg sep "$separator" --arg header "$header" "$jq_script" | while read -r line; do
            if [[ $line == "ERROR: "* ]]; then
                echo "error in ${sql}: ${line#ERROR: }" >&2
            else
                print -r -- "$line"
            fi
        done
    else
        curl -s -X POST "${url}/db/execute?pretty=false" \
             -H "Content-Type: application/json" \
             -d "$(jq -n --arg sql "$sql" '[$sql]')" | jq -r 'if .results[0].error then "ERROR: " + .results[0].error else empty end' | while read -r line; do
             if [[ $line == "ERROR: "* ]]; then
                echo "error in ${sql}: ${line#ERROR: }" >&2
             fi
        done
    fi
}

_histdb_stop_sqlite_pipe () {
    return 0
}

add-zsh-hook zshexit _histdb_stop_sqlite_pipe

_histdb_start_sqlite_pipe () {
    return 0
}

_histdb_query_batch () {
    _histdb_query "$(cat)"
}

_histdb_init () {
    if [[ -n "${HISTDB_SESSION}" ]]; then
        return
    fi

    # Check if tables exist
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

_histdb_update_outcome () {
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

_histdb_addhistory () {
    local cmd="${1[0, -2]}"

    if [[ -o histignorespace && "$cmd" =~ "^ " ]]; then
        return 0
    fi
    if [[ ${cmd} == ${~HISTORY_IGNORE} ]]; then
        return 0
    fi
    local boring
    for boring in "${_BORING_COMMANDS[@]}"; do
        if [[ "$cmd" =~ $boring ]]; then
            return 0
        fi
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

histdb-fzf() {
    # Check for fzf
    which fzf >/dev/null 2>&1 || { echo "fzf not found"; return 1 }
    _histdb_init

    local sep=$'\t'
    # Query for unique commands with host and dir for the preview
    # We use a subquery to get the latest unique commands
    local query="SELECT argv, host, dir, time FROM (
        SELECT 
            commands.argv as argv, 
            places.host as host, 
            places.dir as dir, 
            strftime('%Y-%m-%d %H:%M', history.start_time, 'unixepoch', 'localtime') as time
        FROM history 
        JOIN commands ON history.command_id = commands.id 
        JOIN places ON history.place_id = places.id 
        ORDER BY history.start_time DESC
    ) GROUP BY argv ORDER BY time DESC LIMIT 2000"

    local selected
    selected=$(_histdb_query -separator "$sep" "$query" | \
        fzf --height 40% \
            --reverse \
            --tiebreak=index \
            --delimiter "$sep" \
            --with-nth 1 \
            --preview "echo -e 'Command: {1}\nHost: {2}\nDirectory: {3}\nTime: {4}'" \
            --preview-window down:4:wrap \
            --query "$LBUFFER")

    if [[ -n "$selected" ]]; then
        LBUFFER="${selected%%$sep*}"
    fi
    zle reset-prompt
}

zle -N histdb-fzf

add-zsh-hook zshaddhistory _histdb_addhistory
add-zsh-hook precmd _histdb_update_outcome

histdb-top () {
    _histdb_init
    local sep=$'\x1f'
    local field
    local join
    local table
    1=${1:-cmd}
    case "$1" in
        dir)
            field=places.dir
            join='places.id = history.place_id'
            table=places
            ;;
        cmd)
            field=commands.argv
            join='commands.id = history.command_id'
            table=commands
            ;;;
    esac
    _histdb_query -separator "$sep" \
            -header \
            "select count(*) as count, places.host, replace($field, '
', '
$sep$sep') as ${1:-cmd} from history left join commands on history.command_id=commands.id left join places on history.place_id=places.id group by places.host, $field order by count(*)" | \
        "${HISTDB_TABULATE_CMD[@]}"
}

histdb-sync () {
    echo "rqlite handles synchronization automatically"
}

histdb () {
    _histdb_init
    local -a opts
    local -a hosts
    local -a indirs
    local -a atdirs
    local -a sessions

    zparseopts -E -D -a opts \
               -host+::=hosts \
               -in+::=indirs \
               -at+::=atdirs \
               -forget \
               -yes \
               -detail \
               -sep:- \
               -exact \
               d h -help \
               s+::=sessions \
               -from:- -until:- -limit:- \
               -status:- -desc

    local usage="usage:$0 terms [--desc] [--host[ x]] [--in[ x]] [--at] [-s n]+* [-d] [--detail] [--forget] [--yes] [--exact] [--sep x] [--from x] [--until x] [--limit n] [--status x]
    --desc     reverse sort order of results
    --host     print the host column and show all hosts (otherwise current host)
    --host x   find entries from host x
    --in       find only entries run in the current dir or below
    --in x     find only entries in directory x or below
    --at       like --in, but excluding subdirectories
    -s n       only show session n
    -d         debug output query that will be run
    --detail   show details
    --forget   forget everything which matches in the history
    --yes      don't ask for confirmation when forgetting
    --exact    don't match substrings
    --sep x    print with separator x, and don't tabulate
    --from x   only show commands after date x (sqlite date parser)
    --until x  only show commands before date x (sqlite date parser)
    --limit n  only show n rows. defaults to \$LINES or 25
    --status x only show rows with exit status x. Can be 'error' to find all nonzero."

    local selcols="session as ses, dir"
    local cols="session, replace(places.dir, '$HOME', '~') as dir"
    local where="1"
    if [[ -p /dev/stdout ]]; then
        local limit=""
    else
        local limit="\${\$((LINES - 4)):-25}"
    fi

    local forget="0"
    local forget_accept=0
    local exact=0

    if (( \${#hosts} )); then
        local hostwhere=""
        local host=""
        for host (\$hosts); do
            host="\${\${host#--host}#=}"
            hostwhere="\${hostwhere}\${host:+\${hostwhere:+ or }places.host='\$(sql_escape \${host})'}"
        done
        where="\${where}\${hostwhere:+ and (\${hostwhere})}"
        cols="\${cols}, places.host as host"
        selcols="\${selcols}, host"
    else
        where="\${where} and places.host=\${HISTDB_HOST}"
    fi

    if (( \${#indirs} + \${#atdirs} )); then
        local dirwhere=""
        local dir=""
        for dir (\$indirs); do
            dir="\${\${\${dir#--in}#=}:-\$PWD}"
            dirwhere="\${dirwhere}\${dirwhere:+ or }places.dir like '\$(sql_escape \$dir)%'"
        done
        for dir (\$atdirs); do
            dir="\${\${\${dir#--at}#=}:-\$PWD}"
            dirwhere="\${dirwhere}\${dirwhere:+ or }places.dir = '\$(sql_escape \$dir)'"
        done
        where="\${where}\${dirwhere:+ and (\${dirwhere})}"
    fi

    if (( \${#sessions} )); then
        local sin=""
        local ses=""
        for ses (\$sessions); do
            ses="\${\${\${ses#-s}#=}:-\${HISTDB_SESSION}}"
            sin="\${sin}\${sin:+, }\$ses"
        done
        where="\${where}\${sin:+ and session in (\$sin)}"
    fi

    local sep=$'\x1f'
    local orderdir='asc'
    local debug=0
    local opt=""
    for opt (\$opts); do
        case \$opt in
            --desc)
                orderdir='desc'
                ;;
            --sep*)
                sep=\${opt#--sep}
                ;;
            --from*)
                local from=\${opt#--from}
                case \$from in
                    -*)
                        from="datetime('now', '\$from')"
                        ;;
                    today)
                        from="datetime('now', 'start of day')"
                        ;;
                    yesterday)
                        from="datetime('now', 'start of day', '-1 day')"
                        ;;
                esac
                where="\${where} and datetime(start_time, 'unixepoch') >= \$from"
                ;;
            --status*)
                local xstatus=\${opt#--status}
                case \$xstatus in
                    <->)
                        where="\${where} and exit_status = \$xstatus"
                        ;;
                        error)
                        where="\${where} and exit_status <> 0"
                        ;;
                esac
                ;;
            --until*)
                local until=\${opt#--until}
                case \$until in
                    -*)
                        until="datetime('now', '\$until')"
                        ;;
                    today)
                        until="datetime('now', 'start of day')"
                        ;;
                    yesterday)
                        until="datetime('now', 'start of day', '-1 day')"
                        ;;
                esac
                where="\${where} and datetime(start_time, 'unixepoch') <= \$until"
                ;;
            -d)
                debug=1
                ;;
            --detail)
                cols="\${cols}, exit_status, duration "
                selcols="\${selcols}, exit_status as [?],duration as secs "
                ;;
            -h|--help)
                echo "\$usage"
                return 0
                ;;
            --forget)
                forget=1
                ;;
            --yes)
                forget_accept=1
                ;;
            --exact)
                exact=1
                ;;
            --limit*)
                limit=\${opt#--limit}
                ;;
        esac
    done

    if [[ -n "\$*" ]]; then
        if [[ \$exact -eq 0 ]]; then
            where="\${where} and commands.argv glob '*\$(sql_escape \$@)*'"
        else
            where="\${where} and commands.argv = '\$(sql_escape \$@)'"
        fi
    fi

    if [[ \$forget -gt 0 ]]; then
        limit=""
    fi
    local seps=\$(echo "\$cols" | tr -c -d ',' | tr ',' \$sep)
    cols="\${cols}, replace(commands.argv, '
', '
\$seps') as argv, max(start_time) as max_start"

    local mst="datetime(max_start, 'unixepoch')"
    local dst="datetime('now', 'start of day')"
    local timecol="strftime(case when \$mst > \$dst then '%H:%M' else '%d/%m' end, max_start, 'unixepoch', 'localtime') as time"

    selcols="\${timecol}, \${selcols}, argv as cmd"

    local r_order="asc"
    if [[ \$orderdir == "asc" ]]; then
        r_order="desc"
    fi

    local query="select \${selcols} from (select \${cols}
from
  commands
  join history on history.command_id = commands.id
  join places on history.place_id = places.id
where \${where}
group by history.command_id, history.place_id
order by max_start \${r_order}
\${limit:+limit \$limit}) order by max_start \${orderdir}"

    if [[ \$debug = 1 ]]; then
        echo "\$query"
    else
        local count=\$(_histdb_query "select count(*) from (select \${cols} from commands join history on history.command_id = commands.id join places on history.place_id = places.id where \${where} group by history.command_id, history.place_id)")
        if [[ -p /dev/stdout ]]; then
            buffer() {
                temp=\$(mktemp)
                cat >! "\$temp"
                cat -- "\$temp"
                rm -f -- "\$temp"
            }
        else
            buffer() {
                cat
            }
        fi
        if [[ \$sep == \$'\x1f' ]]; then
            _histdb_query -header -separator \$sep "\$query" | iconv -f utf-8 -t utf-8 -c | buffer | "\${HISTDB_TABULATE_CMD[@]}"
        else
            _histdb_query -header -separator \$sep "\$query" | buffer
        fi
        [[ -n \$limit ]] && [[ \$limit -lt \$count ]] && echo "(showing \$limit of \$count results)"
    fi

    if [[ \$forget -gt 0 ]]; then
        if [[ \$forget_accept -gt 0 ]]; then
          REPLY=y
        else
          read -q "REPLY?Forget all these results? [y/n] "
        fi
        if [[ \$REPLY =~ "[yY]" ]]; then
            _histdb_query "delete from history where
history.id in (
select history.id from
history
  left join commands on history.command_id = commands.id
  left join places on history.place_id = places.id
where \${where})"
            _histdb_query "delete from commands where commands.id not in (select distinct history.command_id from history)"
        fi
    fi
}
