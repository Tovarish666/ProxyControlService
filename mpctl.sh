#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  mpctl — Mobile Proxy Control  v1.0
#  https://github.com/Tovarish666/ProxyVethMP
#
#  Запуск: bash <(curl -s https://raw.githubusercontent.com/Tovarish666/ProxyVethMP/main/mpctl.sh)
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

VERSION="1.0"
GITHUB_RAW="https://raw.githubusercontent.com/Tovarish666/ProxyVethMP/main"
PROXYVETHMP_URL="${GITHUB_RAW}/proxyveth_mp.py"
SELF_URL="${GITHUB_RAW}/mpctl.sh"

# Ubuntu 24.04 — через SHA256SUMS текущей версии (без blind-latest)
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_SHA256_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
UBUNTU_IMG_PATH="/var/lib/vz/template/iso/ubuntu-24.04-noble.img"

STATE_FILE="/etc/mpctl.conf"

# ── Цвета ───────────────────────────────────────────────────────
R="\033[0m"; G="\033[32m"; RD="\033[31m"; Y="\033[33m"
C="\033[36m"; B="\033[1m"; D="\033[2m"

ok()   { echo -e "  ${G}✓${R} $*"; }
fail() { echo -e "\n  ${RD}✗ ОШИБКА:${R} $*\n" >&2; exit 1; }
warn() { echo -e "  ${Y}⚠${R} $*"; }
step() { echo -e "  ${D}→${R} $*"; }
ask()  { echo -ne "  ${C}?${R} $* "; }
hdr()  { echo -e "\n${B}══════════════════════════════════════════\n  $*\n══════════════════════════════════════════${R}"; }

# read всегда с /dev/tty
_rd()  { read -r  "$@" </dev/tty; }
_rds() { read -rs "$@" </dev/tty; }

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

# ── State ────────────────────────────────────────────────────────
load_state() {
    VM_ID="" VM_NAME="proxyvethmp" VM_IP="" VM_BRIDGE="vmbr0"
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" || true
}
save_state() {
    cat > "$STATE_FILE" <<EOF
VM_ID=${VM_ID:-}
VM_NAME=${VM_NAME:-proxyvethmp}
VM_IP=${VM_IP:-}
VM_BRIDGE=${VM_BRIDGE:-vmbr0}
EOF
}

# ── SSH ──────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"
vm_exec()      { ssh $SSH_OPTS root@"${VM_IP}" "$@"; }
vm_run()       { ssh $SSH_OPTS root@"${VM_IP}" bash -s <<< "$1"; }
vm_reachable() { [[ -n "${VM_IP:-}" ]] && vm_exec true 2>/dev/null; }
vm_running()   { [[ -n "${VM_ID:-}" ]] && qm status "$VM_ID" 2>/dev/null | grep -q "running"; }

# ── Получить IP через qm terminal (Ubuntu пишет IP в MOTD) ───────
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
    local vm_status="stopped" st_mp="—" st_pvmp="—" wan="—"
    local vm_dot="${RD}●${R}"

    if [[ -n "${VM_ID:-}" ]] && vm_running 2>/dev/null; then
        vm_status="running"; vm_dot="${G}●${R}"
        if [[ -n "${VM_IP:-}" ]] && vm_reachable 2>/dev/null; then
            st_mp=$(vm_exec   "systemctl is-active mproxy        2>/dev/null" 2>/dev/null || echo "—")
            st_pvmp=$(vm_exec "systemctl is-active proxyvethmp   2>/dev/null" 2>/dev/null || echo "—")
            wan=$(vm_exec "curl -s --max-time 4 2ip.ru" 2>/dev/null || echo "—")
        fi
    fi

    echo -e "\n  ${B}┌──────────────────────────────────────────────┐${R}"
    echo -e   "  ${B}│  mpctl v${VERSION}  —  Mobile Proxy Control         │${R}"
    echo -e   "  ${B}└──────────────────────────────────────────────┘${R}"
    printf    "  VM #%-5s %-18s" "${VM_ID:-—}" "${VM_NAME:-}"
    echo -e   "$(eval "echo -e \"${vm_dot}\"") ${vm_status}"
    printf    "  IP: %-22s WAN: %s\n" "${VM_IP:-—}" "$wan"
    printf    "  mp.space:    "; echo -e "$(eval "echo -e \"$(svc_dot "$st_mp")\"") ${st_mp}"
    printf    "  ProxyVethMP: "; echo -e "$(eval "echo -e \"$(svc_dot "$st_pvmp")\"") ${st_pvmp}"
    echo ""
}

