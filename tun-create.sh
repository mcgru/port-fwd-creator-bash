#!/usr/bin/env bash
# =============================================================================
# tun-create.sh -- настройка ssh-туннеля между двумя хостами
#
# Запускается с управляющего хоста (ноутбука): сам ходит по ssh на оба конца,
# готовит ключ, authorized_keys, known_hosts, оформляет туннель в постоянный
# сервис (systemd --user по умолчанию либо openrc) и печатает памятку для root.
# Привилегированных действий не выполняет.
#
# Форматы запуска (эквивалентные):
#
#   tun-create.sh [u1@]host1:ip1:port1 <направление> u2@host2:ip2:port2 [опции]
#   tun-create.sh u1@host1:127.0.0.1:8080 -R u2@host2:127.0.0.1:80
#   tun-create.sh host1::8080 '}}}' host2::80 --openrc
#   tun-create.sh u1@host1:127.0.0.1:8080 "<<<" u2@host2:10.0.0.5:80 --dry-run
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
#   -d, --dry-run          показать план и ничего не делать
#   -v, --verbose          печатать выполняемые команды
#   -h, --help             справка
#       --version          версия скрипта
# =============================================================================

set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
SCRIPT_VERSION='0.1.0'
SCRIPT_PATH=$0
ORIG_ARGS=("$@")

# -----------------------------------------------------------------------------
# Глобальное состояние (заполняется разбором аргументов и по ходу работы)
# -----------------------------------------------------------------------------
POSITIONAL=()
DIRECTION=''          # L | R
DIR_SRC=''            # option | token | default
INIT_SYSTEM=''        # systemd | openrc
NAME=''
KEY_PATH=''
CTRL_KEY=''           # ключ контроллера для заходов на хосты
CTRL_EXTRA=()         # доп. -o для заходов контроллера
EXTRA_OPTS=()
DRY_RUN=0
VERBOSE=0
FORCE=0
TEARDOWN=0
STEP_NO=1

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
die()  { printf '\nошибка: %s\n' "$*" >&2; exit 1; }

usage() {
    # шапка файла и есть справка: печатаем от заголовка до закрывающей линии
    sed -n '/^# tun-create.sh/,/^# =====/p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
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
    local short='hvdfo:LlRr:n:k:K:O:'
    local long='help,version,dry-run,verbose,force,local,remote,systemd,openrc,teardown,remove,name:,key:,ctrl-key:,ctrl-ssh-option:,ssh-option:'
    local parsed d v
    local -a parts=()

    command -v getopt >/dev/null 2>&1 || die "нужен getopt (util-linux)"

    if ! parsed=$(getopt -o "$short" --long "$long" -n "$SCRIPT_NAME" -- "$@"); then
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

    case ${#POSITIONAL[@]} in
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
            die "нужно 2 или 3 позиционных аргумента, а не ${#POSITIONAL[@]}"
            ;;
    esac

    DIRECTION=${DIRECTION:-L}
    DIR_SRC=${DIR_SRC:-default}
    INIT_SYSTEM=${INIT_SYSTEM:-systemd}
    NAME=$(sanitize_name "${NAME:-ssh-tun-${E2_HOST}-${E2_PORT}}")

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
    NET_IP1=${E1_IP:-127.0.0.1}
    NET_IP2=${E2_IP:-127.0.0.1}

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
    printf '  сервис на host1:     %s\n' "$NAME"
    printf '  менеджер сервисов:   %s\n' "$( [[ $INIT_SYSTEM == systemd ]] && printf 'systemd --user' || printf 'openrc' )"
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
    ssh-keygen -q -t ed25519 -N '' -C "tun-create:$(id -un)@$(hostname -s)" -f "$key" >/dev/null 2>&1 \
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

    local comment="tun-create:${H1_USER}@${E1_HOST}->${E2_HOST}:${E2_PORT}"
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
            if [ "$force" = 1 ]; then
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
                printf 'RESULT=updated\n'
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
        updated)    log "  строка ключа переписана под $PERMIT_OPTS" ;;
        restricted)
            warn "ключ уже прописан, но без $PERMIT_KIND=\"$PERMIT_VALUE\""
            warn "если туннель не поднимется -- добавь опцию в строку руками или запусти с --force"
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
    step "Проверяю, что порт ${LISTEN_PORT} слушается на ${LISTEN_IP}"

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
        VERIFY_OK=1
        printf '  слушается:\n'
        sed 's/^/    /' <<<"$out"
    else
        VERIFY_OK=0
        warn "порт ${LISTEN_PORT} пока не слушается"
    fi
}

# -----------------------------------------------------------------------------
# Памятка для root: готовые блоки через пустую строку
# -----------------------------------------------------------------------------
print_memo() {
    printf '\nПамятка\n'

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
    printf '  4. host1: оформить сервис %s (%s)\n' "$NAME" "$INIT_SYSTEM"
    printf '  5. проверить, что порт %s слушается на %s\n' "$LISTEN_PORT" "$LISTEN_IP"
    printf '\nКоманда туннеля (<HOME>, <u1>, <u2> заменятся на реальные значения):\n\n'
    printf '  ssh %s\n' "$SSH_ARGS_STR"

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
# main
# -----------------------------------------------------------------------------
main() {
    command -v ssh >/dev/null 2>&1 || die "нужен ssh"
    command -v sed >/dev/null 2>&1 || die "нужен sed"
    command -v base64 >/dev/null 2>&1 || die "нужен base64 (coreutils)"

    parse_args "$@"
    resolve_endpoints
    setup_forward
    print_plan

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
    detect_init

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
    stage_persistence
    do_verify
    print_memo

    printf '\nКоманда туннеля (выполняется на host1):\n\n  ssh %s\n' "$SSH_ARGS_STR"
}

main "$@"
