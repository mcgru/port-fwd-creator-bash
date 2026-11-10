#!/usr/bin/env bash
# =============================================================================
# port-fwd-creator.sh -- настройка ssh-туннеля между двумя хостами
#
# Запускается с управляющего хоста (ноутбука): сам ходит по ssh на оба конца,
# готовит ключ, authorized_keys, known_hosts, оформляет туннель в постоянный
# сервис (systemd --user по умолчанию либо openrc) и печатает памятку для root.
# Привилегированных действий не выполняет.
#
# Форматы запуска (эквивалентные):
#
#   port-fwd-creator.sh [u1@]host1:ip1:port1 <направление> u2@host2:ip2:port2 [опции]
#   port-fwd-creator.sh u1@host1:127.0.0.1:8080 -R u2@host2:127.0.0.1:80
#   port-fwd-creator.sh host1::8080 '}}}' host2::80 --openrc
#   port-fwd-creator.sh u1@host1:127.0.0.1:8080 "<<<" u2@host2:10.0.0.5:80 --dry-run
#   port-fwd-creator.sh --from sss::18080 --to ttt::22 -L --no-persist
#   port-fwd-creator.sh --run 4459 --to ttt::172.17.0.1:4444
#
# Направление -- это то, с какой стороны слушается порт, то есть какой флаг
# уйдёт в ssh. Само ssh-соединение туннеля всегда инициируется с host1 на host2.
#
#   -L -l --local   >  >>  >>>   }  }}  }}}   слушает host1 (по умолчанию)
#   -R -r --remote  <  <<  <<<   {  {{  {{{   слушает host2
#
# Токены с '>' в шелле обязательно брать в кавычки, иначе это редирект.
#
# ip1:port1 -- адрес на стороне host1, ip2:port2 -- на стороне host2.
# Пустой ip (host2::80) означает 127.0.0.1.
# IPv6-адрес пишется в квадратных скобках: host:[::1]:8080.
#
# Опции:
#   -L, -l, --local        слушать на host1 (по умолчанию)
#   -R, -r, --remote       слушать на host2
#       --systemd          сервис systemd --user (по умолчанию)
#       --openrc           сервис openrc; файлы готовим у пользователя, ставит root
#   -n, --name <имя>       имя сервиса (по умолчанию ssh-tun-<host2>-<port2>)
#   -k, --key <путь>       ключ на host1 (по умолчанию ~/.ssh/id_ed25519)
#   -o, --ssh-option <список>
#                          доп. опции ssh через пробел, каждая станет своим -o:
#                          -o 'Compression=yes ProxyJump=bastion'
#   -K, --ctrl-key <путь>  ключ контроллера для заходов на host1/host2
#                          (включает IdentitiesOnly: спасение от MaxAuthTries,
#                          когда в агенте много ключей)
#   -O, --ctrl-ssh-option <список>
#                          доп. опции ssh для заходов контроллера, через пробел
#   -f, --force            перезаписать чужой юнит и обновить опции строки ключа
#       --teardown, --remove
#                          снять сервис на host1 (строку ключа не трогает)
#       --no-persist       настроить туннель, но не создавать сервис
#                          (ни systemd, ни openrc): удобно для разовых проверок
#       --check            только проверить, настроен ли туннель (ничего не меняет)
#       --history          показать все успешные создания из history.success
#       --from <адрес>     адрес host1 вместо первого аргумента; опция сильнее
#                          аргумента, поэтому при расхождении берётся она
#       --to <адрес>       адрес host2 вместо второго аргумента
#       --run <момент>     повторить самый свежий успешный запуск, время
#                          которого оканчивается на <момент> (сс, ммсс или
#                          ччммсс; ведущие нули не важны, дата не участвует).
#                          Поиск идёт с конца history.success, берётся первое
#                          совпадение; адреса и опции берутся из истории, но
#                          текущие опции главнее: --from/--to, -L/-R,
#                          --no-persist и прочие применяются поверх.
#                          Позиционные адреса с --run не указываются.
#                          Перед реальным запуском показывает найденный момент
#                          и итоговую команду, затем спрашивает
#                          "Запускаем? [Y/n]": Enter или y -- запуск, n или
#                          Ctrl+C -- отмена. С --dry-run и --check не спрашивает.
#   -d, --dry-run          показать план и ничего не делать
#   -v, --verbose          печатать выполняемые команды
#   -h, --help             справка
#       --version          версия скрипта
#
# История работы пишется на управляющем хосте в ~/.local/share/port-fwd-creator/:
# history.run -- все запуски, history.success -- успешные создания туннелей.
# =============================================================================

set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
SCRIPT_VERSION='0.1.0'
SCRIPT_PATH=$0
ORIG_ARGS=("$@")

# Набор опций для getopt: им же канонизируются аргументы из истории (--run),
# поэтому список живёт в одном месте.
OPT_SHORT='hvdfo:LlRr:n:k:K:O:'
OPT_LONG='help,version,dry-run,verbose,force,local,remote,systemd,openrc,no-persist,teardown,remove,check,history,name:,key:,ctrl-key:,ctrl-ssh-option:,ssh-option:,from:,to:,run:'

# -----------------------------------------------------------------------------
# Глобальное состояние (заполняется разбором аргументов и по ходу работы)
# -----------------------------------------------------------------------------
POSITIONAL=()
DIRECTION=''          # L | R
DIR_SRC=''            # option | token | default
INIT_SYSTEM=''        # systemd | openrc
NAME=''
KEY_PATH=''
FROM_OPT=''           # --from: адрес host1, сильнее позиционного аргумента
TO_OPT=''             # --to: адрес host2
RUN_MOMENT=''         # --run: момент успешного запуска из history.success
CTRL_KEY=''           # ключ контроллера для заходов на хосты
CTRL_EXTRA=()         # доп. -o для заходов контроллера
EXTRA_OPTS=()
DRY_RUN=0
VERBOSE=0
FORCE=0
TEARDOWN=0
NOPERSIST=0           # --no-persist: настроить, но сервис не создавать
CHECK=0               # --check: только проверка, без изменений
HISTORY=0             # --history: показать history.success
STEP_NO=1

# Режим запуска попадает в историю; пусто -- запуск не пишем (help, version).
RUN_MODE=''
RUN_START=$SECONDS
RUN_LOGGED=0
LAST_ERROR=''
CHECK_TOTAL=0
CHECK_FAIL=0

# История работы хранится на управляющем хосте, не на концах туннеля.
HISTORY_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/port-fwd-creator
HISTORY_RUN=$HISTORY_DIR/history.run
HISTORY_SUCCESS=$HISTORY_DIR/history.success

# host1/host2, разобранные из аргументов
E1_USER=''; E1_HOST=''; E1_IP=''; E1_PORT=''
E2_USER=''; E2_HOST=''; E2_IP=''; E2_PORT=''

# Канонические параметры из ssh -G (конфиг читает сам ssh, мы файл не открываем)
H1_CANON_HOST=''; H1_SSH_PORT=''; H1_CFG_USER=''
H2_CANON_HOST=''; H2_SSH_PORT=''; H2_CFG_USER=''

# Факты, собранные на хостах
H1_USER=''; H1_HOME=''; H1_KEY_PATH=''; H1_PUB=''; H1_PTYPE=''; H1_PBLOB=''
H2_USER=''; H2_HOME=''

# Правило проброса
NET_IP1=''; NET_IP2=''
FWD_ARGS=()
LISTEN_TARGET=''; LISTEN_IP=''; LISTEN_PORT=''
PERMIT_KIND=''; PERMIT_VALUE=''; PERMIT_OPTS=''
SSH_ARGS=(); SSH_ARGS_STR=''

# Результаты этапа персистентности
SERVICE_STATE=''; SERVICE_FILE=''; SERVICE_START=''; LINGER_VALUE=''
OPENRC_INIT_PATH=''; OPENRC_CONF_PATH=''
VERIFY_OK=0

# ssh-опции, с которыми контроллер ходит на хосты: только ключи из конфига,
# без интерактива и без «спросить про новый ключ хоста».
CTRL_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)

# -----------------------------------------------------------------------------
# Вывод. Для человека -- без разметки и бэктиков, чтобы можно было копировать.
# -----------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
step() { printf '\n[%d] %s\n' "$STEP_NO" "$*"; STEP_NO=$((STEP_NO + 1)); }
warn() { printf 'внимание: %s\n' "$*" >&2; }

# Текст ошибки сохраняем и для истории, чтобы по history.run было видно причину.
die() {
    LAST_ERROR=$*
    LAST_ERROR=${LAST_ERROR//$'\n'/ }
    printf '\nошибка: %s\n' "$*" >&2
    exit 1
}

usage() {
    # шапка файла и есть справка: печатаем от заголовка до закрывающей линии
    sed -n '/^# port-fwd-creator.sh/,/^# =====/p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

# -----------------------------------------------------------------------------
# Мелкие помощники
# -----------------------------------------------------------------------------

# Печать команды в том виде, в котором её можно скопировать в шелл.
show_cmd() {
    local first=1 a
    for a in "$@"; do
        (( first )) || printf ' '
        printf '%q' "$a"
        first=0
    done
    printf '\n'
}

# Показать и выполнить локальную команду.
run() {
    if (( VERBOSE )); then printf '  + '; show_cmd "$@"; fi
    "$@"
}

# Выполнить скрипт на удалённом хосте (скрипт приходит на stdin, аргументы -- в $1..).
# ssh склеивает аргументы команды через пробел и отдаёт строку удалённому шеллу,
# поэтому каждый аргумент экранируем сам: иначе '>' или пробел в значении
# превратятся в редирект/лишнее слово на той стороне.
remote() {
    local target=$1 cmd
    shift
    cmd=$(printf '%q ' "$@")
    if (( VERBOSE )); then printf '  + ssh %s %s\n' "$target" "$cmd"; fi
    ssh "${CTRL_SSH_OPTS[@]}" -T -- "$target" "$cmd"
}

# Запуск удалённого скрипта с перехватом stdout: remote_out <target> <args...> < скрипт
# Возвращает 1, если ssh/скрипт упал; текст ошибки остаётся в stdout как есть.
remote_out() {
    local target=$1; shift
    remote "$target" bash -s -- "$@"
}

# Квадратные скобки для IPv6 в спецификациях проброса и permit*-опциях.
fmt_addr() {
    case $1 in
        *:*) printf '[%s]' "$1" ;;
        *)   printf '%s' "$1" ;;
    esac
}

is_loopback() {
    case $1 in
        127.*|::1|localhost|'') return 0 ;;
        *) return 1 ;;
    esac
}

