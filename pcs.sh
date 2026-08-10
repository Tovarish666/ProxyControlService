#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  pcs — Proxy Control Service  v2.1
#  https://github.com/Tovarish666/ProxyControlService
#
#  Запуск: bash <(curl -s https://raw.githubusercontent.com/Tovarish666/ProxyControlService/main/pcs.sh)
#
#  Что изменилось против v1.1:
#   • IP ВМ больше не выковыривается из qm terminal через expect. По умолчанию
#     статика через cloud-init, при DHCP — QEMU guest agent. expect выброшен.
#   • SSH на логин/пароль через штатный SSH_ASKPASS_REQUIRE=force (OpenSSH ≥8.4,
#     то есть Proxmox 7 и 8) — никаких sshpass и лишних пакетов на хосте.
#     sshpass используется только как запасной путь на древних хостах.
#     Парольный вход включается ДО первого коннекта,
#     файлом /etc/ssh/sshd_config.d/10-pcs.conf — sshd берёт первое значение,
#     а cloudimg кладёт «PasswordAuthentication no» в 60-…, так что 99-… не работал.
#   • DNS: никакого «rm resolv.conf + chattr +i». Штатный systemd-resolved,
#     глобальные серверы, DHCP-серверы отключены на уровне netplan.
#     Логика вынесена в /usr/local/sbin/pcs-fix-dns — идемпотентно, вызывается
#     из cloud-init и из меню в любой момент.
#   • Нет глобального set -e: шаги установки выполняются в подоболочке,
#     падение шага возвращает в меню, а не убивает pcs.
#   • Установка пишет транскрипт в /var/log/pcs/.
#   • Состояние сохраняется с printf %q и правами 600 (в v1 пароль с пробелом
#     ломал конфиг, а пароль с $(...) исполнялся при следующем запуске).
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

VERSION="2.1"
GITHUB_RAW="https://raw.githubusercontent.com/Tovarish666/ProxyControlService/main"
PROXYVETH_URL="${GITHUB_RAW}/proxyveth.py"
SELF_URL="${GITHUB_RAW}/pcs.sh"

UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_SHA256_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
UBUNTU_IMG_PATH="/var/lib/vz/template/iso/ubuntu-24.04-noble.img"

PCS_DIR="/etc/pcs"
PCS_LOG_DIR="/var/log/pcs"
PCS_TMP="$(mktemp -d /tmp/pcs.XXXXXX)"
PCS_LOG="${PCS_LOG_DIR}/pcs-$(date +%Y%m%d-%H%M%S).log"
PCS_STATE_OUT="${PCS_TMP}/state.out"

# ── Цвета ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    R=$'\033[0m'; G=$'\033[32m'; RD=$'\033[31m'; Y=$'\033[33m'
    C=$'\033[36m'; B=$'\033[1m'; D=$'\033[2m'
else
    R=""; G=""; RD=""; Y=""; C=""; B=""; D=""
fi

_logfile() {
    printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$PCS_LOG" 2>/dev/null || true
}
ok()   { _logfile "OK    $*"; printf '  %s✓%s %s\n'  "$G"  "$R" "$*"; }
warn() { _logfile "WARN  $*"; printf '  %s⚠%s %s\n'  "$Y"  "$R" "$*"; }
bad()  { _logfile "FAIL  $*"; printf '  %s✗%s %s\n'  "$RD" "$R" "$*"; }
step() { _logfile "STEP  $*"; printf '  %s→%s %s\n'  "$D"  "$R" "$*"; }
info() { _logfile "INFO  $*"; printf '  %sℹ%s %s\n'  "$C"  "$R" "$*"; }
hdr()  { _logfile "==== $*"; printf '\n%s══════════════════════════════════════════════\n  %s\n══════════════════════════════════════════════%s\n' "$B" "$*" "$R"; }
die()  { bad "$*"; exit 1; }

# ── Уборка ─────────────────────────────────────────────────────────────────
_spin_pid=""
spinner_start() {
    [[ -t 1 ]] || { step "$1"; return; }
    local msg="$1"
    ( local f=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
      while true; do
          printf '  %s%s%s %s\r' "$C" "${f[$i]}" "$R" "$msg"
          i=$(( (i+1) % 10 )); sleep 0.1
      done ) &
    _spin_pid=$!
}
spinner_stop() {
    [[ -n "${_spin_pid:-}" ]] && kill "$_spin_pid" 2>/dev/null
    _spin_pid=""
    [[ -t 1 ]] && printf '\033[2K\r'
    return 0
}
cleanup_all() { spinner_stop; rm -rf "$PCS_TMP" 2>/dev/null; }
trap cleanup_all EXIT
trap 'spinner_stop; echo; warn "Прервано"; exit 130' INT TERM