# ── Проверить что VM_IP задан ─────────────────────────────────────
need_ip() {
    load_state
    if [[ -z "${VM_IP:-}" ]]; then
        if [[ -n "${VM_ID:-}" ]] && vm_running 2>/dev/null; then
            VM_IP=$(fetch_vm_ip_arp "$VM_ID" 2>/dev/null || true)
            [[ -n "$VM_IP" ]] && { save_state; return; }
        fi
        ask "IP VM:"; _rd VM_IP
    fi
    [[ -n "${VM_IP:-}" ]] || fail "IP VM не задан"
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
        if [[ "$actual" == "$expected" ]]; then
            ok "Образ есть, SHA256 ОК"
            return
        else
            warn "SHA256 не совпал — скачиваем заново"
            rm -f "$UBUNTU_IMG_PATH"
        fi
    fi

    step "Получаем ожидаемый SHA256..."
    local expected
    expected=$(wget -qO- "$UBUNTU_SHA256_URL" | grep "noble-server-cloudimg-amd64.img$" | awk '{print $1}')
    [[ -n "$expected" ]] || fail "Не удалось получить SHA256SUMS"

    step "Скачиваем Ubuntu 24.04 cloud image (~600MB)..."
    wget -q --show-progress -O "$UBUNTU_IMG_PATH" "$UBUNTU_IMG_URL"

    local actual; actual=$(sha256sum "$UBUNTU_IMG_PATH" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || { rm -f "$UBUNTU_IMG_PATH"; fail "SHA256 не совпал после скачивания!"; }
    ok "Образ скачан и проверен"
}

# ══════════════════════════════════════════════════════════════════
#  INSTALL: VM
# ══════════════════════════════════════════════════════════════════
do_install_vm() {
    hdr "Установка VM"

    ask "VM ID [200]:"; _rd VM_ID; VM_ID=${VM_ID:-200}
    if qm status "$VM_ID" &>/dev/null 2>&1; then
        warn "VM ${VM_ID} уже существует!"
        ask "Удалить и пересоздать? (yes/no):"; _rd _c
        [[ "${_c:-}" == "yes" ]] || { echo "Отменено"; return; }
        qm stop "$VM_ID" --skiplock 2>/dev/null || true; sleep 3
        qm destroy "$VM_ID" --destroy-unreferenced-disks 1 --purge 1
        ok "Старая VM удалена"
    fi

    ask "Имя VM [proxyvethmp]:"; _rd VM_NAME;   VM_NAME=${VM_NAME:-proxyvethmp}
    ask "RAM в MB [8192]:";      _rd VM_RAM;    VM_RAM=${VM_RAM:-8192}
    ask "CPU ядра [8]:";         _rd VM_CORES;  VM_CORES=${VM_CORES:-8}
    ask "Диск в GB [50]:";       _rd VM_DISK;   VM_DISK=${VM_DISK:-50}

    echo ""
    step "Доступные хранилища:"
    pvesm status 2>/dev/null | awk 'NR>1{printf "    %-20s %s\n",$1,$2}' || true
    ask "Хранилище [local-lvm]:"; _rd VM_STORAGE; VM_STORAGE=${VM_STORAGE:-local-lvm}

    step "Доступные мосты:"
    ip -o link show | awk -F': ' '/vmbr/{print "    "$2}' || true
    ask "Сетевой мост [vmbr0]:";  _rd VM_BRIDGE;  VM_BRIDGE=${VM_BRIDGE:-vmbr0}

    ask "Пароль root для VM:"; _rds VM_PASSWORD; echo ""
    [[ -n "${VM_PASSWORD:-}" ]] || fail "Пароль не может быть пустым"

    ensure_ubuntu_image

    hdr "Создание VM"
    [[ -f /root/.ssh/id_rsa ]] || {
        ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa -q
        ok "SSH ключ создан"
    }

    step "qm create..."
    qm create "$VM_ID" \
        --name      "$VM_NAME"   --memory  "$VM_RAM"   --cores "$VM_CORES" \
        --cpu       host         --net0    "virtio,bridge=${VM_BRIDGE}" \
        --ostype    l26          --machine q35          --scsihw virtio-scsi-pci \
        --serial0   socket       --onboot  1
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
        --ide2       "${VM_STORAGE}:cloudinit" \
        --ciuser     root \
        --cipassword "$VM_PASSWORD" \
        --ipconfig0  ip=dhcp \
        --sshkeys    /root/.ssh/id_rsa.pub
    ok "Cloud-init настроен"

    hdr "Запуск VM"
    qm start "$VM_ID"

    spinner_start "Ждём загрузки VM (45с)..."; sleep 45; spinner_stop

    step "Получаем IP через qm terminal..."
    VM_IP=$(fetch_vm_ip_terminal)
    if [[ -z "$VM_IP" ]]; then
        warn "Не удалось получить IP автоматически"
        ask "Введи IP VM вручную (см. qm terminal ${VM_ID}):"; _rd VM_IP
    fi
    [[ -n "$VM_IP" ]] || fail "IP VM не задан"
    ok "VM IP: ${VM_IP}"

    # SSH работает по ключу из cloud-init --sshkeys, фиксить конфиг не нужно
    spinner_start "Ждём SSH..."
    elapsed=0
    while ! vm_exec true 2>/dev/null; do
        sleep 5; elapsed=$((elapsed+5))
        [[ $elapsed -ge 120 ]] && { spinner_stop; fail "SSH недоступен на ${VM_IP}"; }
    done
    spinner_stop; ok "SSH доступен"

    hdr "Базовая настройка Ubuntu"
    vm_run "
export DEBIAN_FRONTEND=noninteractive
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
#  INSTALL: mp.space
# ══════════════════════════════════════════════════════════════════
do_install_mp() {
    hdr "Установка mobileproxy.space"
    need_ip

    echo -e "\n  ${Y}auth.mp${R} — скачать на сайте mp.space:"
    echo -e "  Мой прокси-бизнес → Сервера → иконка ↓ у нужного сервера"
    echo -e "  Формат: {\"auth\":\"KEY:KEY\",\"port\":1800}\n"
    ask "Содержимое auth.mp:"; _rd AUTH_MP_CONTENT
    [[ -n "${AUTH_MP_CONTENT:-}" ]] || fail "auth.mp не может быть пустым"

    step "install.sh..."
    vm_exec "wget -O - https://mobileproxy.space/downloads/sp/install.sh | bash"
    ok "install.sh завершён"

    step "setup-modem-management.sh..."
    vm_exec "wget -O - https://mobileproxy.space/downloads/sp/setup-modem-management.sh | bash"
    ok "setup-modem-management.sh завершён"

    # printf вместо echo — безопасно для спецсимволов в ключе
    step "Записываем auth.mp..."
    printf '%s' "$AUTH_MP_CONTENT" | vm_exec "cat > /home/nodejs/work/auth.mp"
    ok "auth.mp записан"

    step "Перезагрузка VM..."
    vm_exec "reboot" || true
    sleep 20
    spinner_start "Ждём SSH после ребута..."
    local elapsed=0
    while ! vm_exec true 2>/dev/null; do
        sleep 5; elapsed=$((elapsed+5))
        [[ $elapsed -ge 120 ]] && { spinner_stop; fail "VM не поднялась после ребута"; }
    done
    spinner_stop; ok "VM перезагружена"

    vm_exec "systemctl is-active mproxy nodejs-server 2>/dev/null || true" | while read -r s; do
        [[ "$s" == "active" ]] && ok "Сервис: $s" || warn "Сервис: $s"
    done

    save_state
    ok "mp.space установлен"
}

# ══════════════════════════════════════════════════════════════════
#  INSTALL: ProxyVethMP
# ══════════════════════════════════════════════════════════════════
do_install_proxyvethmp() {
    hdr "Установка ProxyVethMP"
    need_ip

    ask "SHEET_CSV_URL (Enter = настроить позже):"; _rd SHEET_CSV_URL; SHEET_CSV_URL=${SHEET_CSV_URL:-}

    step "Скачиваем proxyveth_mp.py..."
    vm_run "
wget -q -O /usr/local/bin/proxyveth_mp.py '${PROXYVETHMP_URL}'
chmod +x /usr/local/bin/proxyveth_mp.py
ln -sf /usr/local/bin/proxyveth_mp.py /usr/local/bin/proxyveth
"
    ok "proxyveth_mp.py установлен"

    vm_run "mkdir -p /etc/proxyvethmp/logs"
    if [[ -n "${SHEET_CSV_URL:-}" ]]; then
        vm_exec "echo 'SHEET_CSV_URL=${SHEET_CSV_URL}' > /etc/proxyvethmp/env"
        ok "SHEET_CSV_URL сохранён"
    else
        vm_exec "touch /etc/proxyvethmp/env"
    fi

    step "Установка зависимостей (tun2socks)..."
    vm_exec "proxyveth install"
    ok "Зависимости установлены"

    if [[ -n "${SHEET_CSV_URL:-}" ]]; then
        step "Sync + Up all..."
        vm_exec "SHEET_CSV_URL='${SHEET_CSV_URL}' proxyveth sync && proxyveth up all"
        ok "NS подняты"
    fi

    step "Настройка systemd..."
    vm_exec bash << 'REMOTE'
cat > /etc/systemd/system/proxyvethmp.service << 'EOF'
[Unit]
Description=ProxyVethMP - SOCKS5 to veth for mp.space
After=network-online.target mproxy.service nodejs-server.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-/etc/proxyvethmp/env
ExecStart=/usr/bin/python3 /usr/local/bin/proxyveth_mp.py init
ExecStart=/usr/bin/python3 /usr/local/bin/proxyveth_mp.py up all
ExecStop=/usr/bin/python3 /usr/local/bin/proxyveth_mp.py down all
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/proxyvethmp-watchdog.service << 'EOF'
[Unit]
Description=ProxyVethMP Watchdog
After=proxyvethmp.service
Requires=proxyvethmp.service

[Service]
Type=simple
EnvironmentFile=-/etc/proxyvethmp/env
ExecStart=/usr/bin/python3 /usr/local/bin/proxyveth_mp.py watchdog-loop
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/proxyvethmp-autosync.service << 'EOF'
[Unit]
Description=ProxyVethMP Autosync

[Service]
Type=oneshot
EnvironmentFile=-/etc/proxyvethmp/env
ExecStart=/usr/bin/python3 /usr/local/bin/proxyveth_mp.py autosync
EOF

cat > /etc/systemd/system/proxyvethmp-autosync.timer << 'EOF'
[Unit]
Description=ProxyVethMP Autosync every 5 min

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable proxyvethmp.service proxyvethmp-watchdog.service proxyvethmp-autosync.timer
systemctl start  proxyvethmp-watchdog.service proxyvethmp-autosync.timer
REMOTE
    ok "Systemd сервисы настроены"
    save_state
    ok "ProxyVethMP установлен"
}

# ══════════════════════════════════════════════════════════════════
#  CONFIG
# ══════════════════════════════════════════════════════════════════
do_set_auth() {
    need_ip
    echo -e "\n  Скачать: Мой прокси-бизнес → Сервера → иконка ↓"
    ask "Новое содержимое auth.mp:"; _rd AUTH_MP_CONTENT
    [[ -n "${AUTH_MP_CONTENT:-}" ]] || fail "Пусто"
    printf '%s' "$AUTH_MP_CONTENT" | vm_exec "cat > /home/nodejs/work/auth.mp"
    vm_exec "systemctl restart mproxy nodejs-server 2>/dev/null || true"
    ok "auth.mp обновлён, сервисы перезапущены"
}

do_set_sheet() {
    need_ip
    ask "SHEET_CSV_URL:"; _rd URL
    [[ -n "${URL:-}" ]] || fail "Пусто"
    vm_exec "grep -q '^SHEET_CSV_URL=' /etc/proxyvethmp/env \
        && sed -i 's|^SHEET_CSV_URL=.*|SHEET_CSV_URL=${URL}|' /etc/proxyvethmp/env \
        || echo 'SHEET_CSV_URL=${URL}' >> /etc/proxyvethmp/env"
    ok "URL сохранён"
    ask "Запустить sync + up all? (yes/no):"; _rd _c
    [[ "${_c:-}" == "yes" ]] && vm_exec "proxyveth sync && proxyveth up all" && ok "Sync + Up выполнены"
}

do_change_vm_params() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { ask "VM ID:"; _rd VM_ID; }
    echo -e "\n  Текущие параметры VM ${VM_ID}:"
    qm config "$VM_ID" | grep -E "^(memory|cores|name):" || true
    echo ""
    ask "Новый RAM в MB (Enter = пропустить):";  _rd NEW_RAM
    ask "Новые CPU ядра (Enter = пропустить):";  _rd NEW_CORES
    [[ -n "${NEW_RAM:-}"   ]] && qm set "$VM_ID" --memory "$NEW_RAM"   && ok "RAM = ${NEW_RAM} MB"
    [[ -n "${NEW_CORES:-}" ]] && qm set "$VM_ID" --cores  "$NEW_CORES" && ok "CPU = ${NEW_CORES} ядра"
    warn "Изменения вступят в силу после перезапуска VM"
}

do_change_password() {
    need_ip
    ask "Новый root пароль:"; _rds NEW_PASS; echo ""
    [[ -n "${NEW_PASS:-}" ]] || fail "Пусто"
    vm_exec "echo 'root:${NEW_PASS}' | chpasswd"
    load_state
    [[ -n "${VM_ID:-}" ]] && qm set "$VM_ID" --cipassword "$NEW_PASS" 2>/dev/null || true
    ok "Пароль изменён"
}

do_set_ssh() {
    need_ip
    echo -e "\n  Текущие SSH настройки:"
    vm_exec "sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication)'" || true
    echo ""
    ask "Новый SSH порт (Enter = пропустить):";               _rd NEW_PORT
    ask "PasswordAuthentication yes/no (Enter = пропустить):"; _rd NEW_PA
    [[ -n "${NEW_PORT:-}" ]] && vm_exec "sed -i 's/^#*Port .*/Port ${NEW_PORT}/' /etc/ssh/sshd_config"
    [[ -n "${NEW_PA:-}"   ]] && vm_exec "printf 'PasswordAuthentication ${NEW_PA}\nPermitRootLogin yes\n' > /etc/ssh/sshd_config.d/99-allow-password.conf"
    vm_exec "systemctl restart ssh"
    ok "SSH обновлён"
    [[ -n "${NEW_PORT:-}" ]] && warn "Не забудь обновить порт в SSH_OPTS в mpctl если подключаешься не по 22"
}

# ══════════════════════════════════════════════════════════════════
#  MANAGE
# ══════════════════════════════════════════════════════════════════
do_pvmp_status()     { need_ip; vm_exec "proxyveth status"; }
do_pvmp_status_wan() { need_ip; vm_exec "proxyveth status --wan"; }
do_pvmp_sync()       { need_ip; vm_exec "proxyveth sync && proxyveth up all"; ok "Sync + Up выполнены"; }

do_pvmp_restart() {
    need_ip
    ask "Номер NS или all:"; _rd TARGET; [[ -n "${TARGET:-}" ]] || fail "Пусто"
    vm_exec "proxyveth restart ${TARGET}"; ok "Перезапущено: $TARGET"
}

do_pvmp_check() {
    need_ip
    ask "Номер NS для диагностики:"; _rd N; [[ -n "${N:-}" ]] || fail "Пусто"
    vm_exec "proxyveth check ${N}"
}

do_pvmp_logs() {
    need_ip
    echo -e "\n  ${D}Ctrl+C для выхода${R}"
    vm_exec "tail -f /etc/proxyvethmp/logs/watchdog.log"
}

do_reboot_vm() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { ask "VM ID:"; _rd VM_ID; }
    qm reboot "$VM_ID" 2>/dev/null || { need_ip; vm_exec "reboot" || true; }
    ok "VM перезагружается..."
}

