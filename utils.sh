#!/usr/bin/env bash

# Проверка политики файрвола
validate_policy() {
    local input=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$input" in
        allow|a) echo "allow" ;;
        deny|d)  echo "deny"  ;;
        *) return 1 ;;
    esac
}


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

# Проверка домена для настройки Nginx
validate_domain() {
    local domain=$1
    if [[ "$domain" == http* ]]; then
        return 1
    fi
    if [[ "$domain" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
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

# Получение текущего порта SSH из конфига, если база была пропущена
get_current_ssh_port() {
    local port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    echo "${port:-22}"
}