# ── Ввод ───────────────────────────────────────────────────────────────────
prompt() {                       # prompt "Метка" "дефолт" VARNAME
    local label="$1" default="${2:-}" varname="$3" reply=""
    if [[ -n "$default" ]]; then
        printf '  %s?%s %s %s[%s]%s: ' "$C" "$R" "$label" "$D" "$default" "$R"
    else
        printf '  %s?%s %s: ' "$C" "$R" "$label"
    fi
    read -r reply </dev/tty || true
    printf -v "$varname" '%s' "${reply:-$default}"
}
prompt_pass() {
    local label="$1" varname="$2" reply=""
    printf '  %s?%s %s: ' "$C" "$R" "$label"
    read -rs reply </dev/tty || true; echo ""
    printf -v "$varname" '%s' "$reply"
}
prompt_choice() {
    printf '  %s»%s Выбор: ' "$C" "$R"
    CHOICE=""
    read -r CHOICE </dev/tty || true
    CHOICE="${CHOICE//[[:space:]]/}"
}
confirm() {                      # confirm "Вопрос" [дефолт yes|no]
    local _a; prompt "$1 (yes/no)" "${2:-no}" _a
    [[ "${_a,,}" == "yes" || "${_a,,}" == "y" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
#  СОСТОЯНИЕ
#  /etc/pcs/vm_<id>.conf — конфиг ВМ, /etc/pcs/active — активная
# ═══════════════════════════════════════════════════════════════════════════
VM_ID=""; VM_NAME=""; VM_IP=""; VM_BRIDGE="vmbr0"; VM_PASSWORD=""
VM_SSH_PORT="22"; VM_DNS1="1.1.1.1"; VM_DNS2="8.8.8.8"; VM_NET_MODE="static"

state_reset() {
    VM_ID=""; VM_NAME=""; VM_IP=""; VM_BRIDGE="vmbr0"; VM_PASSWORD=""
    VM_SSH_PORT="22"; VM_DNS1="1.1.1.1"; VM_DNS2="8.8.8.8"; VM_NET_MODE="static"
}

load_state() {
    state_reset
    mkdir -p "$PCS_DIR"; chmod 700 "$PCS_DIR" 2>/dev/null
    local active=""
    [[ -f "${PCS_DIR}/active" ]] && active=$(<"${PCS_DIR}/active")
    if [[ -n "$active" && -f "${PCS_DIR}/vm_${active}.conf" ]]; then
        # shellcheck disable=SC1090
        source "${PCS_DIR}/vm_${active}.conf" 2>/dev/null || true
    fi
}

load_vm() {                       # load_vm <id>
    state_reset
    if [[ -f "${PCS_DIR}/vm_${1}.conf" ]]; then
        # shellcheck disable=SC1090
        source "${PCS_DIR}/vm_${1}.conf" 2>/dev/null || true
    fi
    VM_ID="$1"
}

save_state() {
    [[ -n "${VM_ID:-}" ]] || return 0
    mkdir -p "$PCS_DIR"; chmod 700 "$PCS_DIR" 2>/dev/null
    local f="${PCS_DIR}/vm_${VM_ID}.conf" t="${PCS_DIR}/.vm_${VM_ID}.tmp"
    {
        echo "# pcs v${VERSION} — состояние ВМ. Значения экранированы, не править вручную."
        printf 'VM_ID=%q\n'       "$VM_ID"
        printf 'VM_NAME=%q\n'     "${VM_NAME:-}"
        printf 'VM_IP=%q\n'       "${VM_IP:-}"
        printf 'VM_BRIDGE=%q\n'   "${VM_BRIDGE:-vmbr0}"
        printf 'VM_PASSWORD=%q\n' "${VM_PASSWORD:-}"
        printf 'VM_SSH_PORT=%q\n' "${VM_SSH_PORT:-22}"
        printf 'VM_DNS1=%q\n'     "${VM_DNS1:-1.1.1.1}"
        printf 'VM_DNS2=%q\n'     "${VM_DNS2:-8.8.8.8}"
        printf 'VM_NET_MODE=%q\n' "${VM_NET_MODE:-static}"
    } > "$t"
    chmod 600 "$t"
    mv -f "$t" "$f"
    echo "$VM_ID" > "${PCS_DIR}/active"
    chmod 600 "${PCS_DIR}/active" 2>/dev/null
}

# Шаг выполняется в подоболочке — вернуть наружу переменную можно только так.
state_put() { printf '%s=%q\n' "$1" "$2" >> "$PCS_STATE_OUT"; }

run_step() {                      # run_step "Название" функция [аргументы]
    local title="$1"; shift
    hdr "$title"
    : > "$PCS_STATE_OUT"
    ( set -eu -o pipefail; trap spinner_stop EXIT; "$@" )
    local rc=$?
    if [[ -s "$PCS_STATE_OUT" ]]; then
        # shellcheck disable=SC1090
        source "$PCS_STATE_OUT"
    fi
    : > "$PCS_STATE_OUT"
    if (( rc != 0 )); then
        warn "Шаг «${title}» не выполнен (код ${rc})"
        info "Лог: ${PCS_LOG}"
        return 1
    fi
    ok "Шаг «${title}» выполнен"
    return 0
}

list_vms() {
    local shown=""
    local f id name ip status dot
    for f in "${PCS_DIR}"/vm_*.conf; do
        [[ -f "$f" ]] || continue
        # sourcing в подоболочке — иначе конфиги затирают текущее состояние
        IFS=$'\t' read -r id name ip < <(
            ( unset VM_ID VM_NAME VM_IP
              # shellcheck disable=SC1090
              source "$f" 2>/dev/null
              printf '%s\t%s\t%s\n' "${VM_ID:-}" "${VM_NAME:-?}" "${VM_IP:-}" )
        )
        [[ -n "$id" ]] || continue
        status=$(qm status "$id" 2>/dev/null | awk '{print $2}')
        [[ -n "$status" ]] || status="нет в Proxmox"
        [[ "$status" == "running" ]] && dot="${G}●${R}" || dot="${D}●${R}"
        printf '  %-6s %-20s %-18s %s %s\n' "$id" "$name" "${ip:-—}" "$dot" "$status"
        shown+=" $id "
    done
    while read -r id name status _; do
        [[ -n "$id" && "$id" != "VMID" ]] || continue
        [[ "$shown" == *" $id "* ]] && continue
        [[ "$status" == "running" ]] && dot="${G}●${R}" || dot="${D}●${R}"
        printf '  %-6s %-20s %-18s %s %s\n' "$id" "$name" "—" "$dot" "$status"
    done < <(qm list 2>/dev/null | tail -n +2)
}

select_vm() {
    echo ""
    printf '  %sВыбор ВМ%s\n' "$B" "$R"
    printf '  %s──────────────────────────────────────────────────%s\n' "$D" "$R"
    printf '  %sID     Имя                  IP                 Статус%s\n' "$D" "$R"
    list_vms
    echo ""
    local cur="${VM_ID:-}" newid=""
    prompt "VM ID" "$cur" newid
    [[ -n "$newid" ]] || { warn "ВМ не выбрана"; return 1; }
    if [[ -f "${PCS_DIR}/vm_${newid}.conf" ]]; then
        load_vm "$newid"
        prompt "IP ВМ" "${VM_IP:-}" VM_IP
    else
        state_reset
        VM_ID="$newid"
        VM_NAME=$(qm config "$newid" 2>/dev/null | awk '/^name:/{print $2}')
        [[ -n "$VM_NAME" ]] || VM_NAME="proxyveth"
        prompt "IP ВМ" "" VM_IP
        prompt_pass "Root пароль ВМ (для SSH)" VM_PASSWORD
        warn "ВМ ещё не заводилась через pcs — конфиг создан сейчас"
    fi
    save_state
    ok "Активная ВМ: ${VM_ID} (${VM_NAME}) @ ${VM_IP:-?}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  SSH — логин/пароль, без ключей
#
#  Пароль отдаём через SSH_ASKPASS_REQUIRE=force — это штатный механизм
#  OpenSSH ≥ 8.4 (Proxmox 7 = 8.4, Proxmox 8 = 9.2), никаких лишних пакетов.
#  sshpass остаётся как запасной путь для совсем древних хостов.
# ═══════════════════════════════════════════════════════════════════════════
SSH_METHOD=""; SSH_VER=""; PCS_ASKPASS=""

ssh_setup() {
    PCS_ASKPASS="${PCS_TMP}/askpass"
    printf '#!/bin/sh\nprintf "%%s\\n" "$PCS_SSH_PASS"\n' > "$PCS_ASKPASS"
    chmod 700 "$PCS_ASKPASS"
    local major minor
    SSH_VER=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]\+\.[0-9]\+\).*/\1/p')
    major="${SSH_VER%%.*}"; minor="${SSH_VER##*.}"
    [[ "$major" =~ ^[0-9]+$ ]] || major=0
    [[ "$minor" =~ ^[0-9]+$ ]] || minor=0
    if (( major > 8 || (major == 8 && minor >= 4) )); then
        SSH_METHOD="askpass"
    elif command -v sshpass >/dev/null 2>&1; then
        SSH_METHOD="sshpass"
    else
        SSH_METHOD="none"
    fi
}

ssh_run() {                       # ssh_run <ssh|scp> аргументы...
    local bin="$1"; shift
    case "$SSH_METHOD" in
        askpass)
            PCS_SSH_PASS="${VM_PASSWORD:-}" SSH_ASKPASS="$PCS_ASKPASS" \
            SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
                "$bin" "$@" ;;
        sshpass)
            SSHPASS="${VM_PASSWORD:-}" sshpass -e "$bin" "$@" ;;
        *)
            "$bin" "$@" ;;
    esac
}

# UserKnownHostsFile=/dev/null обязателен: пересозданная ВМ получает тот же IP
# с новым host key, и StrictHostKeyChecking=no от этого НЕ спасает.
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=4
    -o PreferredAuthentications=password,keyboard-interactive
    -o PubkeyAuthentication=no
    -o NumberOfPasswordPrompts=1
)

vm_ssh() {                        # vm_ssh "команда..."
    ssh_run ssh "${SSH_OPTS[@]}" -p "${VM_SSH_PORT:-22}" "root@${VM_IP}" "$@"
}
vm_sh() {                         # vm_sh "многострочный скрипт"
    ssh_run ssh "${SSH_OPTS[@]}" -p "${VM_SSH_PORT:-22}" "root@${VM_IP}" "bash -s" <<<"$1"
}
vm_scp() {                        # vm_scp локальный удалённый
    ssh_run scp "${SSH_OPTS[@]}" -P "${VM_SSH_PORT:-22}" "$1" "root@${VM_IP}:$2"
}
vm_alive() { [[ -n "${VM_IP:-}" ]] && vm_ssh true 2>/dev/null; }
vm_running() { [[ -n "${VM_ID:-}" ]] && qm status "$VM_ID" 2>/dev/null | grep -q running; }

wait_ssh() {                      # wait_ssh <ip> [сек]
    local ip="$1" limit="${2:-420}" elapsed=0
    VM_IP="$ip"
    spinner_start "Ждём SSH на ${ip} (пароль)... 0с"
    while (( elapsed < limit )); do
        if vm_ssh true 2>/dev/null; then spinner_stop; return 0; fi
        sleep 5; elapsed=$((elapsed+5))
        spinner_stop; spinner_start "Ждём SSH на ${ip} (пароль)... ${elapsed}с"
    done
    spinner_stop; return 1
}

