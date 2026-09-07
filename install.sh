#!/bin/bash

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- ХРАНИЛИЩЕ ПРАВИЛ (переживает перезапуск iptables/aaPanel) ---
RULES_DIR="/etc/gokaskad"
RULES_FILE="$RULES_DIR/rules.conf"
SERVICE_FILE="/etc/systemd/system/gokaskad-restore.service"

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Запустите скрипт с правами root!${NC}"
        exit 1
    fi
}

# --- ПОДГОТОВКА СИСТЕМЫ ---
prepare_system() {
    # Автоматическое создание глобальной команды gokaskad
    if [ "$0" != "/usr/local/bin/gokaskad" ]; then
        cp -f "$0" "/usr/local/bin/gokaskad"
        chmod +x "/usr/local/bin/gokaskad"
    fi

    mkdir -p "$RULES_DIR"
    touch "$RULES_FILE"

    # Включение IP Forwarding
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    else
        sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    fi

    # Активация Google BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null

    # Установка зависимостей
    export DEBIAN_FRONTEND=noninteractive
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        apt-get update -y > /dev/null
        apt-get install -y iptables-persistent netfilter-persistent qrencode > /dev/null
    fi

    install_restore_service
}

# --- УСТАНОВКА SYSTEMD-СЛУЖБЫ ДЛЯ АВТО-ВОССТАНОВЛЕНИЯ ---
install_restore_service() {
    if [ -f "$SERVICE_FILE" ]; then
        return
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Gokaskad - restore port forwarding rules after reboot/aaPanel firewall reload
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gokaskad --restore-only
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable gokaskad-restore.service > /dev/null 2>&1
}

# --- ИНСТРУКЦИЯ ---
show_instructions() {
    clear
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║             📚 ИНСТРУКЦИЯ: КАК НАСТРОИТЬ КАСКАД              ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}ШАГ 1: Подготовка${NC}"
    echo -e "У вас должны быть данные от зарубежного сервера (VPN/Прокси и т.д.):"
    echo -e " - ${YELLOW}IP адрес${NC} (зарубежный)"
    echo -e " - ${YELLOW}Порт${NC} (на котором работает целевой сервис)"
    echo ""
    echo -e "${CYAN}ШАГ 2: Настройка этого сервера${NC}"
    echo -e "1. Выберите нужный пункт (${GREEN}1-3${NC} для стандартных или ${GREEN}4${NC} для кастомных)."
    echo -e "2. Введите ${YELLOW}IP${NC} и ${YELLOW}Порты${NC} (входящий и исходящий)."
    echo -e "3. Скрипт создаст 'мост' через этот VPS."
    echo ""
    echo -e "${CYAN}ШАГ 3: Настройка Клиента (Важно!)${NC}"
    echo -e "1. Откройте приложение клиента."
    echo -e "2. В настройках соединения найдите поле ${YELLOW}Endpoint / Адрес сервера${NC}."
    echo -e "3. Замените зарубежный IP на ${GREEN}IP ЭТОГО СЕРВЕРА${NC}."
    echo -e "4. Если вы использовали разные порты в правиле №4, укажите Входящий порт."
    echo ""
    echo -e "${GREEN}Готово! Теперь трафик идет: Клиент -> Этот Сервер -> Зарубеж.${NC}"
    echo ""
    echo -e "${CYAN}О сохранении правил:${NC}"
    echo -e "Все правила сохраняются в ${YELLOW}$RULES_FILE${NC}."
    echo -e "Если aaPanel или перезагрузка сбросят iptables, при следующем запуске"
    echo -e "скрипта (или автоматически при загрузке сервера через systemd-службу"
    echo -e "${YELLOW}gokaskad-restore.service${NC}) правила будут восстановлены заново."
    echo -e "Чтобы правило исчезло навсегда — удаляйте его через пункт ${RED}6${NC}."
    echo ""
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

# --- РАБОТА С ФАЙЛОМ ПРАВИЛ ---
# Формат строки: PROTO|IN_PORT|OUT_PORT|TARGET_IP|NAME

