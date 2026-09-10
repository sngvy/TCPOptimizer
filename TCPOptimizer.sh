#!/bin/bash
# Вычисляет и применяет sysctl-твики под реальные характеристики сервера.
# Каждый параметр тестируется через sysctl -w; неподдерживаемые ядром
# автоматически не попадают в финальный /etc/sysctl.conf.

BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Запустите от имени root.${NC}"
    exit 1
fi

echo -e "${B_CYAN}=== TCPOptimizer: вычисление твиков под характеристики этого сервера ===${NC}\n"

# --- Сбор характеристик железа ---

RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
RAM_MB=$(( RAM_KB / 1024 ))
RAM_BYTES=$(( RAM_KB * 1024 ))
NCPU=$(nproc 2>/dev/null || echo 1)
PAGE_SIZE=$(getconf PAGE_SIZE 2>/dev/null || echo 4096)
TOTAL_PAGES=$(( RAM_BYTES / PAGE_SIZE ))
HAS_SWAP="no"
[ -n "$(swapon --show 2>/dev/null)" ] && HAS_SWAP="yes"

IFACE=$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)
[ -z "$IFACE" ] && IFACE="eth0"

echo -e "${B_GREEN}[✓] Обнаружено железо:${NC}"
echo -e "    RAM:              ${RAM_MB} MB"
echo -e "    vCPU:             ${NCPU}"
echo -e "    Размер страницы:  ${PAGE_SIZE} байт"
echo -e "    Swap:             ${HAS_SWAP}"
echo -e "    Интерфейс:        ${IFACE}\n"

# Профиль по объёму RAM — под него подобраны нелинейные значения (somaxconn и т.п.)
if   [ "$RAM_MB" -lt 1024 ];  then TIER="low"
elif [ "$RAM_MB" -lt 4096 ];  then TIER="medium"
elif [ "$RAM_MB" -lt 16384 ]; then TIER="high"
else                               TIER="xhigh"
fi
echo -e "${B_CYAN}[i] Профиль сервера по RAM: ${TIER}${NC}\n"

# --- Вычисление значений ---

echo -e "${B_YELLOW}[*] Вычисление параметров...${NC}\n"

case "$TIER" in
    low)    CORE_MEM_MAX=4194304  ;;
    medium) CORE_MEM_MAX=8388608  ;;
    high)   CORE_MEM_MAX=16777216 ;;
    xhigh)  CORE_MEM_MAX=33554432 ;;
esac
case "$TIER" in
    low)    CORE_MEM_DEFAULT=131072  ;;
    medium) CORE_MEM_DEFAULT=262144  ;;
    high)   CORE_MEM_DEFAULT=524288  ;;
    xhigh)  CORE_MEM_DEFAULT=1048576 ;;
esac

TCP_RMEM="4096 87380 ${CORE_MEM_MAX}"
TCP_WMEM="4096 65536 ${CORE_MEM_MAX}"

# tcp_mem/udp_mem — в страницах памяти, не в байтах; 5/10/15% от общего числа страниц
TCP_MEM_MIN=$(( TOTAL_PAGES * 5  / 100 ))
TCP_MEM_PRESSURE=$(( TOTAL_PAGES * 10 / 100 ))
TCP_MEM_MAX=$(( TOTAL_PAGES * 15 / 100 ))
UDP_MEM_MIN=$TCP_MEM_MIN
UDP_MEM_PRESSURE=$TCP_MEM_PRESSURE
UDP_MEM_MAX=$TCP_MEM_MAX

NETDEV_BACKLOG=$(( NCPU * 5000 ))
[ "$NETDEV_BACKLOG" -lt 5000 ]  && NETDEV_BACKLOG=5000
[ "$NETDEV_BACKLOG" -gt 65536 ] && NETDEV_BACKLOG=65536

# netdev_budget/netdev_budget_usecs — сколько пакетов softirq успевает разобрать за один проход
NETDEV_BUDGET=$(( NCPU * 300 ))
[ "$NETDEV_BUDGET" -lt 300 ]  && NETDEV_BUDGET=300
[ "$NETDEV_BUDGET" -gt 1200 ] && NETDEV_BUDGET=1200
NETDEV_BUDGET_USECS=$(( NCPU * 2000 ))
[ "$NETDEV_BUDGET_USECS" -lt 2000 ] && NETDEV_BUDGET_USECS=2000
[ "$NETDEV_BUDGET_USECS" -gt 8000 ] && NETDEV_BUDGET_USECS=8000