need_vm() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { warn "ВМ не выбрана"; select_vm || return 1; }
    if [[ -z "${VM_IP:-}" ]]; then
        prompt "IP ВМ" "" VM_IP; save_state
    fi
    if [[ -z "${VM_PASSWORD:-}" ]]; then
        prompt_pass "Root пароль ВМ" VM_PASSWORD; save_state
    fi
    [[ -n "${VM_IP:-}" ]] || { bad "IP ВМ не задан"; return 1; }
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  pcs-fix-dns — единственное место, где решается вопрос DNS на ВМ
# ═══════════════════════════════════════════════════════════════════════════
fixdns_script() {
cat <<'FIXDNS'
#!/bin/bash
# pcs-fix-dns — приводит DNS ВМ в предсказуемое состояние. Идемпотентно.
#
# Почему не «rm /etc/resolv.conf + chattr +i», как раньше:
#   • при повторном запуске rm падает на immutable-файле и рвал установку;
#   • systemd-resolved продолжал работать и переписывал всё обратно;
#   • любой апдейт/скрипт агрегатора, которому нужен resolv.conf, молча ломался.
# Здесь штатный путь: resolved остаётся, но серверы наши, а DHCP-серверы
# отключены на уровне netplan — их просто нечему перебивать.
set -u
[ -r /etc/default/pcs-dns ] && . /etc/default/pcs-dns
DNS1="${PCS_DNS1:-1.1.1.1}"
DNS2="${PCS_DNS2:-8.8.8.8}"
FAIL=0
log() { echo "[pcs-fix-dns] $*"; }

# 0. снять наследие старых версий pcs
if lsattr -l /etc/resolv.conf 2>/dev/null | grep -qi immutable; then
    chattr -i /etc/resolv.conf 2>/dev/null && log "снят immutable с /etc/resolv.conf"
fi

# 1. глобальные серверы; Domains=~. делает их маршрутом по умолчанию для всех имён
install -d -m 0755 /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-pcs.conf <<EOF
[Resolve]
DNS=$DNS1 $DNS2
FallbackDNS=9.9.9.9 1.0.0.1
Domains=~.
DNSStubListener=yes
DNSSEC=no
DNSOverTLS=no
Cache=yes
ReadEtcHosts=yes
EOF
log "resolved: DNS=$DNS1 $DNS2"

# 2. netplan: не принимать DNS от DHCP. Только для интерфейсов, где DHCP реально
#    включён — иначе netplan ругается на dhcp4-overrides без dhcp4 и валит сеть.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    python3 - <<'PY'
import glob, os, yaml
OUT = '/etc/netplan/99-pcs-dns.yaml'
d4, d6 = set(), set()
for p in sorted(glob.glob('/etc/netplan/*.yaml')):
    if os.path.basename(p) == os.path.basename(OUT):
        continue
    try:
        doc = yaml.safe_load(open(p)) or {}
    except Exception:
        continue
    eth = ((doc.get('network') or {}).get('ethernets') or {})
    for name, cfg in eth.items():
        cfg = cfg or {}
        if cfg.get('dhcp4') in (True, 'true', 'yes', 'on'):
            d4.add(name)
        if cfg.get('dhcp6') in (True, 'true', 'yes', 'on'):
            d6.add(name)
names = sorted(d4 | d6)
if not names:
    if os.path.exists(OUT):
        os.remove(OUT)
    print('[pcs-fix-dns] DHCP-интерфейсов нет — netplan не трогаем')
else:
    lines = ['network:', '  version: 2', '  ethernets:']
    for n in names:
        lines.append('    %s:' % n)
        if n in d4:
            lines += ['      dhcp4-overrides:', '        use-dns: false',
                      '        use-domains: false']
        if n in d6:
            lines += ['      dhcp6-overrides:', '        use-dns: false',
                      '        use-domains: false']
    open(OUT, 'w').write('\n'.join(lines) + '\n')
    os.chmod(OUT, 0o600)
    print('[pcs-fix-dns] DNS от DHCP отключён для: %s' % ', '.join(names))
PY
else
    log "python3/yaml нет — netplan пропущен (resolved всё равно главнее)"
fi

# 3. применяем; если netplan не переваривает наш drop-in — откатываем его,
#    сеть важнее, чем идеальный DNS
if command -v netplan >/dev/null 2>&1; then
    if netplan generate >/dev/null 2>&1; then
        netplan apply >/dev/null 2>&1 || log "netplan apply вернул ошибку"
    else
        log "netplan generate не прошёл — drop-in удалён"
        rm -f /etc/netplan/99-pcs-dns.yaml
        netplan generate >/dev/null 2>&1
    fi
fi

# 4. resolv.conf — штатный симлинк на stub
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-resolved >/dev/null 2>&1
systemctl restart systemd-resolved
sleep 1
resolvectl flush-caches >/dev/null 2>&1

# 5. проверка — без неё «починили» ничего не значит
for h in github.com docs.google.com mobileproxy.space; do
    if getent ahostsv4 "$h" >/dev/null 2>&1; then
        log "resolve $h — ok"
    else
        log "resolve $h — ОШИБКА"
        FAIL=1
    fi
done
[ "$FAIL" = 0 ] && log "DNS в порядке" || log "DNS НЕ в порядке"
exit $FAIL
FIXDNS
}

push_fixdns() {
    local tmp="${PCS_TMP}/pcs-fix-dns"
    fixdns_script > "$tmp"
    vm_scp "$tmp" /usr/local/sbin/pcs-fix-dns
    vm_ssh "chmod 0755 /usr/local/sbin/pcs-fix-dns; \
            printf 'PCS_DNS1=%s\nPCS_DNS2=%s\n' '${VM_DNS1}' '${VM_DNS2}' > /etc/default/pcs-dns"
}

do_fix_dns() {
    need_vm || return 1
    vm_alive || { bad "ВМ недоступна по SSH"; return 1; }
    hdr "DNS на ВМ"
    prompt "Основной DNS"  "${VM_DNS1:-1.1.1.1}" VM_DNS1
    prompt "Резервный DNS" "${VM_DNS2:-8.8.8.8}" VM_DNS2
    save_state
    push_fixdns || { bad "не удалось скопировать pcs-fix-dns"; return 1; }
    vm_ssh "/usr/local/sbin/pcs-fix-dns" 2>&1 | tee -a "$PCS_LOG"
    local rc=${PIPESTATUS[0]}
    echo ""
    vm_ssh "resolvectl status 2>/dev/null | sed -n '1,12p'; echo; ls -l /etc/resolv.conf" 2>/dev/null
    (( rc == 0 )) && ok "DNS настроен" || warn "DNS настроен частично — смотри вывод выше"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  PROXMOX
# ═══════════════════════════════════════════════════════════════════════════
host_net_defaults() {
    local line
    line=$(ip -4 route get 1.1.1.1 2>/dev/null | head -1)
    DEF_GW=$(sed -n 's/.* via \([0-9.]\+\).*/\1/p' <<<"$line")
    DEF_DEV=$(sed -n 's/.* dev \([^ ]\+\).*/\1/p' <<<"$line")
    DEF_SRC=$(sed -n 's/.* src \([0-9.]\+\).*/\1/p' <<<"$line")
    DEF_MASK=""
    if [[ -n "${DEF_DEV:-}" ]]; then
        DEF_MASK=$(ip -4 -o addr show dev "$DEF_DEV" 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[2]}')
    fi
    : "${DEF_GW:=}" "${DEF_DEV:=}" "${DEF_SRC:=}" "${DEF_MASK:=24}"
}

host_apt_install() {              # host_apt_install пакет...
    local out rc
    out=$(DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq 2>&1); rc=$?
    printf '%s\n' "$out" >>"$PCS_LOG"
    if (( rc != 0 )); then
        warn "apt-get update вернул ошибку:"
        printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
        if grep -q 'enterprise\.proxmox\.com' <<<"$out"; then
            info "Это платный репозиторий pve-enterprise: без подписки он всегда отдаёт 401."
            info "Лечится отключением /etc/apt/sources.list.d/pve-enterprise.* и включением pve-no-subscription."
        fi
    fi
    out=$(DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq "$@" 2>&1); rc=$?
    printf '%s\n' "$out" >>"$PCS_LOG"
    if (( rc != 0 )); then
        warn "apt-get install $* не прошёл:"
        printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
    fi
    return $rc
}

ensure_host_deps() {
    local rc=0
    command -v wget   >/dev/null 2>&1 || { bad "на хосте нет wget"; rc=1; }
    command -v base64 >/dev/null 2>&1 || { bad "на хосте нет base64 (coreutils)"; rc=1; }
    ssh_setup
    case "$SSH_METHOD" in
        askpass)
            ok "Парольный SSH: SSH_ASKPASS, OpenSSH ${SSH_VER} — сторонних пакетов не нужно" ;;
        sshpass)
            ok "Парольный SSH: sshpass (OpenSSH ${SSH_VER:-?} старее 8.4)" ;;
        none)
            warn "OpenSSH ${SSH_VER:-?} старее 8.4 и sshpass не установлен"
            step "Пробуем поставить sshpass..."
            if host_apt_install sshpass; then
                SSH_METHOD="sshpass"; ok "sshpass установлен"
            else
                bad "Парольный SSH недоступен"
                info "Поставь вручную:  apt-get install -y sshpass"
                rc=1
            fi ;;
    esac
    return $rc
}