# Имя сервиса: только [A-Za-z0-9._-], иначе systemd/openrc будут ругаться.
sanitize_name() {
    local n=${1//[^A-Za-z0-9._-]/-}
    printf '%s\n' "${n:-ssh-tun}"
}

# -----------------------------------------------------------------------------
# История работы: ~/.local/share/port-fwd-creator/history.run -- все запуски,
# history.success -- успешные создания туннелей. Один запуск -- одна строка.
# Пишем из EXIT-ловушки, поэтому в историю попадает и аварийный выход через die.
# -----------------------------------------------------------------------------
history_prepare() {
    local file=$1 header
    if ! mkdir -p "$HISTORY_DIR" 2>/dev/null; then
        warn "не могу создать $HISTORY_DIR -- история не пишется"
        return 1
    fi
    if [[ -e $file ]]; then
        return 0
    fi
    case $file in
        "$HISTORY_RUN")
            header='# время | режим | результат | exit | длительность | сервис | направление | правило | хосты | менеджер | команда'
            ;;
        "$HISTORY_SUCCESS")
            header='# время | статус | сервис | направление | правило | хосты | менеджер | сервисный файл | команда'
            ;;
        *)
            header='#'
            ;;
    esac
    if ! printf '%s\n' "$header" > "$file" 2>/dev/null; then
        warn "не могу писать $file -- история не пишется"
        return 1
    fi
}

# Правило проброса в виде ip1:port1 -> ip2:port2; годится и до setup_forward.
hist_rule() {
    local ip1=${NET_IP1:-${E1_IP:-127.0.0.1}} ip2=${NET_IP2:-${E2_IP:-127.0.0.1}}
    printf '%s:%s -> %s:%s' "$(fmt_addr "$ip1")" "${E1_PORT:-?}" "$(fmt_addr "$ip2")" "${E2_PORT:-?}"
}

hist_hosts() { printf '%s -> %s' "${E1_HOST:-?}" "${E2_HOST:-?}"; }

# Командная строка для истории: направление приводим к -L/-R, чтобы в логе не
# зависеть от того, как его набрали (>>> или -l). Остальные аргументы -- как были.
history_argv() {
    local a
    for a in "${ORIG_ARGS[@]}"; do
        case $a in
            '>'|'>>'|'>>>'|'}'|'}}'|'}}}'|-L|-l|--local)   printf '%s\0' '-L' ;;
            '<'|'<<'|'<<<'|'{'|'{{'|'{{{'|-R|-r|--remote)   printf '%s\0' '-R' ;;
            *)                                              printf '%s\0' "$a" ;;
        esac
    done
}

hist_cmd() {
    local -a args=()
    local a
    while IFS= read -r -d '' a; do
        args+=("$a")
    done < <(history_argv)
    show_cmd "$SCRIPT_PATH" "${args[@]}"
}

history_log_run() {
    local result=$1 rc=$2 dur
    if ! history_prepare "$HISTORY_RUN"; then
        return 0
    fi
    dur=$(( SECONDS - RUN_START ))
    printf '%s  %-8s  %-9s  exit=%-3s  %-4s  %-20s  %-4s  %-34s  %-16s  %-8s  %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$RUN_MODE" "$result" "$rc" "${dur}s" \
        "${NAME:-?}" "${DIRECTION:-?}" "$(hist_rule)" "$(hist_hosts)" "${INIT_SYSTEM:-?}" \
        "$(hist_cmd)${LAST_ERROR:+ | $LAST_ERROR}" >>"$HISTORY_RUN" 2>/dev/null \
        || warn "не смог дописать $HISTORY_RUN"
}

history_log_success() {
    local status=$1 where=$2
    if ! history_prepare "$HISTORY_SUCCESS"; then
        return 0
    fi
    printf '%s  %-9s  %-20s  %-4s  %-34s  %-16s  %-8s  %-46s  %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$status" "$NAME" "$DIRECTION" \
        "$(hist_rule)" "$(hist_hosts)" "$INIT_SYSTEM" "$where" "$(hist_cmd)" \
        >>"$HISTORY_SUCCESS" 2>/dev/null || warn "не смог дописать $HISTORY_SUCCESS"
}

# EXIT-ловушка: фиксирует любой запуск, который дошёл до разбора аргументов.
on_exit() {
    local rc=$1 result
    if (( RUN_LOGGED )) || [[ -z $RUN_MODE ]]; then
        return 0
    fi
    RUN_LOGGED=1
    if (( rc == 0 )); then
        result=ok
    elif (( rc > 128 )); then
        result=interrupted
    else
        result=fail
    fi
    history_log_run "$result" "$rc"
}

# -----------------------------------------------------------------------------
# Разбор аргументов
# -----------------------------------------------------------------------------

# Направление можно задать и опцией, и токеном между хостами.
# Противоречие -- ошибка, повтор того же значения -- нормально.
set_direction() {
    local d=$1 src=$2
    if [[ -n $DIRECTION && $DIRECTION != "$d" ]]; then
        die "конфликт направления: уже задано $DIRECTION ($DIR_SRC), а теперь $d ($src)"
    fi
    DIRECTION=$d
    DIR_SRC=$src
}

set_init() {
    local v=$1
    if [[ -n $INIT_SYSTEM && $INIT_SYSTEM != "$v" ]]; then
        die "конфликт: --systemd и --openrc одновременно"
    fi
    INIT_SYSTEM=$v
}

# Токен направления из позиции между хостами.
parse_direction_token() {
    case $1 in
        '>'|'>>'|'>>>'|'}'|'}}'|'}}}') printf 'L\n' ;;
        '<'|'<<'|'<<<'|'{'|'{{'|'{{{') printf 'R\n' ;;
        *) return 1 ;;
    esac
}

# Разбор [user@]host[:ip]:port.
# Обычный случай -- IFS=: read (быстро и читаемо); IPv6 разбираем встроенными
# средствами bash, потому что read по двоеточиям его не осилит.
# Результат кладётся в E<idx>_USER/E<idx>_HOST/E<idx>_IP/E<idx>_PORT.
parse_endpoint() {
    local raw=$1 idx=$2
    local user='' host='' ip='' port='' rest=''

    [[ -n $raw ]] || die "пустой адрес в аргументе $idx"
    [[ $raw != *[[:space:]]* ]] || die "пробелы внутри адреса: $raw"

    # пользователь отрезается первым: host может быть с @ в конфиге, но не здесь
    if [[ $raw == *@* ]]; then
        user=${raw%%@*}
        rest=${raw#*@}
    else
        rest=$raw
    fi
    [[ -n $rest ]] || die "нет хоста в адресе: $raw"

    if [[ $rest == *'['* ]]; then
        # host:[ipv6]:port -- границы заданы явно, режем подстроками
        host=${rest%%\[*}
        host=${host%:}
        ip=${rest#*\[}
        ip=${ip%%\]*}
        port=${rest#*\]}
        port=${port#:}
        [[ $port != *:* ]] || die "мусор после ] в адресе: $raw"
        [[ -n $ip ]] || die "пустой IPv6-адрес в $raw"
    else
        local colons=${rest//[^:]/}
        if (( ${#colons} > 2 )); then
            die "похоже на IPv6 без скобок: $raw -- пиши адрес в скобках: host:[::1]:port"
        fi
        IFS=: read -r host ip port <<<"$rest"
        # host:port -- ip опущен, сдвигаем поля
        if [[ -n $ip && -z $port ]]; then
            port=$ip
            ip=''
        fi
    fi

    [[ -n $host ]] || die "нет хоста в адресе: $raw"
    [[ $host =~ ^[A-Za-z0-9._-]+$ ]] || die "недопустимый хост: $host"
    [[ -z $user || $user =~ ^[A-Za-z0-9._-]+$ ]] || die "недопустимый пользователь: $user"
    [[ -n $port ]] || die "нет порта в адресе: $raw (пустой ip пишется как host::port)"
    [[ $port =~ ^[0-9]+$ ]] || die "порт не число: $port"
    (( port >= 1 && port <= 65535 )) || die "порт вне 1..65535: $port"
    if [[ -n $ip && ! $ip =~ ^[A-Za-z0-9._:-]+$ ]]; then
        die "недопустимый ip: $ip"
    fi

    printf -v "E${idx}_USER" '%s' "$user"
    printf -v "E${idx}_HOST" '%s' "$host"
    printf -v "E${idx}_IP"   '%s' "$ip"
    printf -v "E${idx}_PORT" '%s' "$port"
}

parse_args() {
    local parsed d v
    local -a parts=()

    command -v getopt >/dev/null 2>&1 || die "нужен getopt (util-linux)"

    if ! parsed=$(getopt -o "$OPT_SHORT" --long "$OPT_LONG" -n "$SCRIPT_NAME" -- "$@"); then
        usage >&2
        exit 2
    fi
    eval set -- "$parsed"

    while true; do
        case $1 in
            -h|--help)    usage; exit 0 ;;
            --version)    printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
            -d|--dry-run) DRY_RUN=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            -f|--force)   FORCE=1 ;;
            --teardown|--remove) TEARDOWN=1 ;;
            --no-persist) NOPERSIST=1 ;;
            --check)      CHECK=1 ;;
            --history)    HISTORY=1 ;;
            --from)       FROM_OPT=$2; shift ;;
            --to)         TO_OPT=$2; shift ;;
            --run)        RUN_MOMENT=$2; shift ;;
            -L|-l|--local)  set_direction L option ;;
            -R|-r|--remote) set_direction R option ;;
            --systemd) set_init systemd ;;
            --openrc)  set_init openrc ;;
            -n|--name) NAME=$2; shift ;;
            -k|--key)  KEY_PATH=$2; shift ;;
            -K|--ctrl-key) CTRL_KEY=$2; shift ;;
            -O|--ctrl-ssh-option)
                v=$2
                parts=()
                read -r -a parts <<<"$v" || true
                CTRL_EXTRA+=("${parts[@]}")
                shift
                ;;
            -o|--ssh-option)
                # список опций через пробел; каждая станет отдельным -o
                v=$2
                parts=()
                read -r -a parts <<<"$v" || true
                EXTRA_OPTS+=("${parts[@]}")
                shift
                ;;
            --)
                shift
                POSITIONAL=("$@")
                break
                ;;
            *)
                die "внутренняя ошибка разбора опций: $1"
                ;;
        esac
        shift
    done

    # --history -- самостоятельный режим: читает файл на контроллере и выходит.
    if (( HISTORY )); then
        if (( ${#POSITIONAL[@]} > 0 )); then
            die "--history только читает историю и не принимает адреса хостов"
        fi
        if (( CHECK || TEARDOWN || DRY_RUN )); then
            die "--history несовместим с --check/--teardown/--dry-run"
        fi
        if [[ -n $RUN_MOMENT ]]; then
            die "--history несовместим с --run"
        fi
        return 0
    fi

    # Режим фиксируем до проверки аргументов: неудачный запуск тоже интересен в истории.
    if (( CHECK )); then
        if (( TEARDOWN )); then
            die "конфликт: --check и --teardown"
        fi
        if (( DRY_RUN )); then
            die "конфликт: --check и --dry-run (проверка и так ничего не меняет)"
        fi
        RUN_MODE=check
    elif (( DRY_RUN )); then
        RUN_MODE=dry-run
    elif (( TEARDOWN )); then
        if (( NOPERSIST )); then
            die "конфликт: --no-persist и --teardown (сервис не создавался)"
        fi
        RUN_MODE=teardown
    else
        RUN_MODE=create
    fi

    local npos=${#POSITIONAL[@]}
    if [[ -n $RUN_MOMENT ]]; then
        # Адреса при --run берутся из history.success; текущие --from/--to и
        # опции -- это оверрайд. Позиционные адреса тут только путали бы.
        if (( npos > 0 )); then
            die "с --run адреса берутся из истории: используй --from/--to и -L/-R, позиционные аргументы не нужны"
        fi
    else
        case $npos in
            0)
                if [[ -z $FROM_OPT || -z $TO_OPT ]]; then
                    usage >&2
                    die "нужны адреса: два позиционных аргумента или --from и --to"
                fi
                ;;
            1)
                # один аргумент дополняет недостающую опцию: --from задан --
                # аргумент описывает host2, и наоборот
                if [[ -n $FROM_OPT ]]; then
                    parse_endpoint "${POSITIONAL[0]}" 2
                elif [[ -n $TO_OPT ]]; then
                    parse_endpoint "${POSITIONAL[0]}" 1
                else
                    die "один адрес без --from/--to не понять: укажи, какой это конец туннеля"
                fi
                ;;
            2)
                parse_endpoint "${POSITIONAL[0]}" 1
                parse_endpoint "${POSITIONAL[1]}" 2
                ;;
            3)
                parse_endpoint "${POSITIONAL[0]}" 1
                if ! d=$(parse_direction_token "${POSITIONAL[1]}"); then
                    die "не понял направление: ${POSITIONAL[1]} (ожидается -L/-R, >, >>, >>>, }, }}, }}}, <, <<, <<<, {, {{, {{{)"
                fi
                set_direction "$d" token
                parse_endpoint "${POSITIONAL[2]}" 2
                ;;
            *)
                usage >&2
                die "нужно 2 или 3 позиционных аргумента, а не $npos"
                ;;
        esac
    fi

    # Опция сильнее аргумента: раз --from/--to написали, она и задаёт адрес.
    # Разбор идёт после позиционных, поэтому просто перекрывает их.
    if [[ -n $FROM_OPT ]]; then
        parse_endpoint "$FROM_OPT" 1
    fi
    if [[ -n $TO_OPT ]]; then
        parse_endpoint "$TO_OPT" 2
    fi

    DIRECTION=${DIRECTION:-L}
    DIR_SRC=${DIR_SRC:-default}
    INIT_SYSTEM=${INIT_SYSTEM:-systemd}
    if [[ -n $RUN_MOMENT && -z $E2_HOST ]]; then
        # адреса ещё не известны -- их принесёт --run; не выдумываем имя
        NAME='?'
    else
        NAME=$(sanitize_name "${NAME:-ssh-tun-${E2_HOST}-${E2_PORT}}")
    fi

    # Заходы контроллера на хосты: если в ssh-агенте много ключей, sshd успевает
    # выдать MaxAuthTries раньше, чем дойдёт до нужного. Явный ключ + IdentitiesOnly
    # режет перебор до одного кандидата.
    local x
    if [[ -n $CTRL_KEY ]]; then
        CTRL_KEY=${CTRL_KEY/#\~/$HOME}
        [[ -r $CTRL_KEY ]] || die "ключ контроллера не читается: $CTRL_KEY"
        CTRL_SSH_OPTS+=(-o IdentitiesOnly=yes -i "$CTRL_KEY")
    fi
    for x in "${CTRL_EXTRA[@]}"; do
        CTRL_SSH_OPTS+=(-o "$x")
    done
}