do_show_summary() {
    need_ip
    load_state
    local wan; wan=$(vm_exec "curl -s --max-time 5 2ip.ru" 2>/dev/null || echo "—")
    echo -e "\n  ${G}Сводка для ЛК mobileproxy.space:${R}"
    echo -e "  ${B}════════════════════════════════════════${R}"
    echo -e "  Статический IP : ${wan}"
    echo -e "  LocalIP        : ${VM_IP}"
    echo -e "  Root login     : root"
    echo -e "  OS             : Unix"
    echo -e "  ${B}════════════════════════════════════════${R}"
    echo -e "  Мой прокси-бизнес → Сервера → ✏ Редактировать\n"
}

do_destroy_vm() {
    load_state
    [[ -n "${VM_ID:-}" ]] || { ask "VM ID:"; _rd VM_ID; }
    warn "ЭТО УДАЛИТ VM ${VM_ID} БЕЗВОЗВРАТНО!"
    ask "Введи DELETE для подтверждения:"; _rd _c
    [[ "${_c:-}" == "DELETE" ]] || { echo "Отменено"; return; }
    qm stop "$VM_ID" --skiplock 2>/dev/null || true; sleep 3
    qm destroy "$VM_ID" --destroy-unreferenced-disks 1 --purge 1
    VM_ID=""; VM_IP=""; save_state
    ok "VM удалена"
}