ensure_ubuntu_image() {
    local expected actual
    expected=$(wget -qO- --timeout=30 "$UBUNTU_SHA256_URL" \
               | awk '/noble-server-cloudimg-amd64\.img$/{print $1; exit}')
    [[ -n "$expected" ]] || { bad "не удалось получить SHA256SUMS (DNS на хосте?)"; return 1; }
    if [[ -f "$UBUNTU_IMG_PATH" ]]; then
        step "Проверяем SHA256 локального образа..."
        actual=$(sha256sum "$UBUNTU_IMG_PATH" | awk '{print $1}')
        if [[ "$actual" == "$expected" ]]; then ok "Образ на месте, SHA256 совпал"; return 0; fi
        warn "SHA256 не совпал (upstream обновился) — качаем заново"
        rm -f "$UBUNTU_IMG_PATH"
    fi
    mkdir -p "$(dirname "$UBUNTU_IMG_PATH")"
    step "Качаем Ubuntu 24.04 cloud image (~600 MB)..."
    wget -q --show-progress --timeout=60 -O "$UBUNTU_IMG_PATH" "$UBUNTU_IMG_URL" || {
        rm -f "$UBUNTU_IMG_PATH"; bad "не скачалось"; return 1; }
    actual=$(sha256sum "$UBUNTU_IMG_PATH" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || { rm -f "$UBUNTU_IMG_PATH"; bad "SHA256 не совпал"; return 1; }
    ok "Образ скачан и проверен"
}

# Хранилище для сниппетов cloud-init (нужно для user-data)
SNIP_STORE="local"; SNIP_DIR="/var/lib/vz/snippets"
ensure_snippets() {
    if pvesm status --content snippets 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$SNIP_STORE"; then
        mkdir -p "$SNIP_DIR"; return 0
    fi
    local cur
    cur=$(awk '/^dir: local$/{f=1;next} /^[a-z]+: /{f=0} f && /^[[:space:]]*content /{print $2; exit}' /etc/pve/storage.cfg 2>/dev/null)
    [[ -n "$cur" ]] || cur="iso,vztmpl,backup"
    step "Включаем content=snippets на хранилище ${SNIP_STORE}"
    pvesm set "$SNIP_STORE" --content "${cur},snippets" >>"$PCS_LOG" 2>&1 \
        || { bad "не удалось включить snippets на ${SNIP_STORE}"; return 1; }
    mkdir -p "$SNIP_DIR"
}

yaml_sq() { printf "'%s'" "${1//\'/\'\'}"; }

build_cloudinit() {               # build_cloudinit <файл>
    local out="$1"
    local pass_yaml fix_b64
    pass_yaml=$(yaml_sq "$VM_PASSWORD")
    fix_b64=$(fixdns_script | base64 -w0)
    cat > "$out" <<YAML
#cloud-config
# сгенерировано pcs v${VERSION}
hostname: ${VM_NAME}
fqdn: ${VM_NAME}
manage_etc_hosts: true
preserve_hostname: false
disable_root: false
ssh_pwauth: true

users:
  - name: root
    lock_passwd: false

chpasswd:
  expire: false
  users:
    - name: root
      password: ${pass_yaml}
      type: text

package_update: true
package_upgrade: false
packages:
  - qemu-guest-agent
  - curl
  - wget
  - ca-certificates
  - iproute2
  - iptables
  - psmisc
  - net-tools
  - python3
  - mc

write_files:
  - path: /etc/ssh/sshd_config.d/10-pcs.conf
    permissions: '0644'
    content: |
      # 10-, а НЕ 99-: sshd берёт первое найденное значение, а cloud-образ
      # кладёт PasswordAuthentication no в 60-cloudimg-settings.conf.
      PermitRootLogin yes
      PasswordAuthentication yes
      KbdInteractiveAuthentication no
      # без этого логин висит 30с, когда обратной зоны нет
      UseDNS no
  - path: /etc/default/pcs-dns
    permissions: '0644'
    content: |
      PCS_DNS1=${VM_DNS1}
      PCS_DNS2=${VM_DNS2}
  - path: /usr/local/sbin/pcs-fix-dns
    permissions: '0755'
    encoding: b64
    content: ${fix_b64}

runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ /usr/local/sbin/pcs-fix-dns ]
  - [ systemctl, restart, ssh ]
YAML
    chmod 600 "$out"
}

qm_import_disk() {                # qm_import_disk <vmid> <образ> <хранилище>
    # Никакого --format qcow2: на local-lvm (дефолт в промпте!) qcow2 не
    # поддерживается и importdisk падал. Формат выбирает Proxmox.
    if qm importdisk "$1" "$2" "$3" >>"$PCS_LOG" 2>&1; then return 0; fi
    qm disk import "$1" "$2" "$3" >>"$PCS_LOG" 2>&1
}

