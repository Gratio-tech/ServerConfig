#!/usr/bin/env bash

set -e
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/utils.sh"

NGINX_TEMPLATE="$SCRIPT_DIR/configs/nginx_base.conf"

setup_nginx() {
    if command -v nginx >/dev/null 2>&1 && [ -f "$NGINX_TEMPLATE" ]; then
        echo "--- Настройка Nginx ---"
        local attempts=0
        local domain=""

        while [ $attempts -lt 2 ]; do
            read -p "Введите домен (например, example.com) [оставьте пустым для пропуска]: " domain

            # Если пусто — выходим из настройки домена
            if [ -z "$domain" ]; then
                echo "Настройка домена пропущена."
                return 0
            fi

            if validate_domain "$domain"; then
                # Если домен валиден — приступаем к настройке
                target="/etc/nginx/sites-available/$domain"

                # Создаем конфиг из шаблона
                if sed "s/{{DOMAIN}}/$domain/g" "$NGINX_TEMPLATE" > "$target"; then
                    ln -sf "$target" "/etc/nginx/sites-enabled/"
                    rm -f /etc/nginx/sites-enabled/default

                    if nginx -t >/dev/null 2>&1; then
                        systemctl reload nginx
                        echo "Nginx для $domain успешно настроен."
                        return 0
                    else
                        echo "Ошибка в конфиге Nginx. Проверьте вручную."
                        rm -f "/etc/nginx/sites-enabled/$domain"
                        return 1
                    fi
                else
                    echo "Ошибка: не удалось создать файл конфига."
                    return 1
                fi
            else
                attempts=$((attempts + 1))
                if [ $attempts -lt 2 ]; then
                    echo "Ошибка: Некорректный формат домена. Не используйте http:// или специальные символы."
                else
                    echo "Слишком много неудачных попыток. Настройка Nginx пропущена."
                fi
            fi
        done
    fi
}

setup_nginx
