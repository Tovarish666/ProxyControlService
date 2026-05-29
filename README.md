# ProxyVeth — Proxy Control Service

Управление mobile proxy инфраструктурой на Proxmox VE.
Три компонента, один инструмент.

## Стек

| # | Компонент | Что делает |
|---|-----------|-----------|
| 1 | **Ubuntu VM** | Гостевая ВМ (cloud-init, SSH, DHCP) |
| 2 | **mobileproxy.space** | mproxy + nodejs-server — основной прокси-демон |
| 3 | **ProxyVeth** | SOCKS5 → veth-пара → mproxy (source routing) |

### Как работает ProxyVeth

Каждый модем получает изолированный network namespace с TUN-интерфейсом:

```
SOCKS5 (модем N)
      │
  tun2socks
      │
    tun{N}  ←── ns_{N} ──── veth_ext{N}_ns ──── 192.168.N.254
                                                       │
              HOST ──── veth_ext{N}_host ──── 192.168.N.100
                                                       │
                                                   mproxy
                                              (source routing)
```

mproxy отправляет трафик через `192.168.N.100` → veth → namespace → tun2socks → реальный SOCKS5 (мобильный модем).

## Быстрый старт

```bash
# На хосте Proxmox, от root:
bash <(curl -s https://raw.githubusercontent.com/Tovarish666/ProxyControlService/main/pscctl.sh)
```

Меню само предложит что установить — VM, ProxyVeth, mp.space, или всё сразу.

## Команды proxyveth (внутри VM)

| Команда | Описание |
|---------|----------|
| `proxyveth status` | Таблица NS + WAN IP каждого модема |
| `proxyveth check` | Диагностика: скорость + ping + 2ip |
| `proxyveth up [N\|all]` | Поднять namespace(ы) |
| `proxyveth down [N\|all]` | Опустить namespace(ы) |
| `proxyveth restart [N\|all]` | Перезапустить |
| `proxyveth sync` | Синхронизировать конфиг из Google Sheets |
| `proxyveth autosync` | Sync с применением diff (добавить/удалить/перезапустить) |
| `proxyveth watchdog` | Разовая проверка watchdog |
| `proxyveth watchdog-loop` | Watchdog-демон (бесконечный цикл) |
| `proxyveth show-config` | Показать конфиг модемов |
| `proxyveth cleanup` | Полная очистка (NS, iptables, veth) |

### `proxyveth check` — диагностика

```
  N  │  WAN IP         │  DL        │  Ping  │ Статус
  ───┼─────────────────┼────────────┼────────┼────────
   1 │ 1.2.3.4         │ 15.2 Mb/s  │  45ms  │ OK
   2 │ 1.2.3.5         │ 12.8 Mb/s  │  67ms  │ WLIST
   3 │ —               │    —       │   —    │ DEAD
```

| Статус | Значение |
|--------|----------|
| **OK** | Всё работает |
| **WLIST** | Белый список: скорость есть, 2ip.ru заблокирован |
| **DEAD** | Модем не отвечает |

Скорость измеряется через yaspeed (если установлен через `YASPEED_URL`) или curl + ping как fallback.

## Формат Google Sheets

Два поддерживаемых формата:

**Компактный** (один столбец proxy):

| n | proxy |
|---|-------|
| 1 | host:port:login:password |

**Раздельный**:

| n | proxy_host | proxy_port | login | password |
|---|-----------|-----------|-------|---------|

URL для pscctl: `https://...pub?gid=XXXX&single=true&output=csv`

## Файловая структура

```
/etc/proxyveth/
├── config.json          # конфиг модемов (из Google Sheets)
├── env                  # переменные окружения
└── logs/
    └── watchdog.log

/usr/local/bin/
├── proxyveth.py               # основной Python-скрипт
├── proxyveth -> ...           # симлинк
└── tun2socks            # бинарь tun2socks v2.5.2

/etc/systemd/system/
├── proxyveth.service           # up all при старте системы
├── proxyveth-watchdog.service  # watchdog-демон
├── proxyveth-autosync.service  # разовый sync
└── proxyveth-autosync.timer    # sync каждые 5 минут
```

## Переменные окружения (`/etc/proxyveth/env`)

| Переменная | Описание | Дефолт |
|------------|----------|--------|
| `SHEET_CSV_URL` | URL CSV-экспорта Google Sheets | — |
| `SHEET_ID` + `SHEET_GID` | ID таблицы + ID листа (альтернатива URL) | — |
| `YASPEED_URL` | URL бинаря yaspeed для `proxyveth check` | — |
| `WATCHDOG_INTERVAL` | Интервал watchdog (сек) | 60 |
| `WATCHDOG_WAN_EVERY` | WAN-проверка каждые N итераций | 10 |
| `WATCHDOG_MAX_RESTART` | Макс. перезапусков на модем | 3 |

## Требования

- Proxmox VE 7+
- Python 3.10+
- tun2socks — скачивается автоматически при установке
- Ubuntu 24.04 cloud image — скачивается автоматически