qm_agent_ip() {                   # qm_agent_ip <vmid>  → IP на stdout
    local out ip
    out=$(qm guest cmd "$1" network-get-interfaces 2>/dev/null) || return 1
    ip=$(printf '%s' "$out" \
         | grep -oE '"ip-address"[[:space:]]*:[[:space:]]*"[0-9]{1,3}(\.[0-9]{1,3}){3}"' \
         | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' \
         | grep -vE '^(127\.|169\.254\.)' \
         | head -1)
    [[ -n "$ip" ]] || return 1
    printf '%s' "$ip"
}

# ═══════════════════════════════════════════════════════════════════════════
#  ШАГИ УСТАНОВКИ ВМ (выполняются в подоболочке через run_step)
# ═══════════════════════════════════════════════════════════════════════════
st_image()   { ensure_ubuntu_image; }

st_create() {
    step "qm create ${VM_ID}..."
    qm create "$VM_ID" \
        --name    "$VM_NAME"     --memory "$VM_RAM"  --cores "$VM_CORES" \
        --balloon 0              --cpu    host       --numa  0 \
        --net0    "virtio,bridge=${VM_BRIDGE}" \
        --ostype  l26            --machine q35       --scsihw virtio-scsi-single \
        --agent   "enabled=1,fstrim_cloned_disks=1" \
        --serial0 socket         --tablet 0          --onboot 1 \
        --description "создано pcs v${VERSION}"
    ok "VM ${VM_ID} создана"

    step "Импорт диска..."
    qm_import_disk "$VM_ID" "$UBUNTU_IMG_PATH" "$VM_STORAGE"
    local disk
    disk=$(qm config "$VM_ID" | awk -F': ' '/^unused[0-9]+:/{print $2; exit}')
    [[ -n "$disk" ]] || { bad "не нашёл импортированный диск в qm config"; return 1; }
    qm set "$VM_ID" --scsi0 "${disk},discard=on,ssd=1" --boot order=scsi0 >>"$PCS_LOG" 2>&1
    qm resize "$VM_ID" scsi0 "${VM_DISK}G" >>"$PCS_LOG" 2>&1
    ok "Диск подключён и расширен до ${VM_DISK} GB"
}

st_cloudinit() {
    ensure_snippets
    local snip="${SNIP_DIR}/pcs-${VM_ID}.yaml"
    build_cloudinit "$snip"
    ok "user-data: ${snip}"

    # cloudinit-диск: пробуем целевое хранилище, иначе local
    if ! qm set "$VM_ID" --ide2 "${VM_STORAGE}:cloudinit" >>"$PCS_LOG" 2>&1; then
        warn "${VM_STORAGE} не умеет cloudinit — кладём на local"
        qm set "$VM_ID" --ide2 "local:cloudinit" >>"$PCS_LOG" 2>&1
    fi

    # --cicustom user= перекрывает только user-data; network-config Proxmox
    # по-прежнему строит из --ipconfig0/--nameserver.
    qm set "$VM_ID" --cicustom "user=${SNIP_STORE}:snippets/pcs-${VM_ID}.yaml" >>"$PCS_LOG" 2>&1
    qm set "$VM_ID" --nameserver "${VM_DNS1} ${VM_DNS2}" >>"$PCS_LOG" 2>&1

    if [[ "$VM_NET_MODE" == "static" ]]; then
        qm set "$VM_ID" --ipconfig0 "ip=${VM_CIDR},gw=${VM_GW}" >>"$PCS_LOG" 2>&1
        ok "Сеть: статика ${VM_CIDR} gw ${VM_GW}, DNS ${VM_DNS1} ${VM_DNS2}"
    else
        qm set "$VM_ID" --ipconfig0 "ip=dhcp" >>"$PCS_LOG" 2>&1
        ok "Сеть: DHCP, DNS ${VM_DNS1} ${VM_DNS2}"
    fi
}

st_boot() {
    step "Запуск ВМ..."
    qm start "$VM_ID" >>"$PCS_LOG" 2>&1 || qm status "$VM_ID" | grep -q running

    local ip="${VM_IP:-}"
    if [[ "$VM_NET_MODE" != "static" || -z "$ip" ]]; then
        # DHCP: спрашиваем guest agent. Никаких qm terminal + expect.
        local elapsed=0 limit=300
        spinner_start "Ждём QEMU guest agent (IP по DHCP)... 0с"
        while (( elapsed < limit )); do
            if ip=$(qm_agent_ip "$VM_ID"); then spinner_stop; break; fi
            ip=""
            sleep 5; elapsed=$((elapsed+5))
            spinner_stop; spinner_start "Ждём QEMU guest agent (IP по DHCP)... ${elapsed}с"
        done
        spinner_stop
        if [[ -z "$ip" ]]; then
            warn "guest agent не ответил за ${limit}с"
            info "Посмотреть вручную: qm terminal ${VM_ID}  (выход — Ctrl+O)"
            prompt "IP ВМ" "" ip
            [[ -n "$ip" ]] || { bad "IP не задан"; return 1; }
        fi
    fi
    state_put VM_IP "$ip"
    VM_IP="$ip"
    ok "IP ВМ: ${VM_IP}"

    wait_ssh "$VM_IP" 420 || {
        bad "SSH по паролю не поднялся за 7 минут"
        info "Диагностика: qm terminal ${VM_ID} → login root → journalctl -u cloud-init"
        return 1
    }
    ok "SSH по паролю работает"

    step "Ждём завершения cloud-init..."
    vm_ssh "cloud-init status --wait >/dev/null 2>&1; cloud-init status 2>/dev/null || true"
    ok "cloud-init отработал"
}

st_verify() {
    local out
    out=$(vm_sh '
set +e
echo "hostname: $(hostname)"
echo "resolv:   $(readlink -f /etc/resolv.conf)"
echo "dns:      $(resolvectl status 2>/dev/null | grep -m2 "DNS Server" | tr -s " " | paste -sd" ")"
echo "pwauth:   $(sshd -T 2>/dev/null | grep -m1 ^passwordauthentication)"
echo "rootlogin:$(sshd -T 2>/dev/null | grep -m1 ^permitrootlogin)"
echo "agent:    $(systemctl is-active qemu-guest-agent 2>/dev/null)"
for h in github.com docs.google.com mobileproxy.space; do
  getent ahostsv4 $h >/dev/null 2>&1 && echo "resolve $h: ok" || echo "resolve $h: FAIL"
done
')
    printf '%s\n' "$out" | sed 's/^/    /'
    printf '%s\n' "$out" >>"$PCS_LOG"
    if grep -q FAIL <<<"$out"; then
        warn "DNS на ВМ отвечает не полностью — запусти «Настройка → Починить DNS»"
    else
        ok "DNS на ВМ в порядке"
    fi
    grep -q 'passwordauthentication yes' <<<"$out" || warn "sshd: парольный вход выключен (?)"
}

do_install_vm() {
    hdr "Установка ВМ"
    ensure_host_deps || return 1
    host_net_defaults

    local newid=""
    prompt "VM ID" "200" newid
    [[ "$newid" =~ ^[0-9]+$ ]] || { bad "VM ID должен быть числом"; return 1; }
    if qm status "$newid" &>/dev/null; then
        warn "ВМ ${newid} уже существует"
        confirm "Удалить и пересоздать?" "no" || { info "Отменено"; return 1; }
        qm stop "$newid" --skiplock &>/dev/null || true
        local w=0; while qm status "$newid" 2>/dev/null | grep -q running && (( w < 30 )); do sleep 2; w=$((w+2)); done
        qm destroy "$newid" --destroy-unreferenced-disks 1 --purge 1 >>"$PCS_LOG" 2>&1 \
            || { bad "не удалось удалить ВМ ${newid}"; return 1; }
        ok "Старая ВМ удалена"
    fi
    state_reset
    VM_ID="$newid"

    while true; do
        prompt "Имя ВМ (латиница/цифры/дефис)" "proxyveth" VM_NAME
        [[ "$VM_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] && break
        warn "Недопустимое имя «${VM_NAME}»"
    done
    prompt "RAM, MB"  "8192" VM_RAM
    prompt "CPU ядра" "8"    VM_CORES
    prompt "Диск, GB" "50"   VM_DISK

    echo ""
    step "Хранилища:"
    pvesm status 2>/dev/null | awk 'NR>1{printf "      %-20s %-10s\n",$1,$2}'
    prompt "Хранилище" "local-lvm" VM_STORAGE

    step "Мосты:"
    ip -o link show | awk -F': ' '/vmbr/{printf "      %s\n",$2}'
    prompt "Сетевой мост" "vmbr0" VM_BRIDGE

    echo ""
    info "Статика надёжнее: IP известен заранее, ничего не надо выяснять после загрузки."
    local mode=""
    prompt "Сеть ВМ: static или dhcp" "static" mode
    VM_NET_MODE="${mode,,}"
    VM_CIDR=""; VM_GW=""
    if [[ "$VM_NET_MODE" == "static" ]]; then
        info "Хост: ${DEF_SRC:-?} на ${DEF_DEV:-?}, шлюз ${DEF_GW:-?}, маска /${DEF_MASK}"
        local addr=""
        prompt "IP ВМ с маской (напр. 10.0.0.50/${DEF_MASK})" "" addr
        [[ "$addr" == */* ]] || { bad "нужен формат IP/маска"; return 1; }
        VM_CIDR="$addr"
        prompt "Шлюз" "${DEF_GW}" VM_GW
        [[ -n "$VM_GW" ]] || { bad "шлюз не задан"; return 1; }
        VM_IP="${addr%%/*}"
    fi

    prompt "Основной DNS для ВМ"  "1.1.1.1" VM_DNS1
    prompt "Резервный DNS для ВМ" "8.8.8.8" VM_DNS2

    prompt_pass "Root пароль ВМ (им же ходит SSH)" VM_PASSWORD
    [[ -n "$VM_PASSWORD" ]] || { bad "пароль не может быть пустым"; return 1; }
    local pass2=""
    prompt_pass "Повтори пароль" pass2
    [[ "$VM_PASSWORD" == "$pass2" ]] || { bad "пароли не совпали"; return 1; }

    save_state
    info "Транскрипт установки: ${PCS_LOG}"

    run_step "Образ Ubuntu"           st_image     || return 1
    run_step "Создание ВМ"            st_create    || return 1
    run_step "cloud-init"             st_cloudinit || return 1
    run_step "Запуск и ожидание ВМ"   st_boot      || { save_state; return 1; }
    save_state
    run_step "Проверка ВМ"            st_verify    || true
    save_state

    echo ""
    ok "ВМ готова: ID=${VM_ID}  IP=${VM_IP}  пароль сохранён в ${PCS_DIR}/vm_${VM_ID}.conf"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  ProxyVeth
# ═══════════════════════════════════════════════════════════════════════════
st_proxyveth() {
    local pyfile="${PCS_TMP}/proxyveth.py"
    step "Качаем proxyveth.py на хост..."
    wget -q --timeout=30 -O "$pyfile" "$PROXYVETH_URL" || { bad "не скачалось: ${PROXYVETH_URL}"; return 1; }
    head -1 "$pyfile" | grep -q '^#!' || { bad "это не python-скрипт (404?)"; return 1; }

    step "Копируем на ВМ..."
    vm_scp "$pyfile" /usr/local/bin/proxyveth.py
    vm_ssh "chmod +x /usr/local/bin/proxyveth.py && ln -sf /usr/local/bin/proxyveth.py /usr/local/bin/proxyveth"
    vm_ssh "install -d -m 700 /etc/proxyveth /etc/proxyveth/logs"
    ok "proxyveth установлен"

    if [[ -n "${SHEET_CSV_URL:-}" ]]; then
        # через stdin — никаких кавычек и & в удалённой командной строке
        printf 'SHEET_CSV_URL=%s\n' "$SHEET_CSV_URL" \
            | vm_ssh "umask 077; cat > /etc/proxyveth/env"
        ok "Источник конфигурации сохранён"
    else
        vm_ssh "touch /etc/proxyveth/env; chmod 600 /etc/proxyveth/env"
    fi

    step "Зависимости и sing-box..."
    vm_ssh "proxyveth install" 2>&1 | tee -a "$PCS_LOG" | sed 's/^/    /'
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { bad "proxyveth install не прошёл"; return 1; }

    step "systemd-юниты..."
    vm_ssh "proxyveth systemd" 2>&1 | sed 's/^/    /'

    if [[ -n "${SHEET_CSV_URL:-}" ]]; then
        step "sync + up all..."
        vm_ssh "proxyveth sync && proxyveth up all" 2>&1 | tee -a "$PCS_LOG" | tail -20 | sed 's/^/    /'
        vm_ssh "systemctl start proxyveth-watchdog.service proxyveth-autosync.timer" || true
    else
        warn "Источник не задан — namespace не поднимались (Настройка → URL таблицы)"
    fi
}

do_install_proxyveth() {
    hdr "Установка ProxyVeth"
    need_vm || return 1
    ensure_host_deps || return 1
    vm_alive || { bad "ВМ недоступна по SSH (${VM_IP})"; return 1; }
    prompt "URL таблицы/API с прокси (Enter — позже)" "" SHEET_CSV_URL
    run_step "ProxyVeth" st_proxyveth || return 1
    ok "ProxyVeth установлен"
}

# ═══════════════════════════════════════════════════════════════════════════
#  mobileproxy.space
# ═══════════════════════════════════════════════════════════════════════════
st_mp() {
    step "install.sh (может рвать сессию — это нормально)..."
    vm_ssh "wget -qO- https://mobileproxy.space/downloads/sp/install.sh | bash" 2>&1 \
        | tail -20 | sed 's/^/    /' || true

    # Свой токен пишем сразу: install.sh генерит собственный proxy_xxx,
    # а setup-modem-management.sh ниже ребутает ВМ и рвёт сессию.
    step "Пишем auth.mp..."
    printf '%s' "$AUTH_MP_CONTENT" | vm_ssh "install -d -m 755 /home/nodejs/work && cat > /home/nodejs/work/auth.mp"
    vm_ssh "systemctl restart mproxy nodejs-server 2>/dev/null || true"
    ok "auth.mp записан"

    step "setup-modem-management.sh (ставит GRUB/initramfs и ребутает)..."
    vm_ssh "wget -qO- https://mobileproxy.space/downloads/sp/setup-modem-management.sh | bash" 2>&1 \
        | tail -20 | sed 's/^/    /' || true

    step "Перезагрузка ВМ..."
    vm_ssh "(sleep 1; systemctl reboot) >/dev/null 2>&1 &" >/dev/null 2>&1 || true
    # Ждём, пока реально уйдёт, иначе поймаем умирающий sshd и пойдём дальше
    local w=0
    while (( w < 60 )) && vm_ssh true 2>/dev/null; do sleep 3; w=$((w+3)); done
    wait_ssh "$VM_IP" 300 || { bad "ВМ не поднялась после ребута"; return 1; }
    ok "ВМ перезагружена"

    # Софт агрегатора трогает сеть — DNS перепроверяем и чиним
    step "Перепроверяем DNS после установки агрегатора..."
    push_fixdns
    vm_ssh "/usr/local/sbin/pcs-fix-dns" 2>&1 | sed 's/^/    /' || warn "DNS требует внимания"

    step "Проверка auth.mp..."
    vm_ssh "cat /home/nodejs/work/auth.mp 2>/dev/null || echo '(нет файла)'" | sed 's/^/    /'
    vm_ssh "systemctl is-active mproxy nodejs-server 2>/dev/null || true" | sed 's/^/    сервис: /'
}

do_install_mp() {
    hdr "Установка mobileproxy.space"
    need_vm || return 1
    vm_alive || { bad "ВМ недоступна по SSH"; return 1; }
    echo ""
    info "auth.mp: ЛК → Мой прокси-бизнес → Сервера → иконка ↓ у нужного сервера"
    info "Формат: {\"auth\":\"KEY:KEY\",\"port\":1800}"
    echo ""
    prompt "Содержимое auth.mp" "" AUTH_MP_CONTENT
    [[ -n "${AUTH_MP_CONTENT:-}" ]] || { bad "auth.mp не может быть пустым"; return 1; }
    run_step "mp.space" st_mp || return 1
    ok "mp.space установлен"
}

# ═══════════════════════════════════════════════════════════════════════════
#  НАСТРОЙКА
# ═══════════════════════════════════════════════════════════════════════════
do_set_auth() {
    need_vm || return 1
    info "ЛК → Мой прокси-бизнес → Сервера → иконка ↓"
    local content=""
    prompt "Новое содержимое auth.mp" "" content
    [[ -n "$content" ]] || { bad "пусто"; return 1; }
    printf '%s' "$content" | vm_ssh "cat > /home/nodejs/work/auth.mp" || { bad "не записалось"; return 1; }
    vm_ssh "systemctl restart mproxy nodejs-server 2>/dev/null || true"
    ok "auth.mp обновлён, сервисы перезапущены"
}

do_set_sheet() {
    need_vm || return 1
    local url=""
    prompt "URL таблицы/API (CSV)" "" url
    [[ -n "$url" ]] || { bad "пусто"; return 1; }
    # Пишем через stdin — никакого sed с экранированием & и |
    {
        vm_ssh "grep -v '^SHEET_CSV_URL=' /etc/proxyveth/env 2>/dev/null || true"
        printf 'SHEET_CSV_URL=%s\n' "$url"
    } | vm_ssh "umask 077; install -d -m 700 /etc/proxyveth; cat > /etc/proxyveth/env" \
        || { bad "не записалось"; return 1; }
    ok "URL сохранён"
    confirm "Запустить sync + up all?" "yes" || return 0
    vm_ssh "proxyveth sync && proxyveth up all" 2>&1 | tail -25 | sed 's/^/    /'
}

do_change_vm_params() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { select_vm || return 1; }
    echo ""
    info "Текущие параметры ВМ ${VM_ID}:"
    qm config "$VM_ID" 2>/dev/null | grep -E '^(memory|cores|name|net0):' | sed 's/^/    /'
    echo ""
    local ram="" cores=""
    prompt "RAM, MB (Enter — без изменений)"  "" ram
    prompt "CPU ядра (Enter — без изменений)" "" cores
    [[ -n "$ram"   ]] && { qm set "$VM_ID" --memory "$ram"   >>"$PCS_LOG" 2>&1 && ok "RAM = ${ram} MB"; }
    [[ -n "$cores" ]] && { qm set "$VM_ID" --cores  "$cores" >>"$PCS_LOG" 2>&1 && ok "CPU = ${cores}"; }
    warn "Применится после перезапуска ВМ"
}

do_change_password() {
    need_vm || return 1
    local p1="" p2=""
    prompt_pass "Новый root пароль" p1
    [[ -n "$p1" ]] || { bad "пусто"; return 1; }
    prompt_pass "Повтори" p2
    [[ "$p1" == "$p2" ]] || { bad "не совпали"; return 1; }
    # через stdin, а не 'echo root:...' — пароль с кавычкой ломал команду
    printf 'root:%s' "$p1" | vm_ssh "chpasswd" || { bad "не сменился"; return 1; }
    qm set "$VM_ID" --cipassword "$p1" >>"$PCS_LOG" 2>&1 || true
    VM_PASSWORD="$p1"; save_state
    vm_alive && ok "Пароль изменён и проверен" || warn "Пароль изменён, но SSH не проверился"
}

do_set_ssh() {
    need_vm || return 1
    echo ""
    info "Действующие настройки sshd:"
    vm_ssh "sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|usedns)'" | sed 's/^/    /'
    echo ""
    local newport=""
    prompt "Новый SSH порт (Enter — не менять)" "" newport
    [[ -n "$newport" ]] || { info "Без изменений"; return 0; }
    [[ "$newport" =~ ^[0-9]+$ ]] || { bad "порт должен быть числом"; return 1; }
    # На Ubuntu 24.04 ssh поднят через сокет-активацию: Port в sshd_config
    # игнорируется, менять надо ListenStream у ssh.socket.
    vm_sh "
set -e
if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    install -d /etc/systemd/system/ssh.socket.d
    printf '[Socket]\nListenStream=\nListenStream=${newport}\n' > /etc/systemd/system/ssh.socket.d/10-pcs-port.conf
    systemctl daemon-reload
    systemctl restart ssh.socket
    echo 'порт задан через ssh.socket'
else
    sed -i 's/^#*Port .*/Port ${newport}/' /etc/ssh/sshd_config
    printf 'Port ${newport}\n' > /etc/ssh/sshd_config.d/11-pcs-port.conf
    systemctl restart ssh
    echo 'порт задан через sshd_config'
fi" | sed 's/^/    /' || { bad "не применилось"; return 1; }
    VM_SSH_PORT="$newport"; save_state
    if vm_alive; then ok "SSH работает на порту ${newport}"
    else warn "SSH на ${newport} не отвечает — проверь через qm terminal ${VM_ID}"; fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  УПРАВЛЕНИЕ
# ═══════════════════════════════════════════════════════════════════════════
pv() { need_vm || return 1; vm_ssh "proxyveth $*"; }

do_pv_status()     { pv status; }
do_pv_status_wan() { pv status --wan; }
do_pv_problems()   { pv problems; }
do_pv_sync()       { pv "sync && proxyveth up all"; }
do_pv_doctor()     { pv doctor; }

do_pv_restart() {
    need_vm || return 1
    local t=""; prompt "Номер NS или all" "all" t
    vm_ssh "proxyveth restart ${t}" 2>&1 | tail -30 | sed 's/^/    /'
}
do_pv_check() {
    need_vm || return 1
    local n=""; prompt "Номер модема" "" n
    [[ -n "$n" ]] || { bad "пусто"; return 1; }
    vm_ssh "proxyveth check ${n}"
}
do_pv_logs() {
    need_vm || return 1
    info "Ctrl+C для выхода"
    vm_ssh "tail -f /etc/proxyveth/logs/watchdog.log" || true
}

do_reboot_vm() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { select_vm || return 1; }
    qm reboot "$VM_ID" >>"$PCS_LOG" 2>&1 || { need_vm && vm_ssh "systemctl reboot" || true; }
    ok "ВМ перезагружается"
}

do_show_summary() {
    need_vm || return 1
    local wan
    wan=$(vm_ssh "curl -s -4 --max-time 6 http://ip-api.com/line/?fields=query" 2>/dev/null | head -1)
    [[ -n "$wan" ]] || wan="—"
    echo ""
    printf '  %sСводка для ЛК mobileproxy.space:%s\n' "$G" "$R"
    printf '  %s════════════════════════════════════════%s\n' "$B" "$R"
    printf '  Статический IP : %s\n' "$wan"
    printf '  LocalIP        : %s\n' "$VM_IP"
    printf '  Root login     : root\n'
    printf '  Root password  : %s\n' "${VM_PASSWORD:-(не сохранён)}"
    printf '  SSH порт       : %s\n' "${VM_SSH_PORT:-22}"
    printf '  OS             : Unix\n'
    printf '  %s════════════════════════════════════════%s\n' "$B" "$R"
    printf '  ЛК → Мой прокси-бизнес → Сервера → ✏ Редактировать\n\n'
}

do_destroy_vm() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { select_vm || return 1; }
    warn "ЭТО УДАЛИТ ВМ ${VM_ID} (${VM_NAME:-?}) БЕЗВОЗВРАТНО"
    local c=""; prompt "Введи DELETE для подтверждения" "" c
    [[ "$c" == "DELETE" ]] || { info "Отменено"; return 0; }
    qm stop "$VM_ID" --skiplock &>/dev/null || true
    local w=0; while qm status "$VM_ID" 2>/dev/null | grep -q running && (( w < 30 )); do sleep 2; w=$((w+2)); done
    qm destroy "$VM_ID" --destroy-unreferenced-disks 1 --purge 1 >>"$PCS_LOG" 2>&1 \
        || { bad "не удалилось"; return 1; }
    rm -f "${PCS_DIR}/vm_${VM_ID}.conf" "${SNIP_DIR}/pcs-${VM_ID}.yaml"
    [[ "$(cat "${PCS_DIR}/active" 2>/dev/null)" == "$VM_ID" ]] && rm -f "${PCS_DIR}/active"
    state_reset
    ok "ВМ удалена"
}

do_doctor() {
    hdr "Диагностика"
    local bad_n=0
    chk() { if [[ "$1" == "0" ]]; then ok "$2"; else bad "$2"; bad_n=$((bad_n+1)); fi; }

    printf '\n  %sХост Proxmox%s\n' "$B" "$R"
    command -v qm      >/dev/null; chk $? "qm"
    command -v pvesm   >/dev/null; chk $? "pvesm"
    command -v wget    >/dev/null; chk $? "wget"
    ssh_setup
    case "$SSH_METHOD" in
        askpass) ok "парольный SSH: SSH_ASKPASS (OpenSSH ${SSH_VER})" ;;
        sshpass) ok "парольный SSH: sshpass (OpenSSH ${SSH_VER:-?})" ;;
        *)       bad "парольный SSH недоступен (OpenSSH ${SSH_VER:-?} < 8.4 и нет sshpass)"; bad_n=$((bad_n+1)) ;;
    esac
    getent ahostsv4 cloud-images.ubuntu.com >/dev/null 2>&1; chk $? "DNS хоста: cloud-images.ubuntu.com"
    getent ahostsv4 raw.githubusercontent.com >/dev/null 2>&1; chk $? "DNS хоста: raw.githubusercontent.com"
    pvesm status --content snippets 2>/dev/null | awk 'NR>1{print $1}' | grep -qx local; chk $? "хранилище local умеет snippets"

    load_state
    if [[ -z "${VM_ID:-}" ]]; then
        warn "ВМ не выбрана — проверки ВМ пропущены"
    else
        printf '\n  %sВМ %s (%s)%s\n' "$B" "$VM_ID" "${VM_NAME:-?}" "$R"
        vm_running; chk $? "ВМ запущена"
        vm_alive;   chk $? "SSH по паролю (${VM_IP:-?}:${VM_SSH_PORT:-22})"
        if vm_alive; then
            local out
            out=$(vm_sh '
set +e
cloud-init status 2>/dev/null | head -1
echo "resolv-link: $(readlink -f /etc/resolv.conf)"
for h in github.com docs.google.com mobileproxy.space; do
  getent ahostsv4 $h >/dev/null 2>&1 && echo "dns-ok $h" || echo "dns-FAIL $h"
done
echo "mproxy: $(systemctl is-active mproxy 2>/dev/null)"
echo "proxyveth: $(systemctl is-active proxyveth 2>/dev/null)"
echo "watchdog: $(systemctl is-active proxyveth-watchdog 2>/dev/null)"
')
            printf '%s\n' "$out" | sed 's/^/      /'
            grep -q 'dns-FAIL' <<<"$out" && { bad "DNS на ВМ сломан — Настройка → Починить DNS"; bad_n=$((bad_n+1)); } \
                                         || ok "DNS на ВМ в порядке"
            echo ""
            info "proxyveth doctor:"
            vm_ssh "proxyveth doctor" 2>/dev/null | sed 's/^/      /' || warn "proxyveth не установлен"
        fi
    fi
    echo ""
    (( bad_n == 0 )) && ok "Проблем не найдено" || bad "Проблем: ${bad_n}"
}

do_selfupdate() {
    step "Качаем последнюю версию..."
    local tmp="${PCS_TMP}/pcs.new"
    wget -q --timeout=30 -O "$tmp" "$SELF_URL" || { bad "не скачалось"; return 1; }
    bash -n "$tmp" 2>/dev/null || { bad "скачанный файл не проходит проверку синтаксиса — не ставлю"; return 1; }
    local newver; newver=$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)
    [[ -n "$newver" ]] || { bad "не удалось определить версию"; return 1; }
    if [[ "$newver" == "$VERSION" ]]; then ok "Уже актуальная версия (v${VERSION})"; return 0; fi
    install -m 0755 "$tmp" /usr/local/bin/pcs || { bad "не установилось"; return 1; }
    ok "Обновлено: v${VERSION} → v${newver}. Перезапускаю."
    exec /usr/local/bin/pcs
}

self_install() {
    local target="/usr/local/bin/pcs"
    [[ -f "$target" ]] && return 0
    confirm "Установить pcs как команду ${target}?" "yes" || return 0
    if [[ -f "${BASH_SOURCE[0]}" ]] && bash -n "${BASH_SOURCE[0]}" 2>/dev/null; then
        install -m 0755 "${BASH_SOURCE[0]}" "$target"
    else
        wget -q --timeout=30 -O "$target" "$SELF_URL" && chmod 0755 "$target" \
            || { warn "не установилось"; return 0; }
    fi
    ok "Готово — дальше просто: pcs"
}

# ═══════════════════════════════════════════════════════════════════════════
#  DASHBOARD + МЕНЮ
# ═══════════════════════════════════════════════════════════════════════════
DASH_CACHE=""; DASH_CACHE_TS=0
show_dashboard() {
    load_state
    local vm_status="нет ВМ" vm_dot="${D}●${R}" st_mp="—" st_pv="—" wan="—"
    if [[ -n "${VM_ID:-}" ]]; then
        if vm_running; then
            vm_status="running"; vm_dot="${G}●${R}"
            local now; now=$(date +%s)
            # опрос ВМ кэшируем: в v1 каждая перерисовка меню = SSH + внешний HTTP
            if (( now - DASH_CACHE_TS > 20 )); then
                DASH_CACHE=$(vm_ssh "printf '%s|%s|%s' \
                    \"\$(systemctl is-active mproxy 2>/dev/null || echo inactive)\" \
                    \"\$(systemctl is-active proxyveth 2>/dev/null || echo inactive)\" \
                    \"\$(curl -s -4 --max-time 4 http://ip-api.com/line/?fields=query 2>/dev/null | head -1)\"" 2>/dev/null)
                DASH_CACHE_TS=$now
            fi
            if [[ -n "$DASH_CACHE" ]]; then
                IFS='|' read -r st_mp st_pv wan <<<"$DASH_CACHE"
            fi
        else
            vm_status="stopped"; vm_dot="${RD}●${R}"
        fi
    fi
    local dot_mp dot_pv
    [[ "$st_mp" == "active" ]] && dot_mp="${G}●${R}" || dot_mp="${RD}●${R}"
    [[ "$st_pv" == "active" ]] && dot_pv="${G}●${R}" || dot_pv="${RD}●${R}"
    [[ "$st_mp" == "—" ]] && dot_mp="${D}●${R}"
    [[ "$st_pv" == "—" ]] && dot_pv="${D}●${R}"

    printf '\n  %s┌────────────────────────────────────────────────┐%s\n' "$B" "$R"
    printf   '  %s│  pcs v%-4s — Proxy Control Service              │%s\n' "$B" "$VERSION" "$R"
    printf   '  %s└────────────────────────────────────────────────┘%s\n' "$B" "$R"
    if [[ -n "${VM_ID:-}" ]]; then
        printf '  ВМ #%-5s %s%-18s%s %s %s\n' "$VM_ID" "$B" "${VM_NAME:-?}" "$R" "$vm_dot" "$vm_status"
        printf '  IP: %-22s WAN: %s\n' "${VM_IP:-—}" "${wan:-—}"
    else
        printf '  %sВМ не выбрана — [v] Выбрать ВМ%s\n' "$D" "$R"
    fi
    printf '  mp.space:   %s %s\n' "$dot_mp" "$st_mp"
    printf '  ProxyVeth:  %s %s\n' "$dot_pv" "$st_pv"
    echo ""
}

menu_install() {
    while true; do
        printf '\n  %sУстановка%s  %s(активная ВМ: %s)%s\n' "$B" "$R" "$D" "${VM_ID:-не выбрана}" "$R"
        printf '  %s──────────────────────────────────────────────%s\n' "$D" "$R"
        echo "  [1] Только ВМ"
        echo "  [2] Только ProxyVeth"
        echo "  [3] Только софт mp.space"
        echo "  [4] ВМ + ProxyVeth"
        echo "  [5] Полный стек  (ВМ → ProxyVeth → mp.space)"
        echo "  [0] ← Назад"
        echo ""
        prompt_choice
        case "${CHOICE:-}" in
            1) do_install_vm ;;
            2) do_install_proxyveth ;;
            3) do_install_mp ;;
            4) do_install_vm && do_install_proxyveth ;;
            5) do_install_vm && do_install_proxyveth && do_install_mp ;;
            0) return 0 ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

