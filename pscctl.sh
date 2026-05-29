#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  pscctl — Proxy Control Service  v1.2
#  https://github.com/Tovarish666/ProxyVethMP
#
#  Запуск: bash <(curl -s https://raw.githubusercontent.com/Tovarish666/ProxyVethMP/main/pscctl.sh)
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

VERSION="1.2"
GITHUB_RAW="https://raw.githubusercontent.com/Tovarish666/ProxyVethMP/main"
PSC_URL="${GITHUB_RAW}/psc.py"
SELF_URL="${GITHUB_RAW}/pscctl.sh"

UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_SHA256_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
UBUNTU_IMG_PATH="/var/lib/vz/template/iso/ubuntu-24.04-noble.img"

PSC_DIR="/etc/psc"

# ── Цвета ───────────────────────────────────────────────────────
R="\033[0m"; G="\033[32m"; RD="\033[31m"; Y="\033[33m"
C="\033[36m"; B="\033[1m"; D="\033[2m"

ok()   { echo -e "  ${G}✓${R} $*"; }
fail() { echo -e "\n  ${RD}✗ ОШИБКА:${R} $*\n" >&2; exit 1; }
warn() { echo -e "  ${Y}⚠${R} $*"; }
step() { echo -e "  ${D}→${R} $*"; }
hdr()  { echo -e "\n${B}══════════════════════════════════════════\n  $*\n══════════════════════════════════════════${R}"; }

# ── Ввод ─────────────────────────────────────────────────────────
prompt() {
    local label="$1" default="${2:-}" varname="$3" reply=""
    if [[ -n "$default" ]]; then
        echo -ne "  ${C}?${R} ${label} ${D}[${default}]${R}: "
    else
        echo -ne "  ${C}?${R} ${label}: "
    fi
    read -r reply </dev/tty || true
    if [[ -n "$reply" ]]; then
        printf -v "$varname" '%s' "$reply"
    else
        printf -v "$varname" '%s' "$default"
    fi
}
prompt_pass() {
    local label="$1" varname="$2" reply=""
    echo -ne "  ${C}?${R} ${label}: "
    read -rs reply </dev/tty || true; echo ""
    printf -v "$varname" '%s' "$reply"
}
prompt_choice() {
    echo -ne "  ${C}»${R} Выбор: "
    CHOICE=""
    read -r CHOICE </dev/tty || true
    CHOICE="${CHOICE//[[:space:]]/}"
}

# ── Spinner ──────────────────────────────────────────────────────
_spin_pid=""
spinner_start() {
    local msg="$1"
    ( local f=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
      while true; do
          echo -ne "  ${C}${f[$i]}${R} ${msg}\r"
          i=$(( (i+1) % 10 )); sleep 0.1
      done ) &
    _spin_pid=$!
}
spinner_stop() {
    [[ -n "$_spin_pid" ]] && kill "$_spin_pid" 2>/dev/null; _spin_pid=""
    echo -ne "\033[2K\r"
}

# ══════════════════════════════════════════════════════════════════
#  MULTI-VM STATE
#  /etc/psc/vm_106.conf  — конфиг конкретной VM
#  /etc/psc/active       — ID активной VM
# ══════════════════════════════════════════════════════════════════
VM_ID="" VM_NAME="psc" VM_IP="" VM_BRIDGE="vmbr0" VM_PASSWORD=""

load_state() {
    VM_ID="" VM_NAME="psc" VM_IP="" VM_BRIDGE="vmbr0" VM_PASSWORD=""
    mkdir -p "$PSC_DIR"
    local active_id=""
    [[ -f "${PSC_DIR}/active" ]] && active_id=$(cat "${PSC_DIR}/active")
    [[ -n "$active_id" && -f "${PSC_DIR}/vm_${active_id}.conf" ]] && source "${PSC_DIR}/vm_${active_id}.conf" || true
}

save_state() {
    mkdir -p "$PSC_DIR"
    [[ -z "${VM_ID:-}" ]] && return
    cat > "${PSC_DIR}/vm_${VM_ID}.conf" <<EOF
VM_ID=${VM_ID}
VM_NAME=${VM_NAME:-psc}
VM_IP=${VM_IP:-}
VM_BRIDGE=${VM_BRIDGE:-vmbr0}
VM_PASSWORD=${VM_PASSWORD:-}
EOF
    echo "$VM_ID" > "${PSC_DIR}/active"
}