# rps_sock_flow_entries — глобальная таблица RFS (Receive Flow Steering)
RPS_SOCK_FLOW_ENTRIES=$(( NCPU * 8192 ))
[ "$RPS_SOCK_FLOW_ENTRIES" -lt 8192 ]  && RPS_SOCK_FLOW_ENTRIES=8192
[ "$RPS_SOCK_FLOW_ENTRIES" -gt 65536 ] && RPS_SOCK_FLOW_ENTRIES=65536

case "$TIER" in
    low)    SOMAXCONN=1024  ;;
    medium) SOMAXCONN=4096  ;;
    high)   SOMAXCONN=8192  ;;
    xhigh)  SOMAXCONN=65535 ;;
esac
SYN_BACKLOG=$(( SOMAXCONN * 4 ))
[ "$SYN_BACKLOG" -gt 65536 ] && SYN_BACKLOG=65536

# ~100 orphan-сокетов на 1 МБ RAM
TCP_MAX_ORPHANS=$(( RAM_MB * 100 ))
[ "$TCP_MAX_ORPHANS" -lt 8192 ]    && TCP_MAX_ORPHANS=8192
[ "$TCP_MAX_ORPHANS" -gt 1000000 ] && TCP_MAX_ORPHANS=1000000

TCP_MAX_TW_BUCKETS=$(( SOMAXCONN * 20 ))
[ "$TCP_MAX_TW_BUCKETS" -lt 16384 ]   && TCP_MAX_TW_BUCKETS=16384
[ "$TCP_MAX_TW_BUCKETS" -gt 2000000 ] && TCP_MAX_TW_BUCKETS=2000000

# neighbor-таблица: важно при активном Docker (veth-пары при (пере)создании контейнеров)
case "$TIER" in
    low)    GC_THRESH1=512;  GC_THRESH2=2048; GC_THRESH3=4096  ;;
    medium) GC_THRESH1=1024; GC_THRESH2=4096; GC_THRESH3=8192  ;;
    high)   GC_THRESH1=2048; GC_THRESH2=8192; GC_THRESH3=16384 ;;
    xhigh)  GC_THRESH1=4096; GC_THRESH2=16384;GC_THRESH3=32768 ;;
esac

MIN_FREE_KBYTES=$(( RAM_KB * 1 / 100 ))
[ "$MIN_FREE_KBYTES" -lt 65536 ]   && MIN_FREE_KBYTES=65536
[ "$MIN_FREE_KBYTES" -gt 1048576 ] && MIN_FREE_KBYTES=1048576

# ~10 КБ RAM на файловый дескриптор
FILE_MAX=$(( RAM_KB / 10 ))
[ "$FILE_MAX" -lt 100000 ]  && FILE_MAX=100000
[ "$FILE_MAX" -gt 2000000 ] && FILE_MAX=2000000


# conntrack: до 5% RAM, ~350 байт на запись, buckets = max / 4
CONNTRACK_PERCENT=5
BYTES_PER_ENTRY=350
CONNTRACK_BUDGET_BYTES=$(( RAM_BYTES * CONNTRACK_PERCENT / 100 ))
NF_CONNTRACK_MAX=$(( CONNTRACK_BUDGET_BYTES / BYTES_PER_ENTRY ))
[ "$NF_CONNTRACK_MAX" -lt 32768 ]   && NF_CONNTRACK_MAX=32768
[ "$NF_CONNTRACK_MAX" -gt 1048576 ] && NF_CONNTRACK_MAX=1048576
NF_CONNTRACK_BUCKETS=$(( NF_CONNTRACK_MAX / 4 ))

if [ "$TIER" = "low" ] && [ "$HAS_SWAP" = "yes" ]; then
    SWAPPINESS=20
else
    SWAPPINESS=10
fi

case "$TIER" in
    low)    DIRTY_BG=3;  DIRTY=10 ;;
    medium) DIRTY_BG=5;  DIRTY=15 ;;
    high)   DIRTY_BG=10; DIRTY=20 ;;
    xhigh)  DIRTY_BG=10; DIRTY=20 ;;
esac

case "$TIER" in
    low)    INOTIFY_WATCHES=65536;  INOTIFY_INSTANCES=128 ;;
    medium) INOTIFY_WATCHES=262144; INOTIFY_INSTANCES=256 ;;
    high)   INOTIFY_WATCHES=524288; INOTIFY_INSTANCES=512 ;;
    xhigh)  INOTIFY_WATCHES=1048576;INOTIFY_INSTANCES=1024 ;;