save_rule_to_file() {
    local PROTO=$1 IN_PORT=$2 OUT_PORT=$3 TARGET_IP=$4 NAME=$5
    # Убираем старую запись с тем же протоколом+входящим портом (правило переопределяется)
    remove_rule_from_file "$PROTO" "$IN_PORT" "silent"
    echo "${PROTO}|${IN_PORT}|${OUT_PORT}|${TARGET_IP}|${NAME}" >> "$RULES_FILE"
}

remove_rule_from_file() {
    local PROTO=$1 IN_PORT=$2 SILENT=$3
    if [ -f "$RULES_FILE" ]; then
        grep -v "^${PROTO}|${IN_PORT}|" "$RULES_FILE" > "${RULES_FILE}.tmp" 2>/dev/null
        mv -f "${RULES_FILE}.tmp" "$RULES_FILE"
    fi
}

# Проверяет, есть ли уже такое правило в iptables прямо сейчас
rule_exists_in_iptables() {
    local PROTO=$1 IN_PORT=$2 OUT_PORT=$3 TARGET_IP=$4
    iptables -t nat -C PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT" 2>/dev/null
}

# Проходит по сохранённому файлу и восстанавливает недостающие правила
restore_rules() {
    if [ ! -s "$RULES_FILE" ]; then
        return
    fi

    local restored=0
    while IFS='|' read -r PROTO IN_PORT OUT_PORT TARGET_IP NAME; do
        [ -z "$PROTO" ] && continue
        if ! rule_exists_in_iptables "$PROTO" "$IN_PORT" "$OUT_PORT" "$TARGET_IP"; then
            apply_iptables_rules "$PROTO" "$IN_PORT" "$OUT_PORT" "$TARGET_IP" "$NAME" "no-save" "quiet"
            restored=$((restored+1))
        fi
    done < "$RULES_FILE"

    if [ "$restored" -gt 0 ] && [ "$1" != "quiet" ]; then
        echo -e "${GREEN}[*] Восстановлено правил после перезапуска: $restored${NC}"
    fi
}

# --- СТАНДАРТНАЯ НАСТРОЙКА (ПОРТ ВХОДА = ПОРТ ВЫХОДА) ---
configure_rule() {
    local PROTO=$1
    local NAME=$2

    echo -e "\n${CYAN}--- Настройка $NAME ($PROTO) ---${NC}"

    while true; do
        echo -e "Введите IP адрес назначения:"
        read -p "> " TARGET_IP
        if [[ -n "$TARGET_IP" ]]; then break; fi
    done

    while true; do
        echo -e "Введите Порт (одинаковый для входа и выхода):"
        read -p "> " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -le 65535 ]; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом!${NC}"
    done

    apply_iptables_rules "$PROTO" "$PORT" "$PORT" "$TARGET_IP" "$NAME"
}

# --- КАСТОМНАЯ НАСТРОЙКА (РАЗНЫЕ ПОРТЫ) ---
configure_custom_rule() {
    echo -e "\n${CYAN}--- 🛠 Универсальное кастомное правило ---${NC}"
    echo -e "${WHITE}Подходит для перенаправления ЛЮБЫХ протоколов (SSH, RDP, нестандартные порты)."
    echo -e "Позволяет сделать так, чтобы клиент подключался к одному порту,"
    echo -e "а трафик уходил на другой порт зарубежного сервера.${NC}\n"

    while true; do
        echo -e "Выберите протокол (${YELLOW}tcp${NC} или ${YELLOW}udp${NC}):"
        read -p "> " PROTO
        if [[ "$PROTO" == "tcp" || "$PROTO" == "udp" ]]; then break; fi
        echo -e "${RED}Ошибка: введите tcp или udp!${NC}"
    done

    while true; do
        echo -e "Введите IP адрес назначения (куда отправляем трафик):"
        read -p "> " TARGET_IP
        if [[ -n "$TARGET_IP" ]]; then break; fi
    done

    while true; do
        echo -e "Введите ${YELLOW}ВХОДЯЩИЙ Порт${NC} (на этом сервере):"
        read -p "> " IN_PORT
        if [[ "$IN_PORT" =~ ^[0-9]+$ ]] && [ "$IN_PORT" -le 65535 ]; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом!${NC}"
    done

    while true; do
        echo -e "Введите ${YELLOW}ИСХОДЯЩИЙ Порт${NC} (на конечном сервере):"
        read -p "> " OUT_PORT
        if [[ "$OUT_PORT" =~ ^[0-9]+$ ]] && [ "$OUT_PORT" -le 65535 ]; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом!${NC}"
    done

    apply_iptables_rules "$PROTO" "$IN_PORT" "$OUT_PORT" "$TARGET_IP" "Custom Rule"
}