list_vms() {
    local -A known=()
    for f in "${PSC_DIR}"/vm_*.conf; do
        [[ -f "$f" ]] || continue
        local id name ip status
        unset VM_ID VM_NAME VM_IP; source "$f" 2>/dev/null || continue
        id="${VM_ID:-}"; name="${VM_NAME:-?}"; ip="${VM_IP:- —  }"
        [[ -z "$id" ]] && continue
        status=$(qm status "$id" 2>/dev/null | awk '{print $2}' || echo "unknown")
        local dot; [[ "$status" == "running" ]] && dot="${G}●${R}" || dot="${D}●${R}"
        printf "  %-6s %-20s %-18s $(eval echo -e \"${dot}\") %s\n" "$id" "$name" "$ip" "$status"
        known[$id]=1
    done
    while IFS= read -r line; do
        local id; id=$(echo "$line" | awk '{print $1}')
        [[ -z "$id" || -n "${known[$id]:-}" ]] && continue
        local name; name=$(echo "$line" | awk '{print $2}')
        local status; status=$(echo "$line" | awk '{print $3}')
        local dot; [[ "$status" == "running" ]] && dot="${G}●${R}" || dot="${D}●${R}"
        printf "  %-6s %-20s %-18s $(eval echo -e \"${dot}\") %s\n" "$id" "$name" "—" "$status"
    done < <(qm list 2>/dev/null | tail -n +2)
}

select_vm() {
    echo -e "\n${B}  Выбор VM${R}"
    echo -e "  ${D}──────────────────────────────────────────${R}"
    echo -e "  ${D}ID     Имя                  IP                 Статус${R}"
    list_vms
    echo ""
    local cur="${VM_ID:-}"
    prompt "VM ID" "$cur" VM_ID
    [[ -z "${VM_ID:-}" ]] && { warn "VM не выбрана"; return 1; }
    if [[ -f "${PSC_DIR}/vm_${VM_ID}.conf" ]]; then
        source "${PSC_DIR}/vm_${VM_ID}.conf"
        ok "Активная VM: ${VM_ID} (${VM_NAME}) @ ${VM_IP:-?}"
    else
        VM_NAME="psc"; VM_IP=""; VM_BRIDGE="vmbr0"
        VM_NAME=$(qm config "$VM_ID" 2>/dev/null | awk '/^name:/{print $2}' || echo "psc")
        warn "Новая VM для PSC — конфиг будет создан после установки"
    fi
    echo "$VM_ID" > "${PSC_DIR}/active"
}

# ── SSH ──────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"
vm_exec()      { ssh $SSH_OPTS root@"${VM_IP}" "$@"; }
vm_run()       { ssh $SSH_OPTS root@"${VM_IP}" bash -s <<< "$1"; }
vm_reachable() { [[ -n "${VM_IP:-}" ]] && vm_exec true 2>/dev/null; }
vm_running()   { [[ -n "${VM_ID:-}" ]] && qm status "$VM_ID" 2>/dev/null | grep -q "running"; }

vm_wait_apt() {
    step "Проверяем apt на VM..."
    vm_run "
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
elapsed=0
while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock >/dev/null 2>&1; do
    echo '  apt занят, ждём...' >&2
    sleep 3; elapsed=\$((elapsed+3))
    [[ \$elapsed -ge 120 ]] && break
done
" 2>/dev/null || true
}

need_ip() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { warn "VM не выбрана"; select_vm || return 1; }
    if [[ -z "${VM_IP:-}" ]]; then
        prompt "IP VM" "" VM_IP
    fi
    [[ -n "${VM_IP:-}" ]] || fail "IP VM не задан"
}

fetch_vm_ip_terminal() {
    apt-get install -y -qq expect 2>/dev/null
    expect -f - 2>/dev/null <<EXPECT | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | head -1
log_user 1
set timeout 90
spawn qm terminal $VM_ID
sleep 3
send "\r"
expect "login:"    { send "root\r" }
expect "Password:" { send "${VM_PASSWORD}\r" }
expect "#"         { send "hostname -I\r" }
expect "#"         { send "\x1d" }
expect eof
EXPECT
}

# ── Dashboard ────────────────────────────────────────────────────
svc_dot() {
    case "$1" in
        active)          echo -e "${G}●${R}" ;;
        inactive|failed) echo -e "${RD}●${R}" ;;
        *)               echo -e "${D}●${R}" ;;
    esac
}

