#!/usr/bin/env bash

# Остановка при любой ошибке
set -e
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TIMEZONE="Europe/Moscow"
export NEW_SSH_PORT=8777 # Дефолт, если пропустим настройку
export SSH_SERV="ssh" # На Debian/Ubuntu обычно ssh
if systemctl list-unit-files | grep -q "^sshd.service"; then
    SSH_SERV="sshd"
fi

# Подгружаем утилиты из подпапки
if [ -f "$SCRIPT_DIR/utils.sh" ]; then
    source "$SCRIPT_DIR/utils.sh"
else
    echo "Критическая ошибка: $SCRIPT_DIR/utils.sh не найден."
    exit 1
fi


remote_deploy() {
    read -p "Введите IP сервера: " REMOTE_IP
    read -p "Введите текущий порт SSH [22]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    read -p "Введите пользователя [root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    # Создаем папку с уникальным именем на сервере
    REMOTE_DIR="~/deploy_$(date +%Y%m%d_%H%M)"

    echo "Копирование файлов проекта на $REMOTE_IP..."
    ssh -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" "mkdir -p $REMOTE_DIR"

    # Рекурсивное копирование всей папки (включая configs/)
    scp -P "$REMOTE_PORT" -r "$SCRIPT_DIR"/* "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"

    echo "Запуск скрипта на удаленном сервере..."
    # Опция -t нужна для интерактивности внутри SSH
    ssh -t -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" "cd $REMOTE_DIR && chmod +x *.sh && sudo ./deploy.sh"
    exit 0
}

# --- Проверка флага remote ---
if [[ "$1" == "-remote" ]]; then
    remote_deploy
fi

if [ "$EUID" -ne 0 ]; then echo "Требуются права root"; exit 1; fi

setup_base() {
    echo "----- Базовая настройка ОС -----"

    while [ -z "$NEW_HOSTNAME" ]; do
        read -p "Введите имя хоста (hostname): " NEW_HOSTNAME
    done

    while true; do
        read -p "Введите порт SSH [1-65535, default: 8777]: " input_port
        input_port=${input_port:-8769}
        if validate_range "$input_port" 1 65535; then
            export NEW_SSH_PORT=$input_port
            break
        else
            echo "Ошибка: введите число от 1 до 65535."
        fi
    done

    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/127.0.1.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
    timedatectl set-timezone "$TIMEZONE"

    # Настройка sshd_config
    local ssh_conf="/etc/ssh/sshd_config"

    # Порт
    sed -i "s/^#Port 22/Port $NEW_SSH_PORT/" "$ssh_conf"
    sed -i "s/^Port .*/Port $NEW_SSH_PORT/" "$ssh_conf"

    # Безопасность и таймауты
    # Сначала удаляем существующие вхождения, чтобы не плодить дубли
    sed -i '/^MaxAuthTries/d; /^ClientAliveInterval/d; /^ClientAliveCountMax/d' "$ssh_conf"
    {
        echo "MaxAuthTries 3"
        echo "ClientAliveInterval 40"
        echo "ClientAliveCountMax 5"
    } >> "$conf"
}

setup_swap() {
    if ask_yn "Настроить Swap-файл (1GB) и Swappiness?" "y"; then
        echo "----- Настройка Swap -----"
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
    echo "----- Настройка логов -----"
    CONF="/etc/systemd/journald.conf"
    sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=1G/' $CONF
    sed -i 's/^#MaxRetentionSec=.*/MaxRetentionSec=60d/' $CONF
    systemctl restart systemd-journald
    journalctl --vacuum-size=512M --vacuum-time=60d
}

disable_ipv6() {
    echo "----- Отключение IPv6 -----"
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
    echo "----- Установка Certbot через Snap -----"

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

install_nginx() {
    echo "----- Установка актуальной версии Nginx -----"
    if ! [ -f /etc/apt/sources.list.d/nginx.list ]; then
        curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
            | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
        http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
            | sudo tee /etc/apt/sources.list.d/nginx.list

        apt update
    fi
    apt install -y nginx
}

install_packages() {
    echo "----- Установка пакетов -----"
    apt update && apt upgrade -y

    # Инициализируем переменную (добавь эту строку)
    export INSTALLED_DOCKER="false"

    for pkg in nginx docker unzip certbot net-tools fail2ban nvm; do
        if ask_yn "Установить $pkg?" "n"; then
            if [ "$pkg" == "nvm" ]; then
                curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
            elif [ "$pkg" == "nginx" ]; then
                  install_nginx
            elif [ "$pkg" == "certbot" ]; then
                install_certbot
            elif [ "$pkg" == "docker" ]; then
                # Добавляем установку флага (изменение здесь)
                curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh && rm get-docker.sh
                export INSTALLED_DOCKER="true"
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

if ask_yn "Выполнить базовую настройку (Hostname, SSH, Swap, IPv6 disable, Packages)?" "y"; then
    setup_base
    setup_swap
    setup_journald
    disable_ipv6
    install_packages
fi

if ask_yn "Настроить Nginx?" "y"; then
    bash "$SCRIPT_DIR/setup_nginx.sh"
fi

if ask_yn "Настроить Файрвол?" "y"; then
    bash "$SCRIPT_DIR/setup_firewall.sh"

    echo "Проверка конфигурации SSH..."
    if sshd -t; then
        echo "Перезапуск сервиса $SSH_SERV на порту $NEW_SSH_PORT..."
        systemctl restart "$SSH_SERV"
    else
        echo "КРИТИЧЕСКАЯ ОШИБКА: Конфиг SSH поврежден. Перезапуск отменен."
        exit 1
    fi

    # Если Docker был установлен или уже есть в системе, перезапускаем его,
    # чтобы он восстановил свои правила iptables поверх правил UFW/Firewalld.
    if [ "$INSTALLED_DOCKER" == "true" ] || command -v docker >/dev/null 2>&1; then
        echo "Перезапуск Docker для восстановления сетевых мостов..."
        systemctl restart docker
    fi
fi

echo "Настройка завершена."

if ask_yn "Удалить временные файлы установки?" "n"; then
    rm -rf "$SCRIPT_DIR"
    echo "Директория удалена."
fi