# --- ПРИМЕНЕНИЕ ПРАВИЛ IPTABLES ---
# Доп. параметры: $6 = "no-save" чтобы не писать в файл (используется при restore)
#                 $7 = "quiet" чтобы не печатать и не спрашивать Enter (используется при restore)
apply_iptables_rules() {
    local PROTO=$1
    local IN_PORT=$2
    local OUT_PORT=$3
    local TARGET_IP=$4
    local NAME=$5
    local NO_SAVE=$6
    local QUIET=$7

    IFACE=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
    if [[ -z "$IFACE" ]]; then
        echo -e "${RED}[ERROR] Не удалось определить интерфейс!${NC}"
        [ "$QUIET" != "quiet" ] && exit 1
        return 1
    fi

    [ "$QUIET" != "quiet" ] && echo -e "${YELLOW}[*] Применение правил...${NC}"

    # Удаление старых правил (по входящему порту)
    iptables -t nat -D PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT" 2>/dev/null
    iptables -D INPUT -p "$PROTO" --dport "$IN_PORT" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    # Новые правила
    iptables -A INPUT -p "$PROTO" --dport "$IN_PORT" -j ACCEPT
    iptables -t nat -A PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT"

    if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    fi

    iptables -A FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Настройка UFW если активен
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$IN_PORT"/"$PROTO" >/dev/null
        sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        ufw reload >/dev/null
    fi

    netfilter-persistent save > /dev/null

    # Сохраняем в наш собственный файл-бекап (переживает сброс iptables aaPanel'ом)
    if [ "$NO_SAVE" != "no-save" ]; then
        save_rule_to_file "$PROTO" "$IN_PORT" "$OUT_PORT" "$TARGET_IP" "$NAME"
    fi

    if [ "$QUIET" != "quiet" ]; then
        echo -e "${GREEN}[SUCCESS] $NAME настроен!${NC}"
        echo -e "$PROTO: Вход $IN_PORT -> Выход $TARGET_IP:$OUT_PORT"
        read -p "Нажмите Enter для возврата в меню..."
    fi
}

# --- СПИСОК ПРАВИЛ ---
list_active_rules() {
    echo -e "\n${CYAN}--- Активные переадресации (сохранённые) ---${NC}"
    echo -e "${MAGENTA}ПОРТ (ВХОД)\tПРОТОКОЛ\tЦЕЛЬ (IP:ВЫХОД)\t\tИМЯ${NC}"
    if [ -s "$RULES_FILE" ]; then
        while IFS='|' read -r PROTO IN_PORT OUT_PORT TARGET_IP NAME; do
            [ -z "$PROTO" ] && continue
            local status="${GREEN}активно${NC}"
            if ! rule_exists_in_iptables "$PROTO" "$IN_PORT" "$OUT_PORT" "$TARGET_IP"; then
                status="${RED}слетело!${NC}"
            fi
            echo -e "$IN_PORT\t\t$PROTO\t\t$TARGET_IP:$OUT_PORT\t($NAME) [$status]"
        done < "$RULES_FILE"
    else
        echo -e "${YELLOW}Нет сохранённых правил.${NC}"
    fi
    echo ""
    read -p "Нажмите Enter..."
}