show_dashboard() {
    load_state
    local vm_status="нет VM" st_mp="—" st_psc="—" wan="—"
    local vm_dot="${D}●${R}"

    if [[ -n "${VM_ID:-}" ]]; then
        if vm_running 2>/dev/null; then
            vm_status="running"; vm_dot="${G}●${R}"
            if [[ -n "${VM_IP:-}" ]] && vm_reachable 2>/dev/null; then
                local _info
                _info=$(vm_exec "printf '%s\n%s\n%s\n' \
                    \"\$(systemctl is-active mproxy 2>/dev/null || echo inactive)\" \
                    \"\$(systemctl is-active psc 2>/dev/null || echo inactive)\" \
                    \"\$(curl -s --max-time 4 2ip.ru 2>/dev/null || echo '—')\"" 2>/dev/null || echo -e "—\n—\n—")
                st_mp=$(echo "$_info"  | sed -n '1p')
                st_psc=$(echo "$_info" | sed -n '2p')
                wan=$(echo "$_info"    | sed -n '3p')
            fi
        else
            vm_status="stopped"; vm_dot="${RD}●${R}"
        fi
    fi

    echo -e "\n  ${B}┌──────────────────────────────────────────────┐${R}"
    echo -e   "  ${B}│  pscctl v${VERSION}  —  Proxy Control Service        │${R}"
    echo -e   "  ${B}└──────────────────────────────────────────────┘${R}"
    if [[ -n "${VM_ID:-}" ]]; then
        printf  "  VM #%-5s ${B}%-18s${R}" "${VM_ID}" "${VM_NAME:-?}"
        echo -e "$(eval "echo -e \"${vm_dot}\"") ${vm_status}"
        printf  "  IP: %-22s WAN: %s\n" "${VM_IP:-—}" "$wan"
    else
        echo -e "  ${D}VM не выбрана — [v] Выбрать VM${R}"
    fi
    printf    "  mp.space:  "; echo -e "$(eval "echo -e \"$(svc_dot "$st_mp")\"") ${st_mp}"
    printf    "  PSC:       "; echo -e "$(eval "echo -e \"$(svc_dot "$st_psc")\"") ${st_psc}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════