esac

case "$TIER" in
    low)    TXQUEUELEN=5000  ;;
    medium) TXQUEUELEN=10000 ;;
    high)   TXQUEUELEN=20000 ;;
    xhigh)  TXQUEUELEN=20000 ;;
esac

# kernel.pid_max — потолок числа PID одновременно в системе
PID_MAX=$(( NCPU * 32768 ))
[ "$PID_MAX" -lt 32768 ]   && PID_MAX=32768
[ "$PID_MAX" -gt 4194304 ] && PID_MAX=4194304

# --- Сводка ---

echo -e "${B_GREEN}[✓] Вычисленные параметры:${NC}"
printf "    %-38s %s\n" "core rmem/wmem max:"        "${CORE_MEM_MAX} байт"
printf "    %-38s %s\n" "tcp_rmem:"                    "${TCP_RMEM}"
printf "    %-38s %s\n" "tcp_wmem:"                    "${TCP_WMEM}"
printf "    %-38s %s\n" "tcp_mem (страницы):"           "${TCP_MEM_MIN} ${TCP_MEM_PRESSURE} ${TCP_MEM_MAX}"
printf "    %-38s %s\n" "netdev_max_backlog:"           "${NETDEV_BACKLOG}"
printf "    %-38s %s\n" "netdev_budget / usecs:"        "${NETDEV_BUDGET} / ${NETDEV_BUDGET_USECS}"
printf "    %-38s %s\n" "rps_sock_flow_entries:"        "${RPS_SOCK_FLOW_ENTRIES}"
printf "    %-38s %s\n" "somaxconn:"                    "${SOMAXCONN}"
printf "    %-38s %s\n" "tcp_max_syn_backlog:"          "${SYN_BACKLOG}"
printf "    %-38s %s\n" "fs.file-max:"                  "${FILE_MAX}"
printf "    %-38s %s\n" "nf_conntrack_max / buckets:"   "${NF_CONNTRACK_MAX} / ${NF_CONNTRACK_BUCKETS}"
printf "    %-38s %s\n" "vm.swappiness:"                "${SWAPPINESS}"
printf "    %-38s %s\n" "dirty_background_ratio/dirty:" "${DIRTY_BG} / ${DIRTY}"
printf "    %-38s %s\n" "inotify watches/instances:"    "${INOTIFY_WATCHES} / ${INOTIFY_INSTANCES}"
printf "    %-38s %s\n" "txqueuelen:"                    "${TXQUEUELEN}"
printf "    %-38s %s\n" "kernel.pid_max:"                "${PID_MAX}"
echo ""

# --- Формирование sysctl.conf ---
# "Вкл/выкл"-параметры (BBR, fq, ECN и т.п.) не детектируются заранее -
# просто тестируются ниже через sysctl -w вместе с числовыми.

LINES=()
add() { LINES+=("$1"); }
add_comment() { LINES+=("# $1"); }
add_blank() { LINES+=(""); }

add_comment "Сгенерировано TCPOptimizer.sh: RAM=${RAM_MB}MB vCPU=${NCPU} tier=${TIER} $(date '+%Y-%m-%d %H:%M:%S')"
add_blank

add_comment "Буферы сокетов"
add "net.core.rmem_max = ${CORE_MEM_MAX}"
add "net.core.wmem_max = ${CORE_MEM_MAX}"
add "net.core.rmem_default = ${CORE_MEM_DEFAULT}"
add "net.core.wmem_default = ${CORE_MEM_DEFAULT}"
add "net.ipv4.tcp_rmem = ${TCP_RMEM}"
add "net.ipv4.tcp_wmem = ${TCP_WMEM}"
add "net.ipv4.tcp_mem = ${TCP_MEM_MIN} ${TCP_MEM_PRESSURE} ${TCP_MEM_MAX}"
add "net.ipv4.udp_mem = ${UDP_MEM_MIN} ${UDP_MEM_PRESSURE} ${UDP_MEM_MAX}"
add "net.core.optmem_max = 262144"
add "net.unix.max_dgram_qlen = 256"
add_blank