# --- УДАЛЕНИЕ ОДНОГО ПРАВИЛА ---
delete_single_rule() {
    echo -e "\n${CYAN}--- Удаление правила ---${NC}"
    declare -a RULES_LIST
    local i=1

    if [ -s "$RULES_FILE" ]; then
        while IFS='|' read -r PROTO IN_PORT OUT_PORT TARGET_IP NAME; do
            [ -z "$PROTO" ] && continue
            RULES_LIST[$i]="$PROTO|$IN_PORT|$OUT_PORT|$TARGET_IP"
            echo -e "${YELLOW}[$i]${NC} Вход: $IN_PORT ($PROTO) -> Выход: $TARGET_IP:$OUT_PORT ($NAME)"
            ((i++))
        done < "$RULES_FILE"
    fi

    if [ ${#RULES_LIST[@]} -eq 0 ]; then
        echo -e "${RED}Нет активных правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo ""
    read -p "Номер правила для удаления (0 отмена): " rule_num
    if [[ "$rule_num" == "0" || -z "${RULES_LIST[$rule_num]}" ]]; then return; fi

    IFS='|' read -r d_proto d_port d_out_port d_target_ip <<< "${RULES_LIST[$rule_num]}"

    iptables -t nat -D PREROUTING -p "$d_proto" --dport "$d_port" -j DNAT --to-destination "$d_target_ip:$d_out_port" 2>/dev/null
    iptables -D INPUT -p "$d_proto" --dport "$d_port" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$d_proto" -d "$d_target_ip" --dport "$d_out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$d_proto" -s "$d_target_ip" --sport "$d_out_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    netfilter-persistent save > /dev/null

    # Удаляем из файла-бекапа, чтобы восстановление больше не возвращало это правило
    remove_rule_from_file "$d_proto" "$d_port"

    echo -e "${GREEN}[OK] Правило удалено (и больше не будет восстанавливаться).${NC}"
    read -p "Нажмите Enter..."
}

# --- ПОЛНАЯ ОЧИСТКА ---
flush_rules() {
    echo -e "\n${RED}!!! ВНИМАНИЕ !!!${NC}"
    echo "Сброс ВСЕХ настроек iptables и удаление сохранённых правил (восстановление больше не будет их применять)."
    read -p "Вы уверены? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -t nat -F
        iptables -t mangle -F
        iptables -F
        iptables -X
        netfilter-persistent save > /dev/null
        > "$RULES_FILE"
        echo -e "${GREEN}[OK] Очищено.${NC}"
    fi
    read -p "Нажмите Enter..."
}

# --- МЕНЮ ---
show_menu() {
    while true; do
        clear
        echo -e "${MAGENTA}"
        echo "******************************************************"
        echo "       Настройка каскадной переадресации портов"
        echo "******************************************************"
        echo -e "${NC}"

        echo -e "1) Настроить ${CYAN}AmneziaWG / WireGuard${NC} (UDP)"
        echo -e "2) Настроить ${CYAN}VLESS / XRay${NC} (TCP)"
        echo -e "3) Настроить ${CYAN}TProxy / MTProto${NC} (TCP)"
        echo -e "4) 🛠 Создать ${YELLOW}Кастомное правило${NC} (Разные порты, SSH, RDP...)"
        echo -e "5) Посмотреть активные правила"
        echo -e "6) ${RED}Удалить одно правило${NC}"
        echo -e "7) ${RED}Сбросить ВСЕ настройки${NC}"
        echo -e "8) ${MAGENTA}📚 ИНСТРУКЦИЯ (Как настроить)${NC}"
        echo -e "0) Выход"
        echo -e "------------------------------------------------------"
        read -p "Ваш выбор: " choice

        case $choice in
            1) configure_rule "udp" "AmneziaWG" ;;
            2) configure_rule "tcp" "VLESS" ;;
            3) configure_rule "tcp" "MTProto/TProxy" ;;
            4) configure_custom_rule ;;
            5) list_active_rules ;;
            6) delete_single_rule ;;
            7) flush_rules ;;
            8) show_instructions ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- ЗАПУСК ---
check_root

# Режим для systemd-службы: тихо восстановить правила и выйти
if [[ "$1" == "--restore-only" ]]; then
    mkdir -p "$RULES_DIR"
    touch "$RULES_FILE"
    restore_rules "quiet"
    exit 0
fi

prepare_system
restore_rules
show_menu