#  UBUNTU IMAGE
# ══════════════════════════════════════════════════════════════════
ensure_ubuntu_image() {
    if [[ -f "$UBUNTU_IMG_PATH" ]]; then
        step "Проверяем SHA256 образа..."
        local expected actual
        expected=$(wget -qO- "$UBUNTU_SHA256_URL" | grep "noble-server-cloudimg-amd64.img$" | awk '{print $1}')
        actual=$(sha256sum "$UBUNTU_IMG_PATH" | awk '{print $1}')
        if [[ "$actual" == "$expected" ]]; then ok "Образ есть, SHA256 ОК"; return
        else warn "SHA256 не совпал — скачиваем заново"; rm -f "$UBUNTU_IMG_PATH"; fi
    fi
    local expected
    expected=$(wget -qO- "$UBUNTU_SHA256_URL" | grep "noble-server-cloudimg-amd64.img$" | awk '{print $1}')
    [[ -n "$expected" ]] || fail "Не удалось получить SHA256SUMS"
    step "Скачиваем Ubuntu 24.04 cloud image (~600MB)..."
    wget -q --show-progress -O "$UBUNTU_IMG_PATH" "$UBUNTU_IMG_URL"
    local actual; actual=$(sha256sum "$UBUNTU_IMG_PATH" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || { rm -f "$UBUNTU_IMG_PATH"; fail "SHA256 не совпал!"; }
    ok "Образ скачан и проверен"
}

# ══════════════════════════════════════════════════════════════════
#  INSTALL: VM
# ══════════════════════════════════════════════════════════════════
do_install_vm() {
    hdr "Установка VM"

    prompt "VM ID" "200" VM_ID
    if qm status "$VM_ID" &>/dev/null 2>&1; then
        warn "VM ${VM_ID} уже существует!"
        prompt "Удалить и пересоздать? (yes/no)" "no" _c
        [[ "${_c:-}" == "yes" ]] || { echo "Отменено"; return; }
        qm stop "$VM_ID" --skiplock 2>/dev/null || true; sleep 3
        qm destroy "$VM_ID" --destroy-unreferenced-disks 1 --purge 1
        ok "Старая VM удалена"
    fi

    while true; do
        prompt "Имя VM (буквы/цифры/дефис, напр. psc)" "psc" VM_NAME
        if [[ "$VM_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?$ ]]; then
            break
        fi
        warn "Недопустимое имя «${VM_NAME}» — только латинские буквы, цифры и дефис"
    done
    prompt "RAM, MB"  "8192"        VM_RAM
    prompt "CPU ядра" "8"           VM_CORES
    prompt "Диск, GB" "50"          VM_DISK

    echo ""
    step "Доступные хранилища:"
    pvesm status 2>/dev/null | awk 'NR>1{printf "    %-20s %s\n",$1,$2}' || true
    prompt "Хранилище" "local-lvm" VM_STORAGE

    step "Доступные мосты:"
    ip -o link show | awk -F': ' '/vmbr/{print "    "$2}' || true
    prompt "Сетевой мост" "vmbr0" VM_BRIDGE

    prompt_pass "Пароль root для VM" VM_PASSWORD
    [[ -n "${VM_PASSWORD:-}" ]] || fail "Пароль не может быть пустым"

    ensure_ubuntu_image

    hdr "Создание VM"
    [[ -f /root/.ssh/id_rsa ]] || { ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa -q; ok "SSH ключ создан"; }

    step "qm create..."
    qm create "$VM_ID" \
        --name    "$VM_NAME"  --memory "$VM_RAM"   --cores "$VM_CORES" \
        --cpu     host        --net0   "virtio,bridge=${VM_BRIDGE}" \
        --ostype  l26         --machine q35         --scsihw virtio-scsi-pci \
        --serial0 socket      --onboot 1 \
        || { warn "qm create завершился с ошибкой. Установка прервана."; return 1; }
    ok "VM создана (ID=${VM_ID})"

    step "Импорт диска..."
    qm importdisk "$VM_ID" "$UBUNTU_IMG_PATH" "$VM_STORAGE" --format qcow2
    local disk; disk=$(qm config "$VM_ID" | awk '/^unused0:/{print $2}')
    [[ -n "$disk" ]] || disk="${VM_STORAGE}:vm-${VM_ID}-disk-0"
    qm set "$VM_ID" --scsi0 "$disk" --boot order=scsi0
    qm resize "$VM_ID" scsi0 "${VM_DISK}G"
    ok "Диск готов (${VM_DISK}GB)"

    step "Cloud-init..."
    qm set "$VM_ID" \
        --ide2 "${VM_STORAGE}:cloudinit" --ciuser root \
        --cipassword "$VM_PASSWORD" --ipconfig0 ip=dhcp \
        --sshkeys /root/.ssh/id_rsa.pub
    ok "Cloud-init настроен"

    hdr "Запуск VM"
    qm start "$VM_ID"
    spinner_start "Ждём загрузки VM (45с)..."; sleep 45; spinner_stop

    step "Получаем IP через qm terminal..."
    VM_IP=$(fetch_vm_ip_terminal)
    if [[ -z "$VM_IP" ]]; then
        warn "Не удалось получить IP автоматически"
        prompt "IP VM (см. qm terminal ${VM_ID})" "" VM_IP
    fi
    [[ -n "$VM_IP" ]] || fail "IP VM не задан"
    ok "VM IP: ${VM_IP}"

    spinner_start "Ждём SSH..."
    local elapsed=0
    while ! vm_exec true 2>/dev/null; do
        sleep 5; elapsed=$((elapsed+5))
        [[ $elapsed -ge 120 ]] && { spinner_stop; fail "SSH недоступен на ${VM_IP}"; }
    done
    spinner_stop; ok "SSH доступен"

    hdr "Базовая настройка Ubuntu"
    vm_wait_apt
    vm_run "
export DEBIAN_FRONTEND=noninteractive
systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq curl wget mc net-tools
hostnamectl set-hostname ${VM_NAME}
grep -q '${VM_NAME}' /etc/hosts || echo '127.0.1.1 ${VM_NAME}' >> /etc/hosts
"
    ok "Ubuntu настроена"
    save_state
    echo -e "\n  ${G}VM готова!${R}  ID: ${VM_ID}  IP: ${VM_IP}"
}

# ══════════════════════════════════════════════════════════════════
#  INSTALL: PSC
# ══════════════════════════════════════════════════════════════════
do_install_psc() {
    hdr "Установка PSC"
    need_ip

    prompt "SHEET_CSV_URL (Enter = позже)" "" SHEET_CSV_URL; SHEET_CSV_URL=${SHEET_CSV_URL:-}

    step "Скачиваем psc.py на хост..."
    local _pyfile; _pyfile=$(mktemp /tmp/psc.XXXXXX.py)
    wget -q --timeout=30 -O "$_pyfile" "${PSC_URL}" \
        || { rm -f "$_pyfile"; fail "Не удалось скачать ${PSC_URL}"; }
    head -1 "$_pyfile" | grep -q '^#!' \
        || { rm -f "$_pyfile"; fail "Файл не является Python-скриптом (404 или пусто?)"; }

    step "Копируем psc.py на VM..."
    scp $SSH_OPTS "$_pyfile" root@"${VM_IP}":/usr/local/bin/psc.py \
        || { rm -f "$_pyfile"; fail "SCP не удался — проверь IP и SSH доступ"; }
    rm -f "$_pyfile"

    vm_exec "chmod +x /usr/local/bin/psc.py && ln -sf /usr/local/bin/psc.py /usr/local/bin/psc"
    ok "psc.py установлен"

    vm_run "mkdir -p /etc/psc/logs"
    if [[ -n "${SHEET_CSV_URL:-}" ]]; then
        vm_exec "echo 'SHEET_CSV_URL=${SHEET_CSV_URL}' > /etc/psc/env"
        ok "SHEET_CSV_URL сохранён"
    else
        vm_exec "touch /etc/psc/env"
    fi

    vm_wait_apt
    step "Установка зависимостей (tun2socks)..."
    vm_exec "psc install"
    ok "Зависимости установлены"

    if [[ -n "${SHEET_CSV_URL:-}" ]]; then
        step "Sync + Up all..."
        vm_exec "SHEET_CSV_URL='${SHEET_CSV_URL}' psc sync && psc up all"
        ok "NS подняты"
    fi

    step "Настройка systemd..."
    vm_exec bash << 'REMOTE'
cat > /etc/systemd/system/psc.service << 'EOF'
[Unit]
Description=PSC — Proxy Control Service
After=network-online.target mproxy.service nodejs-server.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-/etc/psc/env
ExecStart=/usr/bin/python3 /usr/local/bin/psc.py init
ExecStart=/usr/bin/python3 /usr/local/bin/psc.py up all
ExecStop=/usr/bin/python3 /usr/local/bin/psc.py down all
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/psc-watchdog.service << 'EOF'
[Unit]
Description=PSC Watchdog
After=psc.service
Requires=psc.service

[Service]
Type=simple
EnvironmentFile=-/etc/psc/env
ExecStart=/usr/bin/python3 /usr/local/bin/psc.py watchdog-loop
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/psc-autosync.service << 'EOF'
[Unit]
Description=PSC Autosync

[Service]
Type=oneshot
EnvironmentFile=-/etc/psc/env
ExecStart=/usr/bin/python3 /usr/local/bin/psc.py autosync
EOF

cat > /etc/systemd/system/psc-autosync.timer << 'EOF'
[Unit]
Description=PSC Autosync every 5 min

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable psc.service psc-watchdog.service psc-autosync.timer
systemctl start  psc-watchdog.service psc-autosync.timer
REMOTE
    ok "Systemd сервисы настроены"
    save_state
    ok "PSC установлен"
}

# ══════════════════════════════════════════════════════════════════
#  INSTALL: mp.space
# ══════════════════════════════════════════════════════════════════
do_install_mp() {
    hdr "Установка mobileproxy.space"
    need_ip

    echo -e "\n  ${Y}auth.mp${R} — скачать на сайте mp.space:"
    echo -e "  Мой прокси-бизнес → Сервера → иконка ↓ у нужного сервера"
    echo -e "  Формат: {\"auth\":\"KEY:KEY\",\"port\":1800}\n"
    prompt "Содержимое auth.mp" "" AUTH_MP_CONTENT
    [[ -n "${AUTH_MP_CONTENT:-}" ]] || fail "auth.mp не может быть пустым"

    step "install.sh..."
    # install.sh может завершиться обрывом сессии — не валим set -e
    vm_exec "wget -O - https://mobileproxy.space/downloads/sp/install.sh | bash" || true
    ok "install.sh завершён"

    # ── Пишем СВОЙ токен сразу после install.sh, пока SSH-сессия жива. ──
    # install.sh генерит собственный auth.mp (proxy_xxx) — его нужно перебить.
    # Раньше запись стояла ПОСЛЕ setup-modem-management.sh, который ребутает
    # VM и рвёт сессию → set -e убивал скрипт до записи токена (см. историю бага).
    step "Записываем auth.mp..."
    printf '%s' "$AUTH_MP_CONTENT" | vm_exec "cat > /home/nodejs/work/auth.mp"
    vm_exec "systemctl restart mproxy nodejs-server 2>/dev/null || true"
    ok "auth.mp записан + сервисы перезапущены"

    step "setup-modem-management.sh..."
    # ставит GRUB/initramfs и ребутает VM → обрыв пайпа ('Cannot write to -') это норма
    vm_exec "wget -O - https://mobileproxy.space/downloads/sp/setup-modem-management.sh | bash" || true
    ok "setup-modem-management.sh завершён"

    step "Перезагрузка VM..."
    vm_exec "reboot" || true; sleep 20
    spinner_start "Ждём SSH после ребута..."
    local elapsed=0
    while ! vm_exec true 2>/dev/null; do
        sleep 5; elapsed=$((elapsed+5))
        [[ $elapsed -ge 120 ]] && { spinner_stop; fail "VM не поднялась после ребута"; }
    done
    spinner_stop; ok "VM перезагружена"

    # Контроль: токен должен быть НАШ, а не сгенерённый install.sh (proxy_xxx)
    step "Проверка auth.mp..."
    vm_exec "cat /home/nodejs/work/auth.mp" || true

    vm_exec "systemctl is-active mproxy nodejs-server 2>/dev/null || true" | while read -r s; do
        [[ "$s" == "active" ]] && ok "Сервис: $s" || warn "Сервис: $s"
    done
    save_state; ok "mp.space установлен"
}

# ══════════════════════════════════════════════════════════════════
#  CONFIG
# ══════════════════════════════════════════════════════════════════
do_set_auth() {
    need_ip
    echo -e "\n  Скачать: Мой прокси-бизнес → Сервера → иконка ↓"
    prompt "Новое содержимое auth.mp" "" AUTH_MP_CONTENT
    [[ -n "${AUTH_MP_CONTENT:-}" ]] || fail "Пусто"
    printf '%s' "$AUTH_MP_CONTENT" | vm_exec "cat > /home/nodejs/work/auth.mp"
    vm_exec "systemctl restart mproxy nodejs-server 2>/dev/null || true"
    ok "auth.mp обновлён, сервисы перезапущены"
}

do_set_sheet() {
    need_ip
    prompt "SHEET_CSV_URL" "" URL
    [[ -n "${URL:-}" ]] || fail "Пусто"
    local ESCAPED_URL; ESCAPED_URL=$(printf '%s' "$URL" | sed 's/[&\]/\\&/g')
    vm_exec "grep -q '^SHEET_CSV_URL=' /etc/psc/env \
        && sed -i 's|^SHEET_CSV_URL=.*|SHEET_CSV_URL=${ESCAPED_URL}|' /etc/psc/env \
        || echo 'SHEET_CSV_URL=${URL}' >> /etc/psc/env"
    ok "URL сохранён"
    prompt "Запустить sync + up all? (yes/no)" "yes" _c
    [[ "${_c:-}" == "yes" ]] && { vm_exec "psc sync && psc up all" && ok "Sync + Up выполнены" || warn "Ошибка sync"; }
}

do_change_vm_params() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { prompt "VM ID" "" VM_ID; }
    echo -e "\n  Текущие параметры VM ${VM_ID}:"
    qm config "$VM_ID" | grep -E "^(memory|cores|name):" || true; echo ""
    prompt "Новый RAM, MB (Enter = без изменений)" "" NEW_RAM
    prompt "Новые CPU ядра (Enter = без изменений)" "" NEW_CORES
    [[ -n "${NEW_RAM:-}"   ]] && qm set "$VM_ID" --memory "$NEW_RAM"   && ok "RAM = ${NEW_RAM} MB"
    [[ -n "${NEW_CORES:-}" ]] && qm set "$VM_ID" --cores  "$NEW_CORES" && ok "CPU = ${NEW_CORES} ядра"
    warn "Изменения вступят в силу после перезапуска VM"
}

do_change_password() {
    need_ip
    prompt_pass "Новый root пароль" NEW_PASS
    [[ -n "${NEW_PASS:-}" ]] || fail "Пусто"
    vm_exec "echo 'root:${NEW_PASS}' | chpasswd"
    load_state
    [[ -n "${VM_ID:-}" ]] && qm set "$VM_ID" --cipassword "$NEW_PASS" 2>/dev/null || true
    VM_PASSWORD="$NEW_PASS"
    save_state
    ok "Пароль изменён"
}

do_set_ssh() {
    need_ip
    echo -e "\n  Текущие SSH настройки:"
    vm_exec "sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication)'" || true; echo ""
    prompt "Новый SSH порт (Enter = пропустить)" "" NEW_PORT
    prompt "PasswordAuthentication yes/no (Enter = пропустить)" "" NEW_PA
    [[ -n "${NEW_PORT:-}" ]] && vm_exec "sed -i 's/^#*Port .*/Port ${NEW_PORT}/' /etc/ssh/sshd_config"
    [[ -n "${NEW_PA:-}"   ]] && vm_exec "printf 'PasswordAuthentication ${NEW_PA}\nPermitRootLogin yes\n' > /etc/ssh/sshd_config.d/99-allow-password.conf"
    vm_exec "systemctl restart ssh"
    ok "SSH обновлён"
    [[ -n "${NEW_PORT:-}" ]] && warn "Порт изменён — обнови SSH_OPTS в pscctl!"
}

# ══════════════════════════════════════════════════════════════════
#  MANAGE
# ══════════════════════════════════════════════════════════════════
do_psc_status()  { need_ip; vm_exec "psc status"  || warn "psc не отвечает"; }
do_psc_check()   { need_ip; vm_exec "psc check"   || warn "psc не отвечает"; }
do_psc_sync()    { need_ip; vm_exec "psc sync && psc up all" && ok "Sync + Up выполнены" || warn "Ошибка sync"; }

do_psc_restart() {
    need_ip
    prompt "Номер NS или all" "all" TARGET
    vm_exec "psc restart ${TARGET}" && ok "Перезапущено: $TARGET" || warn "Ошибка restart"
}
do_psc_logs() {
    need_ip; echo -e "\n  ${D}Ctrl+C для выхода${R}"
    vm_exec "tail -f /etc/psc/logs/watchdog.log" || true
}

do_reboot_vm() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { prompt "VM ID" "" VM_ID; }
    qm reboot "$VM_ID" 2>/dev/null || { need_ip; vm_exec "reboot" || true; }
    ok "VM перезагружается..."
}

do_show_summary() {
    need_ip; load_state
    local wan; wan=$(vm_exec "curl -s --max-time 5 2ip.ru" 2>/dev/null || echo "—")
    local pass_display="${VM_PASSWORD:-${RD}(не сохранён — смени через [2]→[4])${R}}"
    echo -e "\n  ${G}Сводка для ЛК mobileproxy.space:${R}"
    echo -e "  ${B}════════════════════════════════════════${R}"
    echo -e "  Статический IP : ${wan}"
    echo -e "  LocalIP        : ${VM_IP}"
    echo -e "  Root login     : root"
    echo -e "  Root password  : ${pass_display}"
    echo -e "  OS             : Unix"
    echo -e "  ${B}════════════════════════════════════════${R}"
    echo -e "  Мой прокси-бизнес → Сервера → ✏ Редактировать\n"
}

do_destroy_vm() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { prompt "VM ID" "" VM_ID; }
    warn "ЭТО УДАЛИТ VM ${VM_ID} БЕЗВОЗВРАТНО!"
    prompt "Введи DELETE для подтверждения" "" _c
    [[ "${_c:-}" == "DELETE" ]] || { echo "Отменено"; return; }
    qm stop "$VM_ID" --skiplock 2>/dev/null || true; sleep 3
    qm destroy "$VM_ID" --destroy-unreferenced-disks 1 --purge 1
    rm -f "${PSC_DIR}/vm_${VM_ID}.conf"
    local cur_active; cur_active=$(cat "${PSC_DIR}/active" 2>/dev/null || echo "")
    [[ "$cur_active" == "$VM_ID" ]] && rm -f "${PSC_DIR}/active"
    ok "VM удалена"
}