do_selfupdate() {
    step "Скачиваем последнюю версию..."
    local tmp; tmp=$(mktemp)
    wget -q -O "$tmp" "$SELF_URL" || fail "Не удалось скачать mpctl"
    local new_ver; new_ver=$(grep '^VERSION=' "$tmp" | cut -d'"' -f2)
    if [[ "$new_ver" == "$VERSION" ]]; then
        rm -f "$tmp"; ok "Уже актуальная версия (v${VERSION})"
    else
        mv "$tmp" /usr/local/bin/mpctl && chmod +x /usr/local/bin/mpctl
        ok "Обновлено: v${VERSION} → v${new_ver}"
        exec /usr/local/bin/mpctl
    fi
}

# ══════════════════════════════════════════════════════════════════
#  SELF-INSTALL
# ══════════════════════════════════════════════════════════════════
self_install_prompt() {
    local target="/usr/local/bin/mpctl"
    [[ -f "$target" ]] && return
    echo ""
    ask "Установить mpctl как команду /usr/local/bin/mpctl? (yes/no):"; _rd _c
    [[ "${_c:-}" == "yes" ]] || return
    wget -q -O "$target" "$SELF_URL" || fail "Не удалось скачать"
    chmod +x "$target"
    ok "Готово — теперь просто: mpctl"
}

