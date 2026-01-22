#!/bin/bash

# Остановка при любой ошибке
set -e

# --- Переменные ---
FW_CONFIG="firewall.conf"
NGINX_TEMPLATE="nginx_base.conf"
TIMEZONE="Europe/Moscow"

# --- Вспомогательные функции для валидации ввода ---

# Проверка, является ли ввод числом в заданном диапазоне
validate_range() {
    local val=$1
    local min=$2
    local max=$3
    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge "$min" ] && [ "$val" -le "$max" ]; then
        return 0
    else
        return 1
    fi
}

# Проверка политики файрвола
validate_policy() {
    local input=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$input" in
        allow|a) echo "allow" ;;
        deny|d)  echo "deny"  ;;
        *) return 1 ;;
    esac
}

# Универсальный запрос Y/N
ask_yn() {
    local prompt=$1
    local default=$2
    read -p "$prompt [$default]: " yn
    yn=${yn:-$default}
    case $yn in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Основные функции ---

setup_base() {
    echo "--- Базовая настройка ОС ---"

    while [ -z "$NEW_HOSTNAME" ]; do
        read -p "Введите имя хоста (hostname): " NEW_HOSTNAME
    done

    while true; do
        read -p "Введите порт SSH [1-65535, default: 8769]: " input_port
        input_port=${input_port:-8769}
        if validate_range "$input_port" 1 65535; then
            NEW_SSH_PORT=$input_port
            break
        else
            echo "Ошибка: введите число от 1 до 65535."
        fi
    done

    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/127.0.1.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
    timedatectl set-timezone "$TIMEZONE"

    sed -i "s/^#Port 22/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
    sed -i "s/^Port .*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
    systemctl restart ssh
}

setup_swap() {
    if ask_yn "Настроить Swap-файл (1GB) и Swappiness?" "y"; then
        echo "--- Настройка Swap ---"
        echo "Параметр swappiness определяет интенсивность использования подкачки:"
        echo "0 — свопинг почти отключён (система будет свопить только в крайнем случае)."
        echo "100 — максимально агрессивный свопинг (ядро начнёт выгружать даже при наличии свободной RAM)."
        echo "По умолчанию обычно 60. Назначение: баланс между использованием RAM для кэша и предотвращением OOM-killer."

        local sw_val
        while true; do
            read -p "Введите значение swappiness (0-100) [default: 15]: " sw_val
            sw_val=${sw_val:-15}
            if validate_range "$sw_val" 0 100; then
                break
            else
                echo "Ошибка: введите число от 0 до 100."
            fi
        done

        if [ ! -f /swapfile ]; then
            fallocate -l 1G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi

        sysctl -w vm.swappiness="$sw_val"
        sed -i '/vm.swappiness/d' /etc/sysctl.conf
        echo "vm.swappiness=$sw_val" >> /etc/sysctl.conf
        echo "Swap настроен (swappiness=$sw_val)."
    fi
}

setup_journald() {
    echo "--- Настройка логов ---"
    CONF="/etc/systemd/journald.conf"
    sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=1G/' $CONF
    sed -i 's/^#MaxRetentionSec=.*/MaxRetentionSec=60d/' $CONF
    systemctl restart systemd-journald
    journalctl --vacuum-size=512M --vacuum-time=60d
}

disable_ipv6() {
    echo "--- Отключение IPv6 ---"
    cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl --system

    if [ -f /etc/default/grub ]; then
        if ! grep -q "ipv6.disable=1" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
            update-grub
        fi
    fi
}

install_certbot() {
    echo "--- Установка Certbot через Snap ---"

    # Проверка и установка snapd
    if ! command -v snap >/dev/null 2>&1; then
        apt update && apt install -y snapd
    fi

    # Необходимая инициализация для snap на некоторых системах
    systemctl enable --now snapd.socket

    # Установка core
    snap install core || snap refresh core

    # Удаление старых apt-версий, если они были
    apt remove -y certbot || true

    # Установка Certbot
    snap install --classic certbot

    # Создание симлинка (проверка на существование, чтобы не выбило ошибку)
    if [ ! -f /usr/bin/certbot ]; then
        ln -s /snap/bin/certbot /usr/bin/certbot
    fi
}

install_packages() {
    echo "--- Установка пакетов ---"
    apt update && apt upgrade -y

    for pkg in certbot nginx docker net-tools fail2ban nvm; do
        if ask_yn "Установить $pkg?" "n"; then
            if [ "$pkg" == "nvm" ]; then
                curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
            elif [ "$pkg" == "certbot" ]; then
                install_certbot
            elif [ "$pkg" == "docker" ]; then
                curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh && rm get-docker.sh
            elif [ "$pkg" == "fail2ban" ]; then
                apt install -y fail2ban
                cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $NEW_SSH_PORT
EOF
                systemctl restart fail2ban
            else
                apt install -y "$pkg"
            fi
        fi
    done
}

setup_nginx() {
    if command -v nginx >/dev/null 2>&1 && [ -f "$NGINX_TEMPLATE" ]; then
        read -p "Введите домен для Nginx (или оставьте пустым для пропуска): " domain
        if [ -n "$domain" ]; then
            target="/etc/nginx/sites-available/$domain"
            sed "s/{{DOMAIN}}/$domain/g" "$NGINX_TEMPLATE" > "$target"
            ln -sf "$target" "/etc/nginx/sites-enabled/"
            rm -f /etc/nginx/sites-enabled/default
            nginx -t && systemctl reload nginx
        fi
    fi
}

setup_firewall() {
    echo "--- Настройка файрвола ---"

    # ... (здесь блок запроса POLICY_IN / POLICY_OUT из прошлого шага) ...

    if command -v ufw >/dev/null 2>&1; then
        FW_TOOL="ufw"
        ufw --force reset

        # 1. Настройка ICMP в UFW (правка конфига before.rules)
        # По умолчанию UFW разрешает пинг. Нам нужно заменить ACCEPT на DROP для echo-request.
        sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules

        # Разрешаем нужные типы ICMP (обычно они уже там есть, но для гарантии)
        # UFW по умолчанию содержит правила для destination-unreachable и др. в before.rules

        ufw default "$POLICY_IN" incoming
        ufw default "$POLICY_OUT" outgoing
        ufw allow "$NEW_SSH_PORT/tcp"

    elif command -v firewall-cmd >/dev/null 2>&1; then
        FW_TOOL="firewalld"
        systemctl start firewalld

        # 2. Настройка ICMP в Firewalld
        # Блокируем эхо-запрос
        firewall-cmd --permanent --add-icmp-block=echo-request
        # Разрешаем остальное (обычно разрешено, но фиксируем)
        for t in destination-unreachable time-exceeded parameter-problem; do
            firewall-cmd --permanent --add-icmp-block-inversion # инверсия, чтобы разрешить только выбранные
            # Или проще: firewalld по умолчанию не блокирует их, если не включен icmp-block-all
        done

        if [ "$POLICY_IN" == "deny" ]; then
            firewall-cmd --set-default-zone=drop
        else
            firewall-cmd --set-default-zone=public
        fi
        firewall-cmd --permanent --add-port="$NEW_SSH_PORT/tcp"
    fi

    # 3. Применение правил из firewall.conf (твой цикл парсинга)
    if [ -f "$FW_CONFIG" ]; then
        while IFS='|' read -r action direction port_proto || [ -n "$action" ]; do
            [[ "$action" =~ ^#.* ]] || [ -z "$action" ] && continue
            if [ "$FW_TOOL" == "ufw" ]; then
                ufw "$action" "$direction" "$port_proto"
            else
                [ "$direction" == "in" ] && [ "$action" == "allow" ] && firewall-cmd --permanent --add-port="$port_proto"
            fi
        done < "$FW_CONFIG"
    fi

    # Активация
    [ "$FW_TOOL" == "ufw" ] && ufw --force enable || firewall-cmd --reload
}

# --- Исполнение ---

if [ "$EUID" -ne 0 ]; then echo "Требуются права root"; exit 1; fi

setup_base
setup_swap
setup_journald
disable_ipv6
install_packages
setup_nginx
setup_firewall

echo "Настройка завершена успешно."

if ask_yn "Удалить файлы установки и папку config?" "n"; then
    # Определяем реальный путь к папке, где лежит скрипт
    SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

    # Удаляем файлы конфигов, чтобы не мешались при удалении папки
    rm -f "$SCRIPT_DIR/$FW_CONFIG" "$SCRIPT_DIR/$NGINX_TEMPLATE"

    # Проверяем, что мы находимся в папке config
    if [[ "$SCRIPT_DIR" == *"/config" ]]; then
        echo "Удаление рабочей директории: $SCRIPT_DIR"
        # Удаляем скрипт и саму папку
        # Используем конструкцию, чтобы bash не ругался на удаление запущенного файла
        rm -rf "$SCRIPT_DIR"
        echo "Папка ~/config и файлы удалены."
    else
        # Если запустили из другого места — удаляем только скрипт и конфиги
        rm -f "$SCRIPT_DIR/$FW_CONFIG" "$SCRIPT_DIR/$NGINX_TEMPLATE"
        rm -- "$0"
        echo "Файлы удалены, папка не тронута (не /config)."
    fi
fi