do_selfupdate() {
    step "Скачиваем последнюю версию..."
    local tmp; tmp=$(mktemp)
    wget -q -O "$tmp" "$SELF_URL" || fail "Не удалось скачать pscctl"
    local new_ver; new_ver=$(grep '^VERSION=' "$tmp" | cut -d'"' -f2)
    if [[ "$new_ver" == "$VERSION" ]]; then
        rm -f "$tmp"; ok "Уже актуальная версия (v${VERSION})"
    else
        mv "$tmp" /usr/local/bin/pscctl && chmod +x /usr/local/bin/pscctl
        ok "Обновлено: v${VERSION} → v${new_ver}"
        exec /usr/local/bin/pscctl
    fi
}

# ══════════════════════════════════════════════════════════════════
#  SELF-INSTALL
# ══════════════════════════════════════════════════════════════════
self_install_prompt() {
    local target="/usr/local/bin/pscctl"
    [[ -f "$target" ]] && return
    echo ""
    prompt "Установить pscctl как команду /usr/local/bin/pscctl? (yes/no)" "yes" _c
    [[ "${_c:-}" == "yes" ]] || return
    wget -q -O "$target" "$SELF_URL" || fail "Не удалось скачать"
    chmod +x "$target"
    ok "Готово — теперь просто: pscctl"
}