# ══════════════════════════════════════════════════════════════════
#  МЕНЮ
# ══════════════════════════════════════════════════════════════════
menu_install() {
    while true; do
        echo -e "\n${B}  Установка${R}"
        echo -e "  ${D}──────────────────────────────────────────${R}"
        echo "  [1] Только VM"
        echo "  [2] Только Софт mp.space"
        echo "  [3] Только ProxyVethMP"
        echo "  [4] VM + Софт mp.space"
        echo "  [5] VM + ProxyVethMP"
        echo "  [6] Софт mp.space + ProxyVethMP"
        echo "  [7] Полный стек  (VM + mp.space + ProxyVethMP)"
        echo "  [0] ← Назад"
        echo ""
        ask "Выбор:"; _rd choice
        case ${choice:-} in
            1) do_install_vm ;;
            2) do_install_mp ;;
            3) do_install_proxyvethmp ;;
            4) do_install_vm; do_install_mp ;;
            5) do_install_vm; do_install_proxyvethmp ;;
            6) do_install_mp; do_install_proxyvethmp ;;
            7) do_install_vm; do_install_mp; do_install_proxyvethmp ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

menu_config() {
    while true; do
        echo -e "\n${B}  Настройка${R}"
        echo -e "  ${D}──────────────────────────────────────────${R}"
        echo "  [1] Ключ аутентификации mp.space (auth.mp)"
        echo "  [2] URL Google Sheets таблицы"
        echo "  [3] Параметры VM  (RAM / CPU)"
        echo "  [4] Root пароль VM"
        echo "  [5] SSH настройки"
        echo "  [0] ← Назад"
        echo ""
        ask "Выбор:"; _rd choice
        case ${choice:-} in
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
        echo -e "\n${B}  Управление${R}"
        echo -e "  ${D}──────────────────────────────────────────${R}"
        echo "  [1] Dashboard"
        echo "  [2] proxyveth status"
        echo "  [3] proxyveth status --wan"
        echo "  [4] proxyveth sync + up all"
        echo "  [5] proxyveth restart"
        echo "  [6] proxyveth check N"
        echo "  [7] Логи watchdog"
        echo "  [8] Сводка для ЛК mp.space"
        echo "  [9] Ребут VM"
        echo "  [d] Удалить VM"
        echo "  [u] Обновить mpctl"
        echo "  [0] ← Назад"
        echo ""
        ask "Выбор:"; _rd choice
        case ${choice:-} in
            1) show_dashboard ;;
            2) do_pvmp_status ;;
            3) do_pvmp_status_wan ;;
            4) do_pvmp_sync ;;
            5) do_pvmp_restart ;;
            6) do_pvmp_check ;;
            7) do_pvmp_logs ;;
            8) do_show_summary ;;
            9) do_reboot_vm ;;
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
        echo -e "  ${B}[1]${R} Установка   ${B}[2]${R} Настройка   ${B}[3]${R} Управление   ${B}[q]${R} Выход"
        echo ""
        ask "Выбор:"; _rd choice
        case ${choice:-} in
            1) menu_install ;;
            2) menu_config ;;
            3) menu_manage ;;
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

load_state
self_install_prompt
main_menu