add_comment "Очереди и backlog"
add "net.core.netdev_max_backlog = ${NETDEV_BACKLOG}"
add "net.core.netdev_budget = ${NETDEV_BUDGET}"
add "net.core.netdev_budget_usecs = ${NETDEV_BUDGET_USECS}"
add "net.core.rps_sock_flow_entries = ${RPS_SOCK_FLOW_ENTRIES}"
add "net.core.somaxconn = ${SOMAXCONN}"
add "net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}"
add "net.ipv4.tcp_max_orphans = ${TCP_MAX_ORPHANS}"
add "net.ipv4.tcp_max_tw_buckets = ${TCP_MAX_TW_BUCKETS}"
add "net.ipv4.ip_local_port_range = 10240 65535"
add_blank

add_comment "Congestion control / qdisc"
add "net.core.default_qdisc = fq_codel"
add "net.ipv4.tcp_congestion_control = bbr"
add_blank

add_comment "TCP hardening / поведение соединений"
add "net.ipv4.tcp_syncookies = 1"
add "net.ipv4.tcp_fin_timeout = 15"
add "net.ipv4.tcp_tw_reuse = 1"
add "net.ipv4.tcp_slow_start_after_idle = 0"
add "net.ipv4.tcp_rfc1337 = 1"
add "net.ipv4.tcp_mtu_probing = 1"
add "net.ipv4.tcp_notsent_lowat = 32768"
add "net.ipv4.tcp_retries2 = 8"
add "net.ipv4.tcp_sack = 1"
add "net.ipv4.tcp_dsack = 1"
add "net.ipv4.tcp_window_scaling = 1"
add "net.ipv4.tcp_adv_win_scale = -2"
add "net.ipv4.tcp_fastopen = 3"
add "net.ipv4.tcp_keepalive_time = 300"
add "net.ipv4.tcp_keepalive_probes = 7"
add "net.ipv4.tcp_keepalive_intvl = 30"
add "net.ipv4.tcp_no_metrics_save = 1"
add "net.ipv4.tcp_autocorking = 0"
add_blank

# ECN может мешать некоторым мобильным сетям/middlebox'ам — при проблемах у части клиентов пробовать tcp_ecn=0
add "net.ipv4.tcp_ecn = 1"
add "net.ipv4.tcp_ecn_fallback = 1"
add_blank

add_comment "Redirects / source route / rp_filter"
add "net.ipv4.conf.all.accept_redirects = 0"
add "net.ipv4.conf.default.accept_redirects = 0"
add "net.ipv4.conf.all.send_redirects = 0"
add "net.ipv4.conf.default.send_redirects = 0"
add "net.ipv4.conf.all.accept_source_route = 0"
add "net.ipv4.conf.default.accept_source_route = 0"
add "net.ipv4.conf.all.rp_filter = 2"
add "net.ipv4.conf.default.rp_filter = 2"
add "net.ipv4.ip_forward = 1"
add_blank

add_comment "IPv6: форвардинг и аналоги security-твиков из IPv4"
add "net.ipv6.conf.all.forwarding = 1"
add "net.ipv6.conf.default.forwarding = 1"
add "net.ipv6.conf.all.accept_redirects = 0"
add "net.ipv6.conf.default.accept_redirects = 0"
add "net.ipv6.conf.all.accept_source_route = 0"
add "net.ipv6.conf.default.accept_source_route = 0"
add_blank

add_comment "ARP / neighbor table"
add "net.ipv4.neigh.default.gc_thresh1 = ${GC_THRESH1}"
add "net.ipv4.neigh.default.gc_thresh2 = ${GC_THRESH2}"
add "net.ipv4.neigh.default.gc_thresh3 = ${GC_THRESH3}"
add "net.ipv4.neigh.default.gc_stale_time = 60"
add "net.ipv4.conf.default.arp_announce = 2"
add "net.ipv4.conf.lo.arp_announce = 2"
add "net.ipv4.conf.all.arp_announce = 2"
add_blank

add_comment "Conntrack"
add "net.netfilter.nf_conntrack_max = ${NF_CONNTRACK_MAX}"
add "net.netfilter.nf_conntrack_buckets = ${NF_CONNTRACK_BUCKETS}"
add "net.netfilter.nf_conntrack_tcp_timeout_established = 3600"
add "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
add "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15"
add "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15"
add "net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30"
add "net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30"
add "net.netfilter.nf_conntrack_tcp_loose = 1"
add "net.netfilter.nf_conntrack_tcp_be_liberal = 1"
add "net.netfilter.nf_conntrack_udp_timeout = 30"
add "net.netfilter.nf_conntrack_udp_timeout_stream = 120"
add "net.netfilter.nf_conntrack_icmp_timeout = 30"
add "net.netfilter.nf_conntrack_generic_timeout = 120"
# add "net.netfilter.nf_conntrack_helper = 0"
add_blank