# ══════════════════════════════════════════════════════════════════
#  МЕНЮ
# ══════════════════════════════════════════════════════════════════
menu_install() {
    while true; do
        echo -e "\n${B}  Установка${R}  ${D}(активная VM: ${VM_ID:-не выбрана})${R}"
        echo -e "  ${D}──────────────────────────────────────────${R}"
        echo "  [1] Только VM"
        echo "  [2] Только Софт mp.space"
        echo "  [3] Только PSC"
        echo "  [4] VM + PSC"
        echo "  [5] VM + Софт mp.space"
        echo "  [6] PSC + Софт mp.space"
        echo "  [7] Полный стек  (VM → PSC → mp.space)"
        echo "  [0] ← Назад"
        echo ""
        prompt_choice
        case ${CHOICE:-} in
            1) do_install_vm ;;
            2) do_install_mp ;;
            3) do_install_psc ;;
            4) do_install_vm; do_install_psc ;;
            5) do_install_vm; do_install_mp ;;
            6) do_install_psc; do_install_mp ;;
            7) do_install_vm; do_install_psc; do_install_mp ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

menu_config() {
    while true; do
        echo -e "\n${B}  Настройка${R}  ${D}(VM: ${VM_ID:-?} @ ${VM_IP:-?})${R}"
        echo -e "  ${D}──────────────────────────────────────────${R}"
        echo "  [1] Ключ аутентификации mp.space (auth.mp)"
        echo "  [2] URL Google Sheets таблицы"
        echo "  [3] Параметры VM  (RAM / CPU)"
        echo "  [4] Root пароль VM"
        echo "  [5] SSH настройки"
        echo "  [0] ← Назад"
        echo ""
        prompt_choice
        case ${CHOICE:-} in
            1) do_set_auth ;;
            2) do_set_sheet ;;
            3) do_change_vm_params ;;
            4) do_change_password ;;
            5) do_set_ssh ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

