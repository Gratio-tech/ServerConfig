#!/usr/bin/env bash
set -eu
# set -e остановка при любой ошибке
# set -u завершит скрипт с ошибкой при использовании неопределенной переменной (unset variable).
# предотвращает скрытые ошибки от опечаток или забытых инициализаций, заставляя явно проверять переменные

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TIMEZONE="Europe/Moscow"
MOTD_TEMPLATE="$SCRIPT_DIR/custom-motd.sh"

export NEW_SSH_PORT=8777 # Дефолт, если пропустим настройку
export SSH_SERV="ssh" # На Debian/Ubuntu обычно ssh

# Подгружаем утилиты из подпапки
if [ -f "$SCRIPT_DIR/utils.sh" ]; then
    source "$SCRIPT_DIR/utils.sh"
else
    echo "Критическая ошибка: $SCRIPT_DIR/utils.sh не найден."
    exit 1
fi

detect_ssh_service() {
    SSH_SERV="ssh"

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    if systemctl list-unit-files sshd.service 2>/dev/null | grep -q '^sshd.service'; then
        SSH_SERV="sshd"
    elif systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh.service'; then
        SSH_SERV="ssh"
    fi

    export SSH_SERV
}

restart_ssh_service() {
    echo "Проверка конфигурации SSH..."

    local sshd_bin
    sshd_bin="$(command -v sshd || echo /usr/sbin/sshd)"

    if "$sshd_bin" -t; then
        detect_ssh_service
        echo "Перезапуск сервиса $SSH_SERV на порту $NEW_SSH_PORT..."
        systemctl restart "$SSH_SERV"
    else
        echo "КРИТИЧЕСКАЯ ОШИБКА: конфиг SSH поврежден. Перезапуск отменен."
        exit 1
    fi
}