# Каноническое имя опции, как его отдаёт getopt (один токен на опцию), и
# признак «за ним идёт значение». Для направления печатается ещё L или R.
opt_name() {
    case $1 in
        -h|--help)            printf 'help' ;;
        --version)            printf 'version' ;;
        -d|--dry-run)         printf 'dry-run' ;;
        -v|--verbose)         printf 'verbose' ;;
        -f|--force)           printf 'force' ;;
        -L|-l|--local)        printf 'direction L' ;;
        -R|-r|--remote)       printf 'direction R' ;;
        --systemd)            printf 'systemd' ;;
        --openrc)             printf 'openrc' ;;
        --no-persist)         printf 'no-persist' ;;
        --teardown|--remove)  printf 'teardown' ;;
        --check)              printf 'check' ;;
        --history)            printf 'history' ;;
        -n|--name)            printf 'name 1' ;;
        -k|--key)             printf 'key 1' ;;
        -K|--ctrl-key)        printf 'ctrl-key 1' ;;
        -O|--ctrl-ssh-option) printf 'ctrl-ssh-option 1' ;;
        -o|--ssh-option)      printf 'ssh-option 1' ;;
        --from)               printf 'from 1' ;;
        --to)                 printf 'to 1' ;;
        --run)                printf 'run 1' ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# --run: повтор успешного запуска из history.success