add_comment "Файловые дескрипторы и inotify"
add "fs.file-max = ${FILE_MAX}"
add "fs.inotify.max_user_watches = ${INOTIFY_WATCHES}"
add "fs.inotify.max_user_instances = ${INOTIFY_INSTANCES}"
add_blank

add_comment "Память"
add "vm.swappiness = ${SWAPPINESS}"
add "vm.vfs_cache_pressure = 100"
add "vm.dirty_background_ratio = ${DIRTY_BG}"
add "vm.dirty_ratio = ${DIRTY}"
add "vm.min_free_kbytes = ${MIN_FREE_KBYTES}"
add "vm.overcommit_memory = 0"
add "vm.overcommit_ratio = 100"
add_blank

# panic=10, а не 1 — чтобы сообщение о панике успело попасть в лог перед ребутом
add "kernel.panic = 10"
add "kernel.pid_max = ${PID_MAX}"
add_blank

add "net.ipv4.icmp_ratelimit = 100"
add "net.ipv4.icmp_ratemask = 6168"

# --- Проверка и применение ---

echo -e "${B_YELLOW}[*] Предзагрузка модуля nf_conntrack...${NC}"
modprobe nf_conntrack 2>/dev/null
if lsmod | grep -q '^nf_conntrack'; then
    echo -e "${B_GREEN}[✓] Модуль nf_conntrack загружен.${NC}\n"
else
    echo -e "${B_YELLOW}[!] Модуль nf_conntrack не загрузился — соответствующие твики будут пропущены.${NC}\n"
fi

echo -e "${B_YELLOW}[*] Проверка применимости каждого параметра на этом ядре...${NC}"

FILTERED_FILE=$(mktemp /tmp/sysctl.conf.filtered.XXXXXX)
APPLIED_COUNT=0
SKIPPED_COUNT=0
SKIPPED_KEYS=()

