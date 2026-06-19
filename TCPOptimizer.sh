#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Запустите от имени root.${NC}"
    exit 1
fi

echo -e "${B_CYAN}=== Запуск оптимизации сети ===${NC}\n"

# 1. Автоматическое определение активного сетевого интерфейса
# Ищем интерфейс, через который идет дефолтный маршрут в интернет
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

if [ -z "$IFACE" ]; then
    echo -e "${B_RED}[!] Не удалось автоматически определить активный интерфейс. Используем eth0 по умолчанию.${NC}"
    IFACE="eth0"
else
    echo -e "${B_GREEN}[✓] Определен активный сетевой интерфейс: $IFACE${NC}"
fi

# 2. Настройка txqueuelen
echo -e "${B_YELLOW}[*] Настройка txqueuelen для $IFACE...${NC}"
ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null

# Создаем udev-правило для сохранения настройки после перезагрузки
echo "SUBSYSTEM==\"net\", ACTION==\"add\", KERNEL==\"*\", ATTR{txqueuelen}=\"10000\"" | tee /etc/udev/rules.d/99-network-txqueuelen.rules >/dev/null
echo -e "${B_GREEN}[✓] Правило udev для txqueuelen успешно записано.${NC}\n"

# 3. Скачивание нового sysctl.conf
URL="https://gist.githubusercontent.com/sngvy/66e8f0a21972e6a78ba1ba20c13b8a82/raw/sysctl.conf"
CONF_FILE="/etc/sysctl.conf"

echo -e "${B_CYAN}[*] Скачивание нового sysctl.conf...${NC}"

if command -v curl >/dev/null 2>&1; then
    curl -sSL "$URL" -o "$CONF_FILE"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$CONF_FILE" "$URL"
else
    echo -e "${B_RED}Ошибка: В системе не найдены curl или wget. Установите один из них.${NC}"
    exit 1
fi

# Проверяем, успешно ли скачался файл и не пустой ли он
if [ $? -eq 0 ] && [ -s "$CONF_FILE" ]; then
    echo -e "${B_GREEN}[✓] Файл sysctl.conf успешно скачан и перезаписан.${NC}\n"
    
    # 4. Применение новых настроек ядра
    echo -e "${B_YELLOW}[*] Применение новых параметров ядра...${NC}"
    sysctl -p
    
    if [ $? -eq 0 ]; then
        echo -e "\n${B_GREEN}${BOLD}[=== Оптимизация сети успешно завершена! ===]${NC}"
    else
        echo -e "\n${B_RED}Предупреждение: sysctl применился с какими-то ошибками. Проверьте вывод выше.${NC}"
    fi
else
    echo -e "${B_RED}Ошибка: Не удалось скачать файл или скачанный файл пуст.${NC}"
    exit 1
fi