menu_config() {
    while true; do
        load_state
        printf '\n  %sНастройка%s  %s(ВМ: %s @ %s)%s\n' "$B" "$R" "$D" "${VM_ID:-?}" "${VM_IP:-?}" "$R"
        printf '  %s──────────────────────────────────────────────%s\n' "$D" "$R"
        echo "  [1] Ключ mp.space (auth.mp)"
        echo "  [2] URL таблицы / API с прокси"
        echo "  [3] Параметры ВМ (RAM / CPU)"
        echo "  [4] Root пароль ВМ"
        echo "  [5] SSH порт"
        echo "  [6] IP адрес ВМ (если изменился)"
        echo "  [7] Починить DNS на ВМ"
        echo "  [0] ← Назад"
        echo ""
        prompt_choice
        case "${CHOICE:-}" in
            1) do_set_auth ;;
            2) do_set_sheet ;;
            3) do_change_vm_params ;;
            4) do_change_password ;;
            5) do_set_ssh ;;
            6) load_state; prompt "Новый IP ВМ" "${VM_IP:-}" VM_IP; save_state; ok "IP: ${VM_IP}" ;;
            7) do_fix_dns ;;
            0) return 0 ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

menu_manage() {
    while true; do
        load_state
        printf '\n  %sУправление%s  %s(ВМ: %s @ %s)%s\n' "$B" "$R" "$D" "${VM_ID:-?}" "${VM_IP:-?}" "$R"
        printf '  %s──────────────────────────────────────────────%s\n' "$D" "$R"
        echo "  [1] Dashboard"
        echo "  [2] proxyveth status"
        echo "  [3] proxyveth status --wan"
        echo "  [4] Проблемные модемы"
        echo "  [5] proxyveth sync + up all"
        echo "  [6] proxyveth restart"
        echo "  [7] Диагностика модема (check N)"
        echo "  [8] Логи watchdog"
        echo "  [9] Сводка для ЛК mp.space"
        echo "  [r] Ребут ВМ      [x] Диагностика всего (doctor)"
        echo "  [d] Удалить ВМ    [u] Обновить pcs"
        echo "  [0] ← Назад"
        echo ""
        prompt_choice
        case "${CHOICE:-}" in
            1) DASH_CACHE_TS=0; show_dashboard ;;
            2) do_pv_status ;;
            3) do_pv_status_wan ;;
            4) do_pv_problems ;;
            5) do_pv_sync ;;
            6) do_pv_restart ;;
            7) do_pv_check ;;
            8) do_pv_logs ;;
            9) do_show_summary ;;
            r|R) do_reboot_vm ;;
            x|X) do_doctor ;;
            d|D) do_destroy_vm ;;
            u|U) do_selfupdate ;;
            0) return 0 ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

