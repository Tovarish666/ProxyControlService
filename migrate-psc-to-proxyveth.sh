#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  migrate-psc-to-proxyveth.sh
#  Миграция уже развёрнутой инсталляции psc → proxyveth.
#
#  ─ НА VM (гостевая Ubuntu):   bash migrate-psc-to-proxyveth.sh vm
#  ─ НА ХОСТЕ Proxmox:          bash migrate-psc-to-proxyveth.sh host
#
#  Запускать от root. Идемпотентно: если старого psc нет — ничего не делает.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

ROLE="${1:-}"
ok()   { echo -e "  \033[32m✓\033[0m $*"; }
step() { echo -e "  \033[2m→\033[0m $*"; }
warn() { echo -e "  \033[33m⚠\033[0m $*"; }

migrate_vm() {
    echo "── Миграция VM: psc → proxyveth ──"

    # 1. Остановить и отключить старые сервисы
    step "Останавливаем старые сервисы..."
    systemctl disable --now psc.service psc-watchdog.service \
        psc-autosync.timer psc-autosync.service 2>/dev/null || true
    rm -f /etc/systemd/system/psc.service \
          /etc/systemd/system/psc-watchdog.service \
          /etc/systemd/system/psc-autosync.service \
          /etc/systemd/system/psc-autosync.timer
    ok "Старые юниты удалены"

    # 2. Конфиг: /etc/psc → /etc/proxyveth
    if [[ -d /etc/psc && ! -d /etc/proxyveth ]]; then
        step "Переносим /etc/psc → /etc/proxyveth..."
        mv /etc/psc /etc/proxyveth
        ok "Конфиг перенесён"
    elif [[ -d /etc/proxyveth ]]; then
        warn "/etc/proxyveth уже существует — пропускаю перенос"
    fi

    # 3. Бинарь + симлинк
    if [[ -f /usr/local/bin/psc.py ]]; then
        step "Переносим бинарь psc.py → proxyveth.py..."
        mv /usr/local/bin/psc.py /usr/local/bin/proxyveth.py
    fi
    rm -f /usr/local/bin/psc
    ln -sf /usr/local/bin/proxyveth.py /usr/local/bin/proxyveth
    chmod +x /usr/local/bin/proxyveth.py
    ok "Бинарь: /usr/local/bin/proxyveth (+ симлинк)"

    # 4. sysctl-файл (косметика)
    [[ -f /etc/sysctl.d/99-psc.conf ]] && \
        mv /etc/sysctl.d/99-psc.conf /etc/sysctl.d/99-proxyveth.conf || true

    # 5. Перегенерировать systemd-юниты под новыми именами.
    #    proxyveth.py пишет юниты в setup_systemd(), которая зовётся из setup.
    #    Чтобы не гонять apt заново — пишем юниты напрямую здесь.
    step "Создаём новые systemd-юниты..."
    PY=/usr/bin/python3; SC=/usr/local/bin/proxyveth.py; ENVF=/etc/proxyveth/env
    cat > /etc/systemd/system/proxyveth.service <<EOF
[Unit]
Description=ProxyVeth — Proxy Control Service
After=network-online.target mproxy.service nodejs-server.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-${ENVF}
ExecStart=${PY} ${SC} init
ExecStart=${PY} ${SC} up all
ExecStop=${PY} ${SC} down all
TimeoutStartSec=300
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/proxyveth-watchdog.service <<EOF
[Unit]
Description=ProxyVeth Watchdog
After=proxyveth.service
Requires=proxyveth.service
[Service]
Type=simple
EnvironmentFile=-${ENVF}
ExecStart=${PY} ${SC} watchdog-loop
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/proxyveth-autosync.service <<EOF
[Unit]
Description=ProxyVeth Autosync
[Service]
Type=oneshot
EnvironmentFile=-${ENVF}
ExecStart=${PY} ${SC} autosync
EOF
    cat > /etc/systemd/system/proxyveth-autosync.timer <<EOF
[Unit]
Description=ProxyVeth Autosync Timer
[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable proxyveth.service proxyveth-watchdog.service proxyveth-autosync.timer
    systemctl start proxyveth-watchdog.service proxyveth-autosync.timer
    ok "Новые юниты enabled + watchdog/autosync запущены"

    # 6. Чисто переподнять namespace'ы под управлением proxyveth
    step "Переподнимаем namespace'ы..."
    proxyveth down all 2>/dev/null || true
    proxyveth up all || warn "up all завершился с ошибкой — проверь 'proxyveth status'"

    echo
    proxyveth status || true
    echo
    ok "VM мигрирована. Команда теперь: proxyveth"
}

migrate_host() {
    echo "── Миграция хоста Proxmox: /etc/psc → /etc/proxyveth ──"
    if [[ -d /etc/psc && ! -d /etc/proxyveth ]]; then
        mv /etc/psc /etc/proxyveth
        ok "Состояние pscctl перенесено в /etc/proxyveth"
    elif [[ -d /etc/proxyveth ]]; then
        warn "/etc/proxyveth уже есть — пропускаю"
    else
        warn "/etc/psc не найден — нечего мигрировать"
    fi
    ok "Готово. Обнови pscctl: bash <(curl -s https://raw.githubusercontent.com/Tovarish666/ProxyControlService/main/pscctl.sh)"
}

case "$ROLE" in
    vm)   migrate_vm ;;
    host) migrate_host ;;
    *)    echo "Использование: $0 {vm|host}"; exit 1 ;;
esac