for line in "${LINES[@]}"; do
    trimmed="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -z "$trimmed" ] || [[ "$trimmed" == \#* ]]; then
        echo "$line" >> "$FILTERED_FILE"
        continue
    fi

    if [[ "$trimmed" =~ ^([a-zA-Z0-9_\.-]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        if sysctl -w "${key}=${value}" >/dev/null 2>/tmp/sysctl_err_$$; then
            echo "$line" >> "$FILTERED_FILE"
            APPLIED_COUNT=$((APPLIED_COUNT + 1))
        else
            err_msg=$(cat /tmp/sysctl_err_$$ 2>/dev/null)
            echo -e "${B_RED}  [✗] Пропущен: ${key} = ${value}${NC}"
            [ -n "$err_msg" ] && echo -e "${B_RED}      причина: ${err_msg}${NC}"
            SKIPPED_KEYS+=("$key")
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
        rm -f /tmp/sysctl_err_$$
    else
        continue
    fi
done

echo
echo -e "${B_CYAN}[*] Результат проверки: применено ${APPLIED_COUNT}, пропущено ${SKIPPED_COUNT}${NC}"
if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo -e "${B_YELLOW}    Пропущенные параметры: ${SKIPPED_KEYS[*]}${NC}"
fi
echo

CONF_FILE="/etc/sysctl.conf"
if [ -f "$CONF_FILE" ]; then
    BACKUP_FILE="${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CONF_FILE" "$BACKUP_FILE"
    echo -e "${B_GREEN}[✓] Текущий sysctl.conf сохранён как ${BACKUP_FILE}${NC}"
fi

cp "$FILTERED_FILE" "$CONF_FILE"
rm -f "$FILTERED_FILE"
echo -e "${B_GREEN}[✓] Вычисленный sysctl.conf записан в ${CONF_FILE}${NC}\n"

echo -e "${B_YELLOW}[*] Финальное применение...${NC}"
if sysctl -p; then
    echo -e "${B_GREEN}${BOLD}[✓] Оптимизация завершена успешно.${NC}"
else
    echo -e "${B_RED}Предупреждение: sysctl -p завершился с ошибками, проверьте вывод выше.${NC}"
fi

echo -e "\n${B_YELLOW}[*] Настройка txqueuelen=${TXQUEUELEN} для ${IFACE}...${NC}"
if ip link set dev "$IFACE" txqueuelen "$TXQUEUELEN" 2>/dev/null; then
    echo "SUBSYSTEM==\"net\", ACTION==\"add\", KERNEL==\"$IFACE\", ATTR{txqueuelen}=\"$TXQUEUELEN\"" \
        | tee /etc/udev/rules.d/99-network-txqueuelen.rules >/dev/null
    echo -e "${B_GREEN}[✓] txqueuelen применён и сохранён в udev-правиле.${NC}"
else
    echo -e "${B_RED}[✗] Не удалось изменить txqueuelen для ${IFACE}.${NC}"
fi

# --- Горячее включение fq_codel на интерфейсе ---
# net.core.default_qdisc влияет только на новые qdisc при поднятии интерфейса,
# уже прикреплённый qdisc (fq/pfifo_fast) он не заменяет — делаем явно через tc.
echo -e "\n${B_YELLOW}[*] Применение qdisc fq_codel на ${IFACE}...${NC}"
CURRENT_QDISC=$(tc qdisc show dev "$IFACE" | awk '/qdisc/{print $2; exit}')
echo -e "    Текущий qdisc: ${CURRENT_QDISC:-неизвестно}"

if tc qdisc replace dev "$IFACE" root fq_codel 2>/tmp/tc_err_$$; then
    echo -e "${B_GREEN}[✓] fq_codel применён на ${IFACE} прямо сейчас.${NC}"
else
    err_msg=$(cat /tmp/tc_err_$$ 2>/dev/null)
    echo -e "${B_RED}[✗] Не удалось применить fq_codel на ${IFACE}.${NC}"
    [ -n "$err_msg" ] && echo -e "${B_RED}    причина: ${err_msg}${NC}"
fi
rm -f /tmp/tc_err_$$

# Персистентность после перезагрузки — аналогично txqueuelen/THP ниже:
# /etc/sysctl.conf применится сам при поднятии интерфейса штатным сетевым
# менеджером, но не все дистрибутивы гарантируют это (netplan/NetworkManager
# иногда переопределяют qdisc), поэтому закрепляем через systemd-юнит.
cat << EOF_QDISC > /etc/systemd/system/fq-codel-${IFACE}.service
[Unit]
Description=Apply fq_codel qdisc on ${IFACE}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${IFACE} root fq_codel
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_QDISC

systemctl daemon-reload
systemctl enable --now "fq-codel-${IFACE}.service" >/dev/null 2>&1
echo -e "${B_GREEN}[✓] Служба fq-codel-${IFACE}.service создана и включена для персистентности после ребута.${NC}"

# --- Transparent Huge Pages ---
# Не sysctl-параметр (управляется через /sys, не /proc/sys), поэтому не идёт
# в общий список LINES/sysctl.conf. При памяти под давлением (активный своп,
# минимум free) периодическая компакция/дефрагментация THP сама по себе ест
# CPU в моменты, когда его и так не хватает — отключаем и defrag, и enabled.
echo -e "\n${B_YELLOW}[*] Отключение Transparent Huge Pages (defrag/enabled)...${NC}"
THP_APPLIED=0
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && THP_APPLIED=1
fi
if [ -f /sys/kernel/mm/transparent_hugepage/defrag ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null && THP_APPLIED=1
fi

if [ "$THP_APPLIED" -eq 1 ]; then
    echo -e "${B_GREEN}[✓] THP отключён на текущей загрузке.${NC}"

    # /sys сбрасывается при каждой перезагрузке — закрепляем через systemd,
    # аналогично udev-правилу для txqueuelen выше.
    cat << 'EOF' > /usr/local/bin/disable-thp.sh
#!/bin/bash
[ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo never > /sys/kernel/mm/transparent_hugepage/enabled
[ -f /sys/kernel/mm/transparent_hugepage/defrag ]  && echo never > /sys/kernel/mm/transparent_hugepage/defrag
EOF
    chmod +x /usr/local/bin/disable-thp.sh

    if [ ! -f /etc/systemd/system/disable-thp.service ]; then
        cat << 'EOF' > /etc/systemd/system/disable-thp.service
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable-thp.sh
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
        systemctl daemon-reload
        systemctl enable disable-thp.service >/dev/null 2>&1
        echo -e "${B_GREEN}[✓] Служба disable-thp.service создана и включена для персистентности после ребута.${NC}"
    fi
else
    echo -e "${B_YELLOW}[!] THP-интерфейс не найден в /sys — пропускаю (возможно, отключён на уровне ядра).${NC}"
fi

echo -e "\n${B_GREEN}${BOLD}Готово. Все параметры вычислены под RAM=${RAM_MB}MB, vCPU=${NCPU} (профиль: ${TIER}).${NC}"