main_menu() {
    while true; do
        show_dashboard
        printf '  %s[1]%s Установка  %s[2]%s Настройка  %s[3]%s Управление  %s[v]%s Сменить ВМ  %s[x]%s Диагностика  %s[q]%s Выход\n' \
               "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R"
        echo ""
        prompt_choice
        case "${CHOICE:-}" in
            1) menu_install ;;
            2) menu_config ;;
            3) menu_manage ;;
            v|V) select_vm; DASH_CACHE_TS=0 ;;
            x|X) do_doctor ;;
            q|Q|0) echo ""; exit 0 ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════
[[ $EUID -eq 0 ]]            || die "Запускай от root на хосте Proxmox"
command -v qm    >/dev/null  || die "qm не найден — это не хост Proxmox"
command -v pvesm >/dev/null  || die "pvesm не найден"

mkdir -p "$PCS_DIR" "$PCS_LOG_DIR"
chmod 700 "$PCS_DIR" 2>/dev/null
: > "$PCS_LOG"; chmod 600 "$PCS_LOG"
_logfile "pcs v${VERSION} запущен"
ssh_setup

case "${1:-}" in
    -h|--help|help)
        cat <<EOF
pcs v${VERSION} — Proxy Control Service

  pcs             интерактивное меню
  pcs doctor      диагностика хоста и активной ВМ
  pcs status      proxyveth status на активной ВМ
  pcs fix-dns     починить DNS на активной ВМ
  pcs update      обновиться с GitHub

Состояние: ${PCS_DIR}/vm_<id>.conf   Логи: ${PCS_LOG_DIR}/
EOF
        exit 0 ;;
    doctor)  do_doctor;      exit $? ;;
    status)  do_pv_status;   exit $? ;;
    fix-dns) do_fix_dns;     exit $? ;;
    update)  do_selfupdate;  exit $? ;;
esac

load_state
self_install
main_menu