menu_manage() {
    while true; do
        echo -e "\n${B}  Управление${R}  ${D}(VM: ${VM_ID:-?} @ ${VM_IP:-?})${R}"
        echo -e "  ${D}──────────────────────────────────────────${R}"
        echo "  [1] Dashboard"
        echo "  [2] psc status   (NS + WAN IP)"
        echo "  [3] psc check    (скорость + ping + 2ip)"
        echo "  [4] psc sync + up all"
        echo "  [5] psc restart  [N|all]"
        echo "  [6] Логи watchdog"
        echo "  [7] Сводка для ЛК mp.space"
        echo "  [8] Ребут VM"
        echo "  [d] Удалить VM"
        echo "  [u] Обновить pscctl"
        echo "  [0] ← Назад"
        echo ""
        prompt_choice
        case ${CHOICE:-} in
            1) show_dashboard ;;
            2) do_psc_status ;;
            3) do_psc_check ;;
            4) do_psc_sync ;;
            5) do_psc_restart ;;
            6) do_psc_logs ;;
            7) do_show_summary ;;
            8) do_reboot_vm ;;
            d|D) do_destroy_vm ;;
            u|U) do_selfupdate ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

main_menu() {
    while true; do
        show_dashboard
        echo -e "  ${B}[1]${R} Установка  ${B}[2]${R} Настройка  ${B}[3]${R} Управление  ${B}[v]${R} Сменить VM  ${B}[q]${R} Выход"
        echo ""
        prompt_choice
        case ${CHOICE:-} in
            1) menu_install ;;
            2) menu_config ;;
            3) menu_manage ;;
            v|V) select_vm; save_state 2>/dev/null || true ;;
            q|Q|0) echo ""; exit 0 ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════
[[ $EUID -eq 0 ]]             || fail "Запускай от root на хосте Proxmox"
command -v qm    &>/dev/null  || fail "qm не найден — это не хост Proxmox"
command -v pvesm &>/dev/null  || fail "pvesm не найден"

mkdir -p "$PSC_DIR"
load_state
self_install_prompt
main_menu