#
# Берём последнюю строку, время которой оканчивается на MOMENT (сс, ммсс или
# ччммсс; ведущие нули не важны). Команда из строки воспроизводится заново,
# но текущие опции главнее: --from/--to, -L/-R и прочие перекрывают
# исторические. Реализация не тащит состояние через глобальные переменные:
# собираем argv и делаем exec того же скрипта.
# -----------------------------------------------------------------------------
run_from_history() {
    local line best='' best_time='' d t rest digits info name cmdline
    local tail head pre parsed
    local -a hist_args=() cur=() kept=() pos=() merged=()
    local -A cur_opt=()
    local cur_dir=''

    digits=${RUN_MOMENT//[^0-9]/}
    [[ -n $digits ]] || die "--run: в MOMENT нет цифр: $RUN_MOMENT"
    (( ${#digits} <= 6 )) || die "--run: MOMENT длиннее 6 цифр (сс, ммсс или ччммсс): $RUN_MOMENT"
    # приведение к целому: 02:44:59, 024459 и 24459 -- одно и то же
    digits=$((10#$digits))

    [[ -f $HISTORY_SUCCESS ]] || die "успешных запусков ещё нет: $HISTORY_SUCCESS"

    # Идём с конца файла: нужно первое совпадение с конца, то есть самый
    # свежий запуск. Дата не участвует, сравнивается только время.
    local -a lines=()
    local i ts n
    mapfile -t lines <"$HISTORY_SUCCESS"
    for (( i = ${#lines[@]} - 1; i >= 0; i-- )); do
        line=${lines[i]}
        case $line in
            ''|'#'*) continue ;;
        esac
        read -r d t rest <<<"$line"
        [[ $t == [0-9][0-9]:[0-9][0-9]:[0-9][0-9] ]] || continue
        # 02:44:59 -> 24459. Отсекаем с конца столько цифр, сколько их в
        # значении --run: 59 -- секунды, 4459 -- минуты и секунды.
        ts=${t//:/}
        ts=$((10#$ts))
        n=$((10 ** ${#digits}))
        if (( ts % n == digits )); then
            best=$line
            best_time="$d $t"
            break
        fi
    done
    [[ -n $best ]] || die "в $HISTORY_SUCCESS нет запуска, время которого оканчивается на $digits"

    # Команда -- в конце строки и начинается с пути к скрипту.
    tail=${best##*"$SCRIPT_NAME"}
    head=${best%"$tail"}
    pre=${head%"$SCRIPT_NAME"}
    pre=${pre%"${pre##*[[:space:]]}"}
    cmdline=${best:${#pre}}
    cmdline=${cmdline%% | *}
    [[ -n $cmdline ]] || die "не нашёл команду в строке истории: $best"

    # В истории строка записана через printf %q, поэтому eval возвращает ровно
    # те же аргументы; первый -- путь к скрипту, его заменяем своим.
    eval "hist_args=($cmdline)" || die "не смог разобрать команду из истории: $cmdline"
    (( ${#hist_args[@]} > 0 )) || die "пустая команда в истории"
    hist_args=("${hist_args[@]:1}")

    # Текущие опции: канонизируем и запоминаем, что перекрывать. Позиционных
    # аргументов с --run нет, поэтому здесь только опции.
    parsed=$(getopt -o "$OPT_SHORT" --long "$OPT_LONG" -n "$SCRIPT_NAME" -- "${ORIG_ARGS[@]}") \
        || die "не смог разобрать текущие опции"
    eval set -- "$parsed"
    while (( $# )); do
        [[ $1 == -- ]] && break
        info=$(opt_name "$1") || die "внутренняя ошибка разбора опции: $1"
        name=${info%% *}
        if [[ $name == run ]]; then
            shift
            shift
            continue
        fi
        if [[ $name == direction ]]; then
            cur_dir=${info#* }
            cur_opt[direction]=1
            cur+=("$1")
            shift
        else
            cur_opt[$name]=1
            cur+=("$1")
            shift
            if [[ $info == *' 1' ]]; then
                cur+=("$1")
                shift
            fi
        fi
    done

    # Опции из истории: --run не повторяем, перекрытое текущими выбрасываем.
    parsed=$(getopt -o "$OPT_SHORT" --long "$OPT_LONG" -n "$SCRIPT_NAME" -- "${hist_args[@]}") \
        || die "не смог разобрать команду из истории: $cmdline"
    eval set -- "$parsed"
    while (( $# )); do
        [[ $1 == -- ]] && { shift; break; }
        info=$(opt_name "$1") || die "не понял опцию в истории: $1"
        name=${info%% *}
        case $name in
            direction)
                if [[ -z $cur_dir ]]; then
                    kept+=("$1")
                fi
                shift
                ;;
            run)
                shift
                shift
                ;;
            *)
                if [[ -n ${cur_opt[$name]:-} ]]; then
                    shift
                    if [[ $info == *' 1' ]]; then shift; fi
                else
                    kept+=("$1")
                    shift
                    if [[ $info == *' 1' ]]; then
                        kept+=("$1")
                        shift
                    fi
                fi
                ;;
        esac
    done
    # После "--" -- позиционные адреса из истории. Направление из этой позиции
    # выбрасываем, если оно задано текущей опцией; адрес -- если его перекрыли
    # текущие --from/--to (иначе в истории останется лишний старый адрес).
    local side=1
    while (( $# )); do
        if parse_direction_token "$1" >/dev/null 2>&1; then
            if [[ -z $cur_dir ]]; then
                pos+=("$1")
            fi
            shift
            continue
        fi
        if (( side == 1 )); then
            if [[ -z ${cur_opt[from]:-} ]]; then
                pos+=("$1")
            fi
            side=2
        else
            if [[ -z ${cur_opt[to]:-} ]]; then
                pos+=("$1")
            fi
        fi
        shift
    done

    merged=("${kept[@]}" "${cur[@]}" -- "${pos[@]}")

    printf '\nНайден успешный запуск %s (%s)\n' "$best_time" "$HISTORY_SUCCESS" >&2
    printf '\nКоманда с учётом текущих опций:\n\n  ' >&2
    show_cmd "$SCRIPT_PATH" "${merged[@]}" >&2

    # --dry-run и --check ничего не меняют, поэтому подтверждение не нужно.
    if (( DRY_RUN || CHECK )); then
        exec "$SCRIPT_PATH" "${merged[@]}"
    fi

    # Без терминала подтвердить некому: молча ничего не запускаем.
    if [[ ! -t 0 ]]; then
        printf '\nНет терминала для подтверждения: запуск отменён, запусти интерактивно.\n' >&2
        RUN_MODE=''
        exit 1
    fi

    local answer=''
    printf '\nЗапускаем? [Y/n] ' >&2
    if ! IFS= read -r answer; then
        # Ctrl+D -- тоже отказ
        printf '\nОтменено.\n' >&2
        RUN_MODE=''
        exit 0
    fi
    case $answer in
        ''|y|Y|yes|Yes|YES|д|Д|да|Да|ДА) : ;;
        *)
            printf 'Отменено.\n' >&2
            RUN_MODE=''
            exit 0
            ;;
    esac

    exec "$SCRIPT_PATH" "${merged[@]}"
}


# -----------------------------------------------------------------------------
# Разрешение хостов через ssh -G
#
# Сам ~/.ssh/config мы не читаем: ssh -G отдаёт то, что из него вышло
# (hostname/port/user). Это нужно, чтобы юнит на host1 не зависел от алиасов,
# которые есть только на ноутбуке.
# -----------------------------------------------------------------------------
resolve_ssh_config() {
    local alias=$1 out host port user
    out=$(ssh -G -- "$alias" 2>/dev/null) || return 1
    host=$(sed -n 's/^hostname //p' <<<"$out" | head -n 1)
    port=$(sed -n 's/^port //p' <<<"$out" | head -n 1)
    user=$(sed -n 's/^user //p' <<<"$out" | head -n 1)
    printf '%s\t%s\t%s\n' "${host:-$alias}" "${port:-22}" "${user:-$(id -un)}"
}

resolve_endpoints() {
    step "Разрешаю хосты через ssh -G"

    local info pj
    if ! info=$(resolve_ssh_config "$E1_HOST"); then
        die "ssh -G не смог разобрать host1: $E1_HOST"
    fi
    IFS=$'\t' read -r H1_CANON_HOST H1_SSH_PORT H1_CFG_USER <<<"$info"

    if ! info=$(resolve_ssh_config "$E2_HOST"); then
        die "ssh -G не смог разобрать host2: $E2_HOST"
    fi
    IFS=$'\t' read -r H2_CANON_HOST H2_SSH_PORT H2_CFG_USER <<<"$info"

    # Алиас host2 может тянуть ProxyJump с ноутбука; на host1 такого конфига нет,
    # и туннель молча сломается. Честно предупреждаем.
    pj=$(ssh -G -- "$E2_HOST" 2>/dev/null | sed -n 's/^proxyjump //p' | head -n 1 || true)
    case $pj in
        ''|none) : ;;
        *) warn "для $E2_HOST в конфиге задан ProxyJump ($pj): с host1 он не применится, там нужен прямой доступ" ;;
    esac

    E1_USER=${E1_USER:-$H1_CFG_USER}
    E2_USER=${E2_USER:-$H2_CFG_USER}

    # Контроллер ходит по алиасу: так работают ключи, порты и ProxyJump из конфига.
    H1_LOGIN="${E1_USER}@${E1_HOST}"
    H2_LOGIN="${E2_USER}@${E2_HOST}"
}

# Правило проброса и сторона, которая слушает.
setup_forward() {
    # localhost -- то же самое, что 127.0.0.1, но в сокете он выглядит иначе;
    # нормализуем сразу, иначе проверка адреса прослушивания не сойдётся.
    NET_IP1=${E1_IP:-127.0.0.1}
    NET_IP2=${E2_IP:-127.0.0.1}
    [[ $NET_IP1 == localhost ]] && NET_IP1=127.0.0.1
    [[ $NET_IP2 == localhost ]] && NET_IP2=127.0.0.1

    FWD_ARGS=()
    if [[ $DIRECTION == L ]]; then
        FWD_ARGS=(-L "$(fmt_addr "$NET_IP1"):${E1_PORT}:$(fmt_addr "$NET_IP2"):${E2_PORT}")
        LISTEN_TARGET=$H1_LOGIN
        LISTEN_IP=$NET_IP1
        LISTEN_PORT=$E1_PORT
        PERMIT_KIND=permitopen
    else
        FWD_ARGS=(-R "$(fmt_addr "$NET_IP2"):${E2_PORT}:$(fmt_addr "$NET_IP1"):${E1_PORT}")
        LISTEN_TARGET=$H2_LOGIN
        LISTEN_IP=$NET_IP2
        LISTEN_PORT=$E2_PORT
        PERMIT_KIND=permitlisten
    fi
    # permit*-опция всегда описывает сторону host2: sshd там решает,
    # куда пускать (-L, permitopen) или что разрешать слушать (-R, permitlisten).
    PERMIT_VALUE="$(fmt_addr "$NET_IP2"):${E2_PORT}"
    PERMIT_OPTS="restrict,port-forwarding,${PERMIT_KIND}=\"${PERMIT_VALUE}\""
}

print_plan() {
    local dir_desc rule_desc
    if [[ $DIRECTION == L ]]; then
        dir_desc="-L, слушает host1"
        rule_desc="$(fmt_addr "$NET_IP1"):${E1_PORT} -> $(fmt_addr "$NET_IP2"):${E2_PORT} (цель видна с host2)"
    else
        dir_desc="-R, слушает host2"
        rule_desc="$(fmt_addr "$NET_IP2"):${E2_PORT} <- $(fmt_addr "$NET_IP1"):${E1_PORT} (цель видна с host1)"
    fi

    printf '\nСостав задачи:\n'
    printf '  host1 (инициатор):   %s  (u1=%s)\n' "$E1_HOST" "$E1_USER"
    printf '  host2 (приёмник):    %s  -> %s:%s\n' "$E2_HOST" "$H2_CANON_HOST" "$H2_SSH_PORT"
    printf '  направление:         %s\n' "$dir_desc"
    printf '  правило:             %s\n' "$rule_desc"
    if (( NOPERSIST )); then
        printf '  сервис на host1:     не создаётся (--no-persist)\n'
    else
        printf '  сервис на host1:     %s\n' "$NAME"
        printf '  менеджер сервисов:   %s\n' "$( [[ $INIT_SYSTEM == systemd ]] && printf 'systemd --user' || printf 'openrc' )"
    fi
    printf '  ключ на host1:       %s\n' "${KEY_PATH:-~/.ssh/id_ed25519}"
    if (( ${#EXTRA_OPTS[@]} )); then
        printf '  доп. опции ssh:      %s\n' "${EXTRA_OPTS[*]}"
    fi
}

# -----------------------------------------------------------------------------
# Этап 1: ключ на host1
# -----------------------------------------------------------------------------
stage_key() {
    step "host1 ($H1_LOGIN): готовлю ключ ${KEY_PATH:-~/.ssh/id_ed25519}"

    local out
    if ! out=$(remote_out "$H1_LOGIN" "${KEY_PATH:--}" <<'REMOTE'
set -u
key=$1
case $key in
    '-')   key="$HOME/.ssh/id_ed25519" ;;
    '~/'*) key="$HOME/${key#\~/}" ;;
    /*)    : ;;
    *)     key="$HOME/.ssh/$key" ;;
esac

umask 077
mkdir -p "$HOME/.ssh" || { echo "ERR нет доступа к $HOME/.ssh"; exit 3; }
chmod 700 "$HOME/.ssh" 2>/dev/null || true

if [ ! -f "$key" ]; then
    command -v ssh-keygen >/dev/null 2>&1 || { echo "ERR на $(hostname -s) нет ssh-keygen"; exit 3; }
    ssh-keygen -q -t ed25519 -N '' -C "port-fwd-creator:$(id -un)@$(hostname -s)" -f "$key" >/dev/null 2>&1 \
        || { echo "ERR ssh-keygen не смог создать $key"; exit 3; }
    state=created
else
    state=exists
fi

# Публичная часть восстанавливается и из приватной: если .pub потерялся, чиним молча.
# Заодно это проверка, что ключ без пароля -- сервис иначе не сможет его использовать.
if ! derived=$(ssh-keygen -y -P '' -f "$key" 2>/dev/null); then
    echo "ERR ключ $key защищён паролем; для сервиса нужен ключ без пароля"
    exit 4
fi
if [ -f "$key.pub" ]; then publine=$(cat "$key.pub"); else publine=$derived; fi

printf 'STATE=%s\n' "$state"
printf 'KEY=%s\n' "$key"
printf 'HOME=%s\n' "$HOME"
printf 'WHO=%s\n' "$(id -un)"
printf 'PUB=%s\n' "$publine"
REMOTE
    ); then
        die "не смог подготовить ключ на host1: $out"
    fi

    local line key_state='exists'
    while IFS= read -r line; do
        case $line in
            STATE=*) key_state=${line#STATE=} ;;
            KEY=*)   H1_KEY_PATH=${line#KEY=} ;;
            HOME=*)  H1_HOME=${line#HOME=} ;;
            WHO=*)   H1_USER=${line#WHO=} ;;
            PUB=*)   H1_PUB=${line#PUB=} ;;
            ERR*)    die "${line#ERR }" ;;
            '')      : ;;
            *)       warn "неожиданный ответ с host1: $line" ;;
        esac
    done <<<"$out"

    [[ -n $H1_PUB && $H1_PUB == ssh-ed25519\ * ]] || die "с host1 не пришёл публичный ключ"
    [[ -n $H1_HOME ]] || die "не удалось определить домашний каталог на host1"

    # Ключ на host1 мог уже быть; тогда state=exists, и это нормально.
    H1_PTYPE=${H1_PUB%% *}
    local tmp=${H1_PUB#* }
    H1_PBLOB=${tmp%% *}

    if [[ $key_state == created ]]; then
        log "  создан ключ $H1_KEY_PATH"
    else
        log "  ключ уже есть: $H1_KEY_PATH"
    fi
    log "  публичная часть: $H1_PTYPE ${H1_PBLOB:0:32}..."
}

# -----------------------------------------------------------------------------
# Этап 2: authorized_keys на host2
# -----------------------------------------------------------------------------
stage_authorized_keys() {
    step "host2 ($H2_LOGIN): проверяю строку ключа в authorized_keys"

    local comment="port-fwd-creator:${H1_USER}@${E1_HOST}->${E2_HOST}:${E2_PORT}"
    local out
    if ! out=$(remote_out "$H2_LOGIN" "$PERMIT_OPTS" "$H1_PTYPE" "$H1_PBLOB" "$comment" "$PERMIT_KIND=\"$PERMIT_VALUE\"" "$FORCE" <<'REMOTE'
set -u
opts=$1; ptype=$2; pblob=$3; comment=$4; req=$5; force=${6:-0}

umask 077
mkdir -p "$HOME/.ssh" || { echo "ERR нет доступа к $HOME/.ssh"; exit 3; }
chmod 700 "$HOME/.ssh" 2>/dev/null || true
ak="$HOME/.ssh/authorized_keys"
[ -f "$ak" ] || : > "$ak"
chmod 600 "$ak" 2>/dev/null || true

# Ищем ключ по телу (второе поле), а не по всей строке: иначе смена опций плодит дубли.
line=$(grep -F -- "$pblob" "$ak" 2>/dev/null | head -n 1 || true)

if [ -z "$line" ]; then
    # файл может не заканчиваться переводом строки -- иначе склеим две записи
    if [ -s "$ak" ] && [ -n "$(tail -c 1 "$ak")" ]; then printf '\n' >> "$ak"; fi
    printf '%s %s %s %s\n' "$opts" "$ptype" "$pblob" "$comment" >> "$ak"
    printf 'RESULT=added\n'
else
    case $line in
        *"$req"*) printf 'RESULT=exists\n' ;;
        *)
            # Строку, созданную этим скриптом, узнаём по комментарию port-fwd-creator:
            # её можно обновлять без --force, она целиком наша. Чужую строку
            # трогаем только по явному --force.
            suffix=${line#*" $ptype $pblob"}
            suffix=${suffix# }
            case $suffix in
                port-fwd-creator:*) owner=ours ;;
                *)            owner=foreign ;;
            esac
            if [ "$force" = 1 ] || [ "$owner" = ours ]; then
                newline="$opts $ptype $pblob $comment"
                tmp=$(mktemp "$HOME/.ssh/.authorized_keys.XXXXXX") || { echo "ERR mktemp"; exit 3; }
                while IFS= read -r l; do
                    case $l in
                        *"$pblob"*) printf '%s\n' "$newline" ;;
                        *)          printf '%s\n' "$l" ;;
                    esac
                done < "$ak" > "$tmp"
                chmod 600 "$tmp"
                mv "$tmp" "$ak"
                if [ "$owner" = ours ]; then
                    printf 'RESULT=updated\n'
                else
                    printf 'RESULT=forced\n'
                fi
            else
                printf 'RESULT=restricted\n'
                printf 'LINE=%s\n' "$line"
            fi
            ;;
    esac
fi

printf 'WHO=%s\n' "$(id -un)"
printf 'HOME=%s\n' "$HOME"
REMOTE
    ); then
        die "не смог разобрать authorized_keys на host2: $out"
    fi

    local line result
    result=''
    while IFS= read -r line; do
        case $line in
            RESULT=*) result=${line#RESULT=} ;;
            WHO=*)    H2_USER=${line#WHO=} ;;
            HOME=*)   H2_HOME=${line#HOME=} ;;
            LINE=*)   printf '  текущая строка: %s\n' "${line#LINE=}" ;;
            ERR*)     die "${line#ERR }" ;;
            '')       : ;;
            *)        warn "неожиданный ответ с host2: $line" ;;
        esac
    done <<<"$out"

    [[ -n $H2_USER ]] || die "не удалось определить пользователя на host2"
    case $result in
        added)      log "  строка ключа добавлена: $PERMIT_OPTS" ;;
        exists)     log "  строка ключа уже есть с нужными опциями" ;;
        updated)    log "  своя строка ключа обновлена под $PERMIT_OPTS" ;;
        forced)     log "  чужая строка ключа переписана под $PERMIT_OPTS (--force)" ;;
        restricted)
            die "ключ на host2 уже прописан с другими опциями, а нужного $PERMIT_KIND=\"$PERMIT_VALUE\" нет.
Строка принадлежит не port-fwd-creator, поэтому без --force её не трогаю.
Либо запусти с --force (строка будет переписана), либо поправь её на host2 руками."
            ;;
        *) die "непонятный результат этапа authorized_keys: ${result:-пусто}" ;;
    esac
}

# -----------------------------------------------------------------------------
# Этап 3: known_hosts на host1
# -----------------------------------------------------------------------------
build_ssh_args() {
    SSH_ARGS=(-N -T)
    # Пользовательские -o идут первыми: ssh берёт первое встреченное значение
    # параметра, поэтому так они могут переопределить наши дефолты.
    local x
    for x in "${EXTRA_OPTS[@]}"; do
        SSH_ARGS+=(-o "$x")
    done
    SSH_ARGS+=(
        -o BatchMode=yes
        -o ExitOnForwardFailure=yes
        -o StrictHostKeyChecking=yes
        -o UserKnownHostsFile="$H1_HOME/.ssh/known_hosts"
        -o IdentitiesOnly=yes
        -i "$H1_KEY_PATH"
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=3
        -o TCPKeepAlive=yes
    )
    if (( H2_SSH_PORT != 22 )); then
        SSH_ARGS+=(-p "$H2_SSH_PORT")
    fi
    SSH_ARGS+=("${FWD_ARGS[@]}" "${H2_USER}@${H2_CANON_HOST}")
    SSH_ARGS_STR="${SSH_ARGS[*]}"
}

stage_known_hosts() {
    step "host1: прописываю host2 в known_hosts (первый коннект идёт с host1)"

    local out
    if ! out=$(remote_out "$H1_LOGIN" "$H2_CANON_HOST" "$H2_USER" "$H2_SSH_PORT" <<'REMOTE'
set -u
host=$1; user=$2; port=$3
# Идентичность host2 уже проверена на предыдущем этапе (мы вошли на него с
# контроллера), поэтому здесь достаточно accept-new: запись появится сама,
# а подмену ключа на уже известном хосте ssh всё равно отвергнет.
out=$(ssh -T -p "$port" -o BatchMode=yes -o ConnectTimeout=10 \
          -o StrictHostKeyChecking=accept-new -- "$user@$host" true 2>&1) \
    && { echo OK; exit 0; }
printf 'ERR %s\n' "$out"
exit 1
REMOTE
    ); then
        die "host1 не смог подключиться к $H2_USER@$H2_CANON_HOST:$H2_SSH_PORT: $out"
    fi
    log "  known_hosts обновлён, коннект host1 -> host2 проходит"
}

# -----------------------------------------------------------------------------
# Этап 4: какой менеджер сервисов на host1
# -----------------------------------------------------------------------------
detect_init() {
    step "host1: определяю менеджер сервисов"

    local out
    if ! out=$(remote_out "$H1_LOGIN" <<'REMOTE'
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    echo systemd
elif command -v rc-service >/dev/null 2>&1 || [ -x /sbin/openrc-run ]; then
    echo openrc
else
    echo unknown
fi
REMOTE
    ); then
        die "не смог определить init на host1"
    fi
    out=${out//[[:space:]]/}

    case $out in
        systemd)
            if [[ $INIT_SYSTEM != systemd ]]; then
                die "на host1 работает systemd, а запрошен openrc. Запусти так:

$(copy_paste_command --systemd)"
            fi
            ;;
        openrc|unknown)
            if [[ $INIT_SYSTEM == systemd && $out == openrc ]]; then
                # ровно то, что просили: ломаемся и печатаем готовую команду
                die "на host1 работает openrc, а не systemd. Запусти так:

$(copy_paste_command --openrc)"
            fi
            if [[ $out == unknown ]]; then
                die "на host1 не нашёл ни systemd, ни openrc; настраивать сервис не на чем"
            fi
            ;;
        *) die "непонятный ответ про init на host1: $out" ;;
    esac
    log "  менеджер сервисов: $out"
}

# Та же команда, что запускали, но с нужным флагом в конце -- чтобы скопировать целиком.
copy_paste_command() {
    local -a parts=("$SCRIPT_PATH")
    local a
    for a in "${ORIG_ARGS[@]}"; do
        case $a in
            --systemd|--openrc) continue ;;
        esac
        parts+=("$a")
    done
    parts+=("$@")
    printf '%q ' "${parts[@]}"
    printf '\n'
}

# -----------------------------------------------------------------------------
# Шаблоны сервисов. __SSH_BIN__ подставляется уже на host1.
# -----------------------------------------------------------------------------
build_systemd_unit() {
    cat <<UNIT
# Сгенерировано ${SCRIPT_NAME} ${SCRIPT_VERSION}
# Туннель: ${DIRECTION} ($([[ $DIRECTION == L ]] && printf 'слушает host1' || printf 'слушает host2'))
# Правило: $(fmt_addr "$NET_IP1"):${E1_PORT} <-> $(fmt_addr "$NET_IP2"):${E2_PORT}
# Соединение инициируется с этого хоста на ${H2_USER}@${H2_CANON_HOST}:${H2_SSH_PORT}
[Unit]
Description=ssh tunnel ${NAME} ($(fmt_addr "$NET_IP1"):${E1_PORT} <-> $(fmt_addr "$NET_IP2"):${E2_PORT})
Documentation=man:ssh(1)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=__SSH_BIN__ ${SSH_ARGS_STR}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIT
}

build_openrc_init() {
    cat <<INIT
#!/sbin/openrc-run
# Сгенерировано ${SCRIPT_NAME} ${SCRIPT_VERSION}
# Туннель: ${DIRECTION} ($([[ $DIRECTION == L ]] && printf 'слушает host1' || printf 'слушает host2'))
# Правило: $(fmt_addr "$NET_IP1"):${E1_PORT} <-> $(fmt_addr "$NET_IP2"):${E2_PORT}
description="ssh tunnel ${NAME}"
command="\${SSH_TUN_BIN:-/usr/bin/ssh}"
command_args="\${SSH_TUN_ARGS}"
command_user="\${SSH_TUN_USER}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
respawn_delay=10
supervisor=supervise-daemon

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory /run --mode 0755
}
INIT
}

build_openrc_conf() {
    cat <<CONF
# Сгенерировано ${SCRIPT_NAME} ${SCRIPT_VERSION}
# Туннель: ${DIRECTION} ($([[ $DIRECTION == L ]] && printf 'слушает host1' || printf 'слушает host2'))
# Правило: $(fmt_addr "$NET_IP1"):${E1_PORT} <-> $(fmt_addr "$NET_IP2"):${E2_PORT}
#
# Сервис работает от имени u1, а не root: ключ и known_hosts указаны
# абсолютными путями, чтобы ничего не зависело от HOME.
SSH_TUN_USER="${H1_USER}"
SSH_TUN_BIN="__SSH_BIN__"
SSH_TUN_ARGS="${SSH_ARGS_STR}"
CONF
}

# -----------------------------------------------------------------------------
# Этап 5: сервис
# -----------------------------------------------------------------------------
stage_persistence_systemd() {
    local unit_b64 out
    unit_b64=$(build_systemd_unit | base64 | tr -d '\n')

    if ! out=$(remote_out "$H1_LOGIN" "$NAME" "$unit_b64" "$FORCE" <<'REMOTE'
set -u
name=$1; b64=$2; force=${3:-0}
command -v base64 >/dev/null 2>&1 || { echo "ERR на $(hostname -s) нет base64"; exit 3; }
ssh_bin=$(command -v ssh || echo /usr/bin/ssh)

dir="$HOME/.config/systemd/user"
mkdir -p "$dir" || { echo "ERR не могу создать $dir"; exit 3; }
tmp=$(mktemp "$dir/.$name.XXXXXX") || { echo "ERR mktemp"; exit 3; }
printf '%s' "$b64" | base64 -d | sed "s|__SSH_BIN__|$ssh_bin|" > "$tmp" \
    || { rm -f "$tmp"; echo "ERR не смог распаковать шаблон"; exit 3; }

f="$dir/$name.service"
if [ -f "$f" ] && cmp -s "$f" "$tmp"; then
    rm -f "$tmp"
    printf 'RESULT=unchanged\nFILE=%s\n' "$f"
    exit 0
fi
if [ -f "$f" ] && [ "$force" != 1 ]; then
    rm -f "$tmp"
    printf 'RESULT=conflict\nFILE=%s\n' "$f"
    exit 0
fi
mv "$tmp" "$f" || { rm -f "$tmp"; echo "ERR не смог записать $f"; exit 3; }
chmod 644 "$f"
printf 'RESULT=written\nFILE=%s\n' "$f"
REMOTE
    ); then
        die "не смог создать юнит systemd на host1: $out"
    fi

    local line
    while IFS= read -r line; do
        case $line in
            RESULT=*) SERVICE_STATE=${line#RESULT=} ;;
            FILE=*)   SERVICE_FILE=${line#FILE=} ;;
            ERR*)     die "${line#ERR }" ;;
            '')       : ;;
        esac
    done <<<"$out"

    case $SERVICE_STATE in
        written)   log "  юнит записан: $SERVICE_FILE" ;;
        unchanged) log "  юнит уже актуален: $SERVICE_FILE" ;;
        conflict)
            die "юнит $SERVICE_FILE уже существует и отличается.
Если он больше не нужен -- удали его или запусти с --force (старый будет перезаписан)."
            ;;
        *) die "непонятный результат записи юнита: ${SERVICE_STATE:-пусто}" ;;
    esac

    # enable/start -- это уже действия пользователя u1, не root: linger нужен
    # только для автозапуска при загрузке, и это уже памятка для root.
    if ! out=$(remote_out "$H1_LOGIN" "$NAME" <<'REMOTE'
set -u
name=$1
uid=$(id -u)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
if ! command -v systemctl >/dev/null 2>&1; then echo 'RESULT=nosystemctl'; exit 0; fi
if ! systemctl --user daemon-reload >/dev/null 2>&1; then echo 'RESULT=nobus'; exit 0; fi
systemctl --user enable "$name.service" >/dev/null 2>&1 || { echo 'RESULT=enable-failed'; exit 0; }
if systemctl --user restart "$name.service" >/dev/null 2>&1; then
    echo 'RESULT=started'
else
    echo 'RESULT=start-failed'
fi
printf 'LINGER=%s\n' "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo unknown)"
# mc "
REMOTE
    ); then
        warn "не смог запустить сервис на host1, смотри памятку ниже"
        SERVICE_START='start-failed'
    else
        while IFS= read -r line; do
            case $line in
                RESULT=*) SERVICE_START=${line#RESULT=} ;;
                LINGER=*) LINGER_VALUE=${line#LINGER=} ;;
            esac
        done <<<"$out"
    fi

    case ${SERVICE_START:-} in
        started)       log "  сервис включён и запущен" ;;
        nobus)         warn "systemctl --user недоступен без сессии/linger: включение оставлено памяткой" ;;
        enable-failed) warn "не удалось выполнить systemctl --user enable" ;;
        start-failed)  warn "сервис не запустился, причина будет видна в journalctl (памятка ниже)" ;;
        *)             warn "непонятный результат запуска: ${SERVICE_START:-пусто}" ;;
    esac
}

stage_persistence_openrc() {
    local init_b64 conf_b64 out
    init_b64=$(build_openrc_init | base64 | tr -d '\n')
    conf_b64=$(build_openrc_conf | base64 | tr -d '\n')

    if ! out=$(remote_out "$H1_LOGIN" "$NAME" "$init_b64" "$conf_b64" <<'REMOTE'
set -u
name=$1; init_b64=$2; conf_b64=$3
command -v base64 >/dev/null 2>&1 || { echo "ERR на $(hostname -s) нет base64"; exit 3; }
ssh_bin=$(command -v ssh || echo /usr/bin/ssh)

dir="$HOME/.local/share/$name"
mkdir -p "$dir/init.d" "$dir/conf.d" || { echo "ERR не могу создать $dir"; exit 3; }

umask 022
printf '%s' "$init_b64" | base64 -d | sed "s|__SSH_BIN__|$ssh_bin|" > "$dir/init.d/$name" \
    || { echo "ERR не смог записать init-скрипт"; exit 3; }
printf '%s' "$conf_b64" | base64 -d | sed "s|__SSH_BIN__|$ssh_bin|" > "$dir/conf.d/$name" \
    || { echo "ERR не смог записать conf.d"; exit 3; }
chmod 755 "$dir/init.d/$name"
chmod 644 "$dir/conf.d/$name"

printf 'INIT=%s\nCONF=%s\n' "$dir/init.d/$name" "$dir/conf.d/$name"
REMOTE
    ); then
        die "не смог подготовить файлы openrc на host1: $out"
    fi

    local line
    while IFS= read -r line; do
        case $line in
            INIT=*) OPENRC_INIT_PATH=${line#INIT=} ;;
            CONF=*) OPENRC_CONF_PATH=${line#CONF=} ;;
            ERR*)   die "${line#ERR }" ;;
            '')     : ;;
        esac
    done <<<"$out"

    [[ -n $OPENRC_INIT_PATH && -n $OPENRC_CONF_PATH ]] || die "не удалось подготовить файлы openrc"
    log "  init-скрипт: $OPENRC_INIT_PATH"
    log "  конфиг:      $OPENRC_CONF_PATH"
    SERVICE_START='need-root'
}

stage_persistence() {
    step "host1: оформляю туннель как сервис ($INIT_SYSTEM)"
    if [[ $INIT_SYSTEM == systemd ]]; then
        stage_persistence_systemd
    else
        stage_persistence_openrc
    fi
}

# -----------------------------------------------------------------------------
# Этап 6: проверка, что порт слушается
# -----------------------------------------------------------------------------
do_verify() {
    step "Проверяю, что порт ${LISTEN_PORT} слушается на $(fmt_addr "$LISTEN_IP")"

    if (( NOPERSIST )); then
        log "  сервис не создавался (--no-persist), прослушивание не проверяю"
        return 0
    fi

    if [[ $SERVICE_START == need-root ]]; then
        # openrc: сервис ставит root, до установки проверять нечего
        log "  сервис ещё не установлен (это делает root), проверка отложена"
        return 0
    fi

    sleep 2
    local out
    if ! out=$(remote_out "$LISTEN_TARGET" "$LISTEN_PORT" <<'REMOTE'
set -u
port=$1
if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$port" 2>/dev/null
elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
fi
REMOTE
    ); then
        out=''
    fi

    if [[ -n $out ]]; then
        # Порт может слушаться не на том адресе, который просили: sshd для -R
        # без GatewayPorts привязывает loopback и молча игнорирует адрес из -R.
        local want line found=0
        local -a f=()
        want="$(fmt_addr "$LISTEN_IP"):${LISTEN_PORT}"
        while IFS= read -r line; do
            read -r -a f <<<"$line"
            [[ ${f[3]:-} == "$want" ]] && found=1
        done <<<"$out"

        if (( found )); then
            VERIFY_OK=1
            printf '  слушается:\n'
            sed 's/^/    /' <<<"$out"
        else
            VERIFY_OK=0
            warn "порт ${LISTEN_PORT} слушается, но не на ${want}:"
            sed 's/^/    /' <<<"$out" >&2
            if [[ $DIRECTION == R ]] && ! is_loopback "$NET_IP2"; then
                warn "sshd на host2 привязал -R к loopback: чтобы слушать $(fmt_addr "$NET_IP2"), в его sshd_config нужен GatewayPorts clientspecified"
            fi
        fi
    else
        VERIFY_OK=0
        warn "порт ${LISTEN_PORT} пока не слушается"
    fi
}

# -----------------------------------------------------------------------------
# --check: только чтение. Проверяет, что туннель из аргументов настроен:
# init на host1, доступ, ключ, строка в authorized_keys, known_hosts, сервис
# и прослушивание порта. Ничего не меняет и не требует root.
# -----------------------------------------------------------------------------
check_ok()   { CHECK_TOTAL=$((CHECK_TOTAL + 1)); printf '  ok    %s\n' "$*"; }
check_no()   { CHECK_TOTAL=$((CHECK_TOTAL + 1)); CHECK_FAIL=$((CHECK_FAIL + 1)); printf '  НЕТ   %s\n' "$*"; }
check_info() { CHECK_TOTAL=$((CHECK_TOTAL + 1)); printf '  инфо  %s\n' "$*"; }

check_init_match() {
    local out
    if ! out=$(remote_out "$H1_LOGIN" <<'REMOTE'
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    echo systemd
elif command -v rc-service >/dev/null 2>&1 || [ -x /sbin/openrc-run ]; then
    echo openrc
else
    echo unknown
fi
REMOTE
    ); then
        check_no "host1 $E1_HOST: ssh недоступен, менеджер сервисов не определить"
        return 0
    fi
    out=${out//[[:space:]]/}
    case $out in
        "$INIT_SYSTEM") check_ok "менеджер сервисов host1: $out (как запрошено)" ;;
        systemd) check_no "host1: systemd, а запрошен openrc. Запусти так: $(copy_paste_command --systemd)" ;;
        openrc)  check_no "host1: openrc, а запрошен systemd. Запусти так: $(copy_paste_command --openrc)" ;;
        *)       check_no "host1: не нашёл ни systemd, ни openrc" ;;
    esac
    return 0
}

# Доступ к обоим хостам и факты о пользователях/домах, нужные остальным проверкам.
check_access() {
    local out line
    if ! out=$(remote_out "$H1_LOGIN" <<'REMOTE'
printf 'WHO=%s\nHOME=%s\n' "$(id -un)" "$HOME"
REMOTE
    ); then
        check_no "host1 $H1_LOGIN: ssh недоступен"
        return 0
    fi
    while IFS= read -r line; do
        case $line in
            WHO=*)  H1_USER=${line#WHO=} ;;
            HOME=*) H1_HOME=${line#HOME=} ;;
        esac
    done <<<"$out"
    check_ok "host1: доступ по ssh есть (пользователь ${H1_USER:-?})"

    if ! out=$(remote_out "$H2_LOGIN" <<'REMOTE'
printf 'WHO=%s\nHOME=%s\n' "$(id -un)" "$HOME"
REMOTE
    ); then
        check_no "host2 $H2_LOGIN: ssh недоступен"
        return 0
    fi
    while IFS= read -r line; do
        case $line in
            WHO=*)  H2_USER=${line#WHO=} ;;
            HOME=*) H2_HOME=${line#HOME=} ;;
        esac
    done <<<"$out"
    check_ok "host2: доступ по ssh есть (пользователь ${H2_USER:-?})"
    return 0
}

check_key() {
    if [[ -z $H1_HOME ]]; then
        check_info "ключ на host1: пропущено, host1 недоступен"
        return 0
    fi
    local out line state='' key='' pub=''
    if ! out=$(remote_out "$H1_LOGIN" "$KEY_PATH" <<'REMOTE'
set -u
key=${1:-}
case $key in
    '')    key="$HOME/.ssh/id_ed25519" ;;
    '~/'*) key="$HOME/${key#\~/}" ;;
    /*)    : ;;
    *)     key="$HOME/.ssh/$key" ;;
esac
printf 'KEY=%s\n' "$key"
if [ ! -f "$key" ]; then echo 'STATE=absent'; exit 0; fi
if ! pub=$(ssh-keygen -y -P '' -f "$key" 2>/dev/null); then
    echo 'STATE=locked'
    exit 0
fi
if [ -f "$key.pub" ]; then publine=$(cat "$key.pub"); else publine=$pub; fi
printf 'STATE=ok\nPUB=%s\n' "$publine"
REMOTE
    ); then
        check_no "ключ на host1: не смог проверить"
        return 0
    fi
    while IFS= read -r line; do
        case $line in
            KEY=*)   key=${line#KEY=} ;;
            STATE=*) state=${line#STATE=} ;;
            PUB=*)   pub=${line#PUB=} ;;
        esac
    done <<<"$out"

    local rest
    case $state in
        ok)
            H1_KEY_PATH=$key
            H1_PUB=$pub
            H1_PTYPE=${pub%% *}
            rest=${pub#* }
            H1_PBLOB=${rest%% *}
            check_ok "ключ на host1: $key (без пароля)"
            ;;
        absent) check_no "ключ на host1 отсутствует: $key (создастся при запуске без --check)" ;;
        locked) check_no "ключ на host1 защищён паролем: $key -- сервис его не использует" ;;
        *)      check_no "ключ на host1: непонятный ответ" ;;
    esac
    return 0
}

check_authorized_keys() {
    if [[ -z $H1_PBLOB ]]; then
        check_info "строка ключа на host2: пропущено, публичный ключ host1 неизвестен"
        return 0
    fi
    if [[ -z $H2_USER ]]; then
        check_info "строка ключа на host2: пропущено, host2 недоступен"
        return 0
    fi
    local out line state='' permit='' cmdopt=''
    if ! out=$(remote_out "$H2_LOGIN" "$H1_PBLOB" "$PERMIT_KIND=\"$PERMIT_VALUE\"" <<'REMOTE'
set -u
ak="$HOME/.ssh/authorized_keys"
if [ ! -f "$ak" ]; then echo 'STATE=absent'; exit 0; fi
line=$(grep -F -- "$1" "$ak" 2>/dev/null | head -n 1 || true)
if [ -z "$line" ]; then echo 'STATE=absent'; exit 0; fi
printf 'STATE=found\nLINE=%s\n' "$line"
case $line in *"$2"*) echo 'PERMIT=yes' ;; *) echo 'PERMIT=no' ;; esac
case $line in *command=*) echo 'CMDOPT=yes' ;; *) echo 'CMDOPT=no' ;; esac
REMOTE
    ); then
        check_no "строка ключа на host2: не смог прочитать authorized_keys"
        return 0
    fi
    while IFS= read -r line; do
        case $line in
            STATE=*)  state=${line#STATE=} ;;
            PERMIT=*) permit=${line#PERMIT=} ;;
            CMDOPT=*) cmdopt=${line#CMDOPT=} ;;
            LINE=*)   printf '  строка: %s\n' "${line#LINE=}" ;;
        esac
    done <<<"$out"

    case $state in
        absent) check_no "строка ключа на host2 отсутствует в authorized_keys" ;;
        found)
            if [[ $cmdopt == yes ]]; then
                check_no "строка ключа на host2 содержит command=... -- проброс не поднимется"
            elif [[ $permit == yes ]]; then
                check_ok "строка ключа на host2 есть с $PERMIT_KIND=\"$PERMIT_VALUE\""
            else
                check_no "ключ на host2 есть, но без $PERMIT_KIND=\"$PERMIT_VALUE\" (исправить: запусти с --force)"
            fi
            ;;
        *) check_no "строка ключа на host2: непонятный ответ" ;;
    esac
    return 0
}

check_known_hosts() {
    if [[ -z $H1_HOME ]]; then
        check_info "known_hosts на host1: пропущено, host1 недоступен"
        return 0
    fi
    local out
    if ! out=$(remote_out "$H1_LOGIN" "$H2_CANON_HOST" "$H2_SSH_PORT" <<'REMOTE'
set -u
host=$1; port=$2
kh="$HOME/.ssh/known_hosts"
if [ ! -f "$kh" ]; then echo missing; exit 0; fi
# ssh-keygen -F понимает и хэшированные записи; '--' старые версии не принимают.
if ssh-keygen -F "$host" -f "$kh" >/dev/null 2>&1; then echo present; exit 0; fi
if ssh-keygen -F "[$host]:$port" -f "$kh" >/dev/null 2>&1; then echo present; exit 0; fi
echo missing
REMOTE
    ); then
        check_no "known_hosts на host1: не смог проверить"
        return 0
    fi
    out=${out//[[:space:]]/}
    if [[ $out == present ]]; then
        check_ok "known_hosts на host1: $H2_CANON_HOST есть"
    else
        check_no "known_hosts на host1: $H2_CANON_HOST отсутствует (появится при запуске без --check)"
    fi
    return 0
}

check_service() {
    if [[ -z $H1_HOME ]]; then
        check_info "сервис на host1: пропущено, host1 недоступен"
        return 0
    fi
    if [[ $INIT_SYSTEM == systemd ]]; then
        check_service_systemd
    else
        check_service_openrc
    fi
}

check_service_systemd() {
    local out line state='' svc_file='' enabled='' active=''
    if ! out=$(remote_out "$H1_LOGIN" "$NAME" <<'REMOTE'
set -u
name=$1
uid=$(id -u)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
f="$HOME/.config/systemd/user/$name.service"
if [ ! -f "$f" ]; then echo 'STATE=absent'; exit 0; fi
printf 'STATE=present\nFILE=%s\n' "$f"
if command -v systemctl >/dev/null 2>&1; then
    printf 'ENABLED=%s\n' "$(systemctl --user is-enabled "$name.service" 2>/dev/null || true)"
    printf 'ACTIVE=%s\n' "$(systemctl --user is-active "$name.service" 2>/dev/null || true)"
else
    echo 'ENABLED=unknown'
    echo 'ACTIVE=unknown'
fi
REMOTE
    ); then
        check_no "юнит systemd на host1: не смог проверить"
        return 0
    fi
    while IFS= read -r line; do
        case $line in
            STATE=*)   state=${line#STATE=} ;;
            FILE=*)    svc_file=${line#FILE=} ;;
            ENABLED=*) enabled=${line#ENABLED=} ;;
            ACTIVE=*)  active=${line#ACTIVE=} ;;
        esac
    done <<<"$out"

    case $state in
        absent)  check_no "юнит systemd отсутствует: ~/.config/systemd/user/$NAME.service" ;;
        present)
            if [[ $enabled == enabled && $active == active ]]; then
                check_ok "юнит systemd включён и запущен: $svc_file"
            elif [[ -z $enabled || $enabled == unknown || $active == unknown ]]; then
                check_info "юнит systemd есть ($svc_file), состояние без systemctl --user не определить"
            elif [[ $enabled != enabled ]]; then
                check_no "юнит systemd есть, но не включён: systemctl --user enable $NAME.service"
            else
                check_no "юнит systemd включён, но не запущен: systemctl --user start $NAME.service"
            fi
            ;;
        *) check_no "юнит systemd: непонятный ответ" ;;
    esac
    return 0
}

check_service_openrc() {
    local out line prepared='' installed='' status='' detail=''
    if ! out=$(remote_out "$H1_LOGIN" "$NAME" <<'REMOTE'
set -u
name=$1
d="$HOME/.local/share/$name"
prepared=no
if [ -f "$d/init.d/$name" ] && [ -f "$d/conf.d/$name" ]; then prepared=yes; fi
installed=no
if [ -f "/etc/init.d/$name" ] && [ -f "/etc/conf.d/$name" ]; then installed=yes; fi
printf 'PREPARED=%s\nINSTALLED=%s\n' "$prepared" "$installed"
if [ "$installed" = yes ]; then
    if st=$(rc-service "$name" status 2>&1); then
        echo 'STATUS=started'
    else
        echo 'STATUS=stopped'
        printf 'DETAIL=%s\n' "$(printf '%s' "$st" | head -n 1)"
    fi
else
    echo 'STATUS=uninstalled'
fi
REMOTE
    ); then
        check_no "сервис openrc на host1: не смог проверить"
        return 0
    fi
    while IFS= read -r line; do
        case $line in
            PREPARED=*)  prepared=${line#PREPARED=} ;;
            INSTALLED=*) installed=${line#INSTALLED=} ;;
            STATUS=*)    status=${line#STATUS=} ;;
            DETAIL=*)    detail=${line#DETAIL=} ;;
        esac
    done <<<"$out"

    if [[ $installed == yes ]]; then
        case $status in
            started) check_ok "сервис openrc установлен и запущен: /etc/init.d/$NAME" ;;
            stopped)
                if [[ $detail == *root* ]]; then
                    check_info "сервис openrc установлен; статус без root не узнать (rc-service $NAME status)"
                else
                    check_no "сервис openrc установлен, но не запущен (root: rc-service $NAME start)"
                fi
                ;;
            *) check_info "сервис openrc установлен; статус не определить" ;;
        esac
    elif [[ $prepared == yes ]]; then
        check_no "файлы сервиса openrc подготовлены, но не установлены: нужен root (install в /etc + rc-update add $NAME default)"
    else
        check_no "сервис openrc не подготовлен на host1"
    fi
    return 0
}

check_port() {
    local out
    if ! out=$(remote_out "$LISTEN_TARGET" "$LISTEN_PORT" <<'REMOTE'
set -u
port=$1
if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$port" 2>/dev/null
elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
fi
REMOTE
    ); then
        check_no "порт ${LISTEN_PORT} на ${LISTEN_TARGET}: не смог проверить"
        return 0
    fi
    if [[ -z ${out//[[:space:]]/} ]]; then
        check_no "порт ${LISTEN_PORT} на $(fmt_addr "$LISTEN_IP") не слушается"
        return 0
    fi

    local want line addr found=0
    local -a f=()
    want="$(fmt_addr "$LISTEN_IP"):${LISTEN_PORT}"
    while IFS= read -r line; do
        read -r -a f <<<"$line"
        [[ ${f[3]:-} == "$want" ]] && found=1
    done <<<"$out"

    if (( found )); then
        check_ok "порт ${LISTEN_PORT} слушается на $(fmt_addr "$LISTEN_IP") (${LISTEN_TARGET##*@})"
        return 0
    fi

    # Адрес не совпал: чаще всего sshd для -R молча привязался к loopback.
    read -r -a f <<<"$(head -n 1 <<<"$out")"
    addr=${f[3]:-неизвестно}
    check_no "порт ${LISTEN_PORT} слушается на ${addr}, а ожидался ${want}"
    return 0
}

do_check() {
    step "Проверяю, настроен ли туннель ${NAME} (только чтение)"
    if (( NOPERSIST )); then
        check_info "менеджер сервисов не важен (--no-persist)"
    else
        check_init_match
    fi
    check_access
    check_key
    check_authorized_keys
    check_known_hosts
    if (( NOPERSIST )); then
        check_info "сервис не запрашивался (--no-persist)"
    else
        check_service
    fi
    check_port

    printf '\nПроверок: %d, проблем: %d\n' "$CHECK_TOTAL" "$CHECK_FAIL"
    if (( CHECK_FAIL == 0 )); then
        log "Туннель ${NAME} настроен."
        return 0
    fi
    warn "туннель ${NAME} настроен не полностью (проблем: $CHECK_FAIL)"
    return 1
}

# -----------------------------------------------------------------------------
# Памятка для root: готовые блоки через пустую строку
# -----------------------------------------------------------------------------
print_memo() {
    printf '\nПамятка\n'

    if (( NOPERSIST )); then
        printf '\nРежим --no-persist: сервис на host1 не создавался, автозапуска нет.\n'
        printf '\nПоднять туннель вручную (пользователь %s на host1 %s):\n\n' "$H1_USER" "$E1_HOST"
        printf 'ssh %s\n' "$SSH_ARGS_STR"
        if [[ $DIRECTION == R ]] && ! is_loopback "$NET_IP2"; then
            printf '\nhost2 слушает не loopback-адрес, для этого в sshd на %s нужен GatewayPorts:\n\n' "$E2_HOST"
            printf 'GatewayPorts clientspecified\n'
            printf '\nБез него sshd привяжет порт к 127.0.0.1, а не к %s.\n' "$(fmt_addr "$NET_IP2")"
        fi
        printf '\nСервиса нет, снимать нечего: достаточно Ctrl+C в окне с ssh.\n'
        return 0
    fi

    if [[ $INIT_SYSTEM == systemd ]]; then
        if [[ ${SERVICE_START:-} != started || ${LINGER_VALUE:-} == no ]]; then
            printf '\nАвтозапуск туннеля после перезагрузки (root на host1 %s):\n\n' "$E1_HOST"
            printf 'loginctl enable-linger %s\n' "$H1_USER"
        fi
        if [[ ${SERVICE_START:-} != started ]]; then
            printf '\nВключить и запустить сервис (пользователь %s на host1):\n\n' "$H1_USER"
            printf 'systemctl --user daemon-reload\n'
            printf 'systemctl --user enable --now %s.service\n' "$NAME"
            printf '\nДиагностика (пользователь %s на host1):\n\n' "$H1_USER"
            printf 'systemctl --user status %s.service\n' "$NAME"
            printf 'journalctl --user -u %s.service -n 30\n' "$NAME"
        fi
    else
        printf '\nФайлы сервиса подготовлены на host1 в %s\n' "$(dirname "$(dirname "$OPENRC_INIT_PATH")")"
# mc "
        printf '\nУстановить сервис (root на host1 %s):\n\n' "$E1_HOST"
        printf 'install -m 755 %s /etc/init.d/%s\n' "$OPENRC_INIT_PATH" "$NAME"
        printf 'install -m 644 %s /etc/conf.d/%s\n' "$OPENRC_CONF_PATH" "$NAME"
        printf '\nВключить в автозапуск (root на host1):\n\n'
        printf 'rc-update add %s default\n' "$NAME"
        printf '\nЗапустить (root на host1):\n\n'
        printf 'rc-service %s start\n' "$NAME"
    fi

    if [[ $DIRECTION == R ]] && ! is_loopback "$NET_IP2"; then
        printf '\nhost2 слушает не loopback-адрес, для этого в sshd на %s нужен GatewayPorts:\n\n' "$E2_HOST"
        printf 'GatewayPorts clientspecified\n'
    fi

    if [[ $SERVICE_START != need-root ]] && ! (( VERIFY_OK )); then
        printf '\nТуннель не подтвердился. Первым делом смотри журнал сервиса на host1 и проверь,\n'
        printf 'что ключ на host2 принят с опциями %s\n' "$PERMIT_OPTS"
    fi

    printf '\nСнять туннель:\n\n'
    printf '  %s\n' "$(copy_paste_command --teardown "--${INIT_SYSTEM}")"
    printf '\nСтрока ключа в authorized_keys на host2 остаётся: ключ может быть общим для других туннелей.\n'
}

# -----------------------------------------------------------------------------
# teardown
# -----------------------------------------------------------------------------
do_teardown() {
    step "Снимаю сервис ${NAME} на host1"

    if [[ $INIT_SYSTEM == systemd ]]; then
        local out
        if ! out=$(remote_out "$H1_LOGIN" "$NAME" <<'REMOTE'
set -u
name=$1
uid=$(id -u)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
f="$HOME/.config/systemd/user/$name.service"
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "$name.service" >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
fi
if [ -f "$f" ]; then rm -f "$f"; printf 'RESULT=removed\nFILE=%s\n' "$f"; else printf 'RESULT=absent\nFILE=%s\n' "$f"; fi
REMOTE
        ); then
            die "не смог снять сервис на host1: $out"
        fi
        local line
        while IFS= read -r line; do
            case $line in
                RESULT=*) log "  ${line#RESULT=}" ;;
                FILE=*)   log "  файл: ${line#FILE=}" ;;
            esac
        done <<<"$out"
    else
        local dir="$H1_HOME/.local/share/$NAME"
        if ! remote_out "$H1_LOGIN" "$dir" <<'REMOTE' >/dev/null
set -u
dir=$1
rm -rf -- "$dir"
REMOTE
        then
            warn "не смог удалить $dir на host1"
        else
            log "  подготовленные файлы удалены: $dir"
        fi
        printf '\nСам сервис из /etc удаляет root на host1 %s:\n\n' "$E1_HOST"
        printf 'rc-service %s stop\n' "$NAME"
        printf 'rc-update del %s default\n' "$NAME"
        printf 'rm -f /etc/init.d/%s /etc/conf.d/%s\n' "$NAME" "$NAME"
    fi

    printf '\nСтрока ключа в authorized_keys на host2 не тронута: она может быть общей для других туннелей.\n'
}

# -----------------------------------------------------------------------------
# dry-run
# -----------------------------------------------------------------------------
print_dry_run() {
    printf '\nПлан действий (--dry-run, по ssh не ходил):\n'
    printf '  1. host1: взять или создать ключ %s\n' "${KEY_PATH:-~/.ssh/id_ed25519}"
    printf '  2. host2: проверить/дописать строку ключа с опциями %s\n' "$PERMIT_OPTS"
    printf '  3. host1: прописать host2 в known_hosts первым коннектом\n'
    if (( NOPERSIST )); then
        printf '  4. сервис не создавать (--no-persist)\n'
    else
        printf '  4. host1: оформить сервис %s (%s)\n' "$NAME" "$INIT_SYSTEM"
        printf '  5. проверить, что порт %s слушается на %s\n' "$LISTEN_PORT" "$(fmt_addr "$LISTEN_IP")"
    fi
    printf '\nКоманда туннеля (<HOME>, <u1>, <u2> заменятся на реальные значения):\n\n'
    printf '  ssh %s\n' "$SSH_ARGS_STR"

    (( NOPERSIST )) && return 0

    printf '\nШаблон сервиса (%s):\n\n' "$INIT_SYSTEM"
    if [[ $INIT_SYSTEM == systemd ]]; then
        build_systemd_unit | sed 's/^/  /'
    else
        build_openrc_init | sed 's/^/  /'
        printf '\n'
        build_openrc_conf | sed 's/^/  /'
    fi
}

# -----------------------------------------------------------------------------
# --history: показать все успешные создания туннелей из history.success
# -----------------------------------------------------------------------------
print_history() {
    local rows
    if [[ ! -f $HISTORY_SUCCESS ]]; then
        log "Успешных созданий пока нет: файла $HISTORY_SUCCESS ещё нет."
        return 0
    fi
    rows=$(grep -cv '^#' "$HISTORY_SUCCESS" 2>/dev/null || true)
    if [[ -z $rows || $rows == 0 ]]; then
        log "Успешных созданий пока нет: $HISTORY_SUCCESS пуст."
        return 0
    fi
    log "Успешные создания туннелей: $HISTORY_SUCCESS (записей: $rows)"
    printf '\n'
    cat "$HISTORY_SUCCESS"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    command -v ssh >/dev/null 2>&1 || die "нужен ssh"
    command -v sed >/dev/null 2>&1 || die "нужен sed"
    command -v base64 >/dev/null 2>&1 || die "нужен base64 (coreutils)"

    parse_args "$@"

    if (( HISTORY )); then
        print_history
        return 0
    fi

    # --run до любых ssh-заходов: он собирает argv и уходит в exec (или в exit,
    # если подтверждения нет).
    if [[ -n $RUN_MOMENT ]]; then
        run_from_history
    fi

    resolve_endpoints
    setup_forward
    print_plan

    if (( CHECK )); then
        do_check && return 0
        return 1
    fi

    if (( DRY_RUN )); then
        # для наглядности подставляем заглушки вместо того, что узнаём по ssh
        H1_HOME=${H1_HOME:-'<HOME>'}
        H1_KEY_PATH=${H1_KEY_PATH:-"$H1_HOME/.ssh/id_ed25519"}
        H1_USER=${H1_USER:-'<u1>'}
        H2_USER=${H2_USER:-'<u2>'}
        build_ssh_args
        print_dry_run
        return 0
    fi

    # Менеджер сервисов проверяем до любых изменений на хостах: незачем
    # создавать ключ и править authorized_keys, если сервис всё равно некуда ставить.
    # В режиме --no-persist сервис не нужен, поэтому менеджер не важен.
    if (( ! NOPERSIST )); then
        detect_init
    fi

    if (( TEARDOWN )); then
        H1_HOME=$(remote_out "$H1_LOGIN" <<'REMOTE' || true
printf '%s\n' "$HOME"
REMOTE
        )
        H1_HOME=${H1_HOME//[[:space:]]/}
        do_teardown
        return 0
    fi

    stage_key
    stage_authorized_keys
    # ssh-команда собирается после whoami на host2: имя пользователя нужно точное
    build_ssh_args
    stage_known_hosts
    if (( NOPERSIST )); then
        log "  режим --no-persist: сервис не создаю, туннель остаётся ручным"
    else
        stage_persistence
        do_verify
    fi

    # В history.success попадает только то, что действительно заработало:
    # systemd -- запущенный сервис и слушающийся порт; openrc -- файлы,
    # готовые к установке root-ом (проверить туннель до установки нельзя).
    # Без сервиса (--no-persist) записывать нечего.
    if (( ! NOPERSIST )); then
        if [[ ${SERVICE_START:-} == started && $VERIFY_OK == 1 ]]; then
            history_log_success ok "$SERVICE_FILE"
        elif [[ ${SERVICE_START:-} == need-root ]]; then
            history_log_success prepared "$OPENRC_INIT_PATH"
        fi
    fi

    print_memo

    # В режиме --no-persist команда туннеля уже напечатана в памятке.
    if (( ! NOPERSIST )); then
        printf '\nКоманда туннеля (выполняется на host1):\n\n  ssh %s\n' "$SSH_ARGS_STR"
    fi
}

# История пишется на выходе: так в неё попадают и штатные запуски, и ошибки.
trap 'on_exit $?' EXIT

main "$@"
