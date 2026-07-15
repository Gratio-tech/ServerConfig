#!/usr/bin/env bash
set -eu
# set -e остановка при любой ошибке
# set -u завершит скрипт с ошибкой при использовании неопределенной переменной (unset variable).
# предотвращает скрытые ошибки от опечаток или забытых инициализаций, заставляя явно проверять переменные

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
    local port
    port="$(sshd -T 2>/dev/null |
        awk '$1 == "port" { print $2; exit }')" || true
    printf '%s\n' "${port:-22}"
}

shell_quote() {
    # Делает безопасный shell-литерал:
    # hello    -> 'hello'
    # it's ok  -> 'it'\''s ok'
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}