remote_deploy() {
    read -p "Введите IP сервера: " REMOTE_IP
    read -p "Введите текущий порт SSH на сервере [по дефолту 22]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    read -p "Введите пользователя [root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    # Создаем папку с уникальным именем на сервере
    REMOTE_DIR="~/deploy_$(date +%Y%m%d_%H%M)"

    echo "Копирование файлов проекта на $REMOTE_IP..."
    ssh -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" "mkdir -p $REMOTE_DIR"

    # Рекурсивное копирование всей папки (включая configs/)
    scp -P "$REMOTE_PORT" -r "$SCRIPT_DIR"/* "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"

    # На всякий случай заменяем CRLF во всех файлах, если такие были после обновления скрипта
    ssh -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" "
        cd $REMOTE_DIR &&
        find . -type f \( -name '*.sh' -o -name '*.conf' \) -exec sed -i 's/\r$//' {} +
    "

    echo "Запуск скрипта на удаленном сервере..."
    # Опция -t нужна для интерактивности внутри SSH
    local remote_run_cmd
    if [ "$REMOTE_USER" = "root" ]; then
        remote_run_cmd="bash ./deploy.sh"
    else
        remote_run_cmd="sudo bash ./deploy.sh"
    fi
    ssh -t -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" "cd $REMOTE_DIR && chmod +x *.sh && $remote_run_cmd"
    exit 0
}

# --- Проверка флага remote и рут-прав ---
if [ "${#}" -ge 1 ]; then
    case "$1" in
        -remote|--remote|-r|--r)
            remote_deploy
            ;;
    esac
fi

if [ "$EUID" -ne 0 ]; then echo "Требуются права root"; exit 1; fi

detect_ssh_service

setup_base() {
    echo "----- Базовая настройка ОС -----"

    NEW_HOSTNAME=""
    while [ -z "$NEW_HOSTNAME" ]; do
        read -p "Введите имя хоста (hostname): " NEW_HOSTNAME
    done

    while true; do
        read -p "Введите новый порт SSH [1-65535, default: 8777]: " input_port
        input_port=${input_port:-8777}
        if validate_range "$input_port" 1 65535; then
            export NEW_SSH_PORT=$input_port
            break
        else
            echo "Ошибка: введите число от 1 до 65535."
        fi
    done

    hostnamectl set-hostname "$NEW_HOSTNAME"

    if ! grep -q "127.0.1.1" /etc/hosts; then
        echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
    else
        sed -i "s/127.0.1.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
    fi

    timedatectl set-timezone "$TIMEZONE"

    # Настройка sshd_config
    local ssh_conf="/etc/ssh/sshd_config"

    # Очищаем старые записи порта (как закомментированные, так и нет)
    # и дублирующиеся параметры, игнорируя пробелы в начале строк.
    sed -i '/^[[:space:]]*#\?Port[[:space:]]/d' "$ssh_conf"
    sed -i '/^[[:space:]]*MaxAuthTries/d' "$ssh_conf"
    sed -i '/^[[:space:]]*ClientAliveInterval/d' "$ssh_conf"
    sed -i '/^[[:space:]]*ClientAliveCountMax/d' "$ssh_conf"

    # Безопасное добавление настроек в начало файла.
    # Это исключает проблему склеивания строк без EOF-переноса
    # и гарантирует, что параметры не окажутся внутри блока Match в конце файла.
    {
        echo "Port $NEW_SSH_PORT"
        echo "MaxAuthTries 3"
        echo "ClientAliveInterval 40"
        echo "ClientAliveCountMax 5"
        cat "$ssh_conf"
    } > "${ssh_conf}.tmp" && mv "${ssh_conf}.tmp" "$ssh_conf"

    chmod 644 "$ssh_conf"
    # Ребутим SSH для применения порта
    restart_ssh_service
}

remove_old_users() {
    # Удаляем исторических юзеров, которые не используются в современных системах:
    # Только если юзер существует
    for user in games lp uucp news; do
        if getent passwd "$user" >/dev/null; then
            # Здесь, возможно, придётся добавить sudo перед userdel
            # Но скрипт должен выполняться от root
            userdel -r "$user" || true
        fi
    done
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
            grep -qF '/swapfile none swap sw 0 0' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi

        local swappiness_conf="/etc/sysctl.d/99-serverconfig-swappiness.conf"
        install -d -m 0755 /etc/sysctl.d
        printf 'vm.swappiness = %s\n' "$sw_val" > "$swappiness_conf"
        sysctl -p "$swappiness_conf"
        echo "Swap настроен (swappiness=$sw_val)."
    fi
}

setup_journald() {
    echo "----- Настройка логов -----"
    install -d -m 0755 /etc/systemd/journald.conf.d

    cat > /etc/systemd/journald.conf.d/99-serverconfig.conf <<'EOF'
[Journal]
SystemMaxUse=1G
MaxRetentionSec=60d
EOF

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

select_cheats_language() {
    echo "----- Выбор языка подсказок cheat -----"
    echo "Доступные языки:"
    echo "  ru — русский"

    read -p "Введите код языка подсказок [ru]: " CHEATS_LANGUAGE
    CHEATS_LANGUAGE=${CHEATS_LANGUAGE:-ru}

    case "$CHEATS_LANGUAGE" in
        ru)
            ;;
        *)
            echo "Язык '$CHEATS_LANGUAGE' пока не поддерживается. Использую ru."
            CHEATS_LANGUAGE="ru"
            ;;
    esac

    export CHEATS_LANGUAGE
}

install_cheat() {
    echo "----- Установка cheat -----"

    if ! command -v cheat >/dev/null 2>&1; then
        local arch cheat_arch tmp_gz tmp_bin
        arch="$(dpkg --print-architecture)"

        case "$arch" in
            amd64)
                cheat_arch="amd64"
                ;;
            i386)
                cheat_arch="386"
                ;;
            arm64)
                cheat_arch="arm64"
                ;;
            armhf)
                cheat_arch="arm7"
                ;;
            armel)
                cheat_arch="arm5"
                ;;
            *)
                echo "Критическая ошибка: архитектура '$arch' не поддерживается установщиком cheat."
                return 1
                ;;
        esac

        apt install -y ca-certificates curl gzip less

        tmp_gz="/tmp/cheat-linux-${cheat_arch}.gz"
        tmp_bin="/tmp/cheat-linux-${cheat_arch}"

        curl -fsSL \
            -o "$tmp_gz" \
            "https://github.com/cheat/cheat/releases/latest/download/cheat-linux-${cheat_arch}.gz"

        gzip -dc "$tmp_gz" > "$tmp_bin"
        chmod +x "$tmp_bin"
        mv "$tmp_bin" /usr/local/bin/cheat
        rm -f "$tmp_gz"
    else
        echo "cheat уже установлен: $(cheat --version 2>/dev/null || true)"
    fi

    select_cheats_language

    local source_dir target_dir
    source_dir="$SCRIPT_DIR/cheatsheets/$CHEATS_LANGUAGE"
    target_dir="/usr/local/share/cheat/serverconfig/$CHEATS_LANGUAGE"

    if [ ! -d "$source_dir" ]; then
        echo "Критическая ошибка: каталог подсказок не найден: $source_dir"
        return 1
    fi

    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    cp -a "$source_dir/." "$target_dir/"
    chmod -R a+rX /usr/local/share/cheat

    mkdir -p /etc/cheat
    cat <<EOF > /etc/cheat/conf.yml
---
editor: nano
colorize: true
style: monokai
formatter: terminal256
pager: less -FRX

cheatpaths:
  - name: serverconfig-$CHEATS_LANGUAGE
    path: $target_dir
    tags: [ serverconfig, $CHEATS_LANGUAGE ]
    readonly: true
EOF

    cat <<'EOF' > /etc/profile.d/serverconfig-cheat.sh
export CHEAT_CONFIG_PATH=/etc/cheat/conf.yml
EOF
    chmod 0644 /etc/profile.d/serverconfig-cheat.sh
    export CHEAT_CONFIG_PATH=/etc/cheat/conf.yml

    echo "cheat настроен. Проверка: cheat nginx"
}


setup_fail2ban() {
    echo "----- Настройка fail2ban -----"

    apt install -y fail2ban
    mkdir -p /etc/fail2ban/jail.d

    cat <<EOF > /etc/fail2ban/jail.d/sshd.local
[DEFAULT]
# 5 неудачных попыток за findtime => бан на bantime.
maxretry = 5
findtime = 10m
bantime = 1h

# Повторные баны становятся длиннее, но не больше 1 дня.
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1d

[sshd]
enabled = true
port = $NEW_SSH_PORT
backend = auto
EOF

    if fail2ban-client -t; then
        systemctl enable --now fail2ban
        systemctl restart fail2ban
        fail2ban-client status sshd || true
    else
        echo "КРИТИЧЕСКАЯ ОШИБКА: конфиг fail2ban некорректен."
        exit 1
    fi
}

setup_motd() {
    echo "----- Настройка SSH MOTD -----"

    local target custom_text quoted_text escaped_text

    target="/etc/update-motd.d/00-header"

    if [ ! -f "$MOTD_TEMPLATE" ]; then
        echo "Критическая ошибка: шаблон MOTD не найден: $MOTD_TEMPLATE"
        return 1
    fi

    read -r -p "Введите кастомный текст для MOTD [Enter — без кастомного блока]: " custom_text

    install -d -m 0755 /etc/update-motd.d

    if [ -n "$custom_text" ]; then
        quoted_text="$(shell_quote "$custom_text")"
        escaped_text="$(printf '%s' "$quoted_text" | sed -e 's/[\/&\\]/\\&/g')"

        sed "s/CUSTOM_USER_TEST/$escaped_text/g" "$MOTD_TEMPLATE" > "$target"
    else
        awk '
            /^# __CUSTOM_USER_BLOCK_START__$/ { skip = 1; next }
            /^# __CUSTOM_USER_BLOCK_END__$/ { skip = 0; next }
            !skip { print }
        ' "$MOTD_TEMPLATE" > "$target"
    fi

    chmod 0755 "$target"

    find /etc/update-motd.d -mindepth 1 -maxdepth 1 \
        ! -name "$(basename "$target")" \
        \( -type f -o -type l \) \
        -exec rm -f -- {} +

    rm -f /etc/motd
    touch /etc/motd
    chmod 0644 /etc/motd

    echo "MOTD настроен: $target"
}

install_packages() {
    echo "----- Установка пакетов -----"
    apt update && apt upgrade -y
    apt install -y net-tools

    for pkg in nginx docker unzip certbot fail2ban nvm cheat; do
        if ask_yn "Установить $pkg?" "n"; then
            if [ "$pkg" == "nvm" ]; then
                curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh | bash
            elif [ "$pkg" == "nginx" ]; then
                  install_nginx
            elif [ "$pkg" == "certbot" ]; then
                install_certbot
            elif [ "$pkg" == "cheat" ]; then
                install_cheat
            elif [ "$pkg" == "docker" ]; then
                curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh && rm get-docker.sh

                # Создаем пустой JSON объект с настройками демона (часто нужно для DNS внутри контейнера)
                # Важно: это перезаписывает существующий /etc/docker/daemon.json.
                mkdir -p /etc/docker
                echo "Для Docker daemon будут установлены DNS 8.8.8.8 и 1.1.1.1"
                echo '{ "dns": ["8.8.8.8", "1.1.1.1"] }' > /etc/docker/daemon.json
                systemctl restart docker
            elif [ "$pkg" == "fail2ban" ]; then
                setup_fail2ban
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
    if ask_yn "Отключить IPv6?" "y"; then
        disable_ipv6
    fi
    if ask_yn "Удалить неиспользуемых юзеров (games, uucp и юзер для печати lp)?" "y"; then
        remove_old_users
    fi
    install_packages
fi

if ask_yn "Обновить стандартное приветствие SSH MOTD?" "y"; then
    setup_motd
fi


if ask_yn "Настроить Nginx?" "y"; then
    bash "$SCRIPT_DIR/setup_nginx.sh"
fi

if ask_yn "Настроить Файрвол?" "y"; then
    bash "$SCRIPT_DIR/setup_firewall.sh"

    # Если Docker был установлен или уже есть в системе, перезапускаем его,
    # чтобы он восстановил свои правила iptables поверх правил UFW/Firewalld.
    if command -v docker >/dev/null 2>&1; then
        echo "Перезапуск Docker для восстановления сетевых мостов..."
        systemctl restart docker
    fi
fi

echo "Настройка завершена."

if ask_yn "Удалить временные файлы установки?" "n"; then
    rm -rf "$SCRIPT_DIR"
    echo "Директория удалена."
fi
