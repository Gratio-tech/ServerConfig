#!/usr/bin/env bash

set -e
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

if [ -f "$SCRIPT_DIR/utils.sh" ]; then
    source "$SCRIPT_DIR/utils.sh"
else
    echo "Критическая ошибка: $SCRIPT_DIR/utils.sh не найден."
    exit 1
fi

NGINX_CONF="/etc/nginx/nginx.conf"
MAIN_TEMPLATE="$SCRIPT_DIR/configs/nginx.conf"
SITE_TEMPLATE="$SCRIPT_DIR/configs/site_base.conf"

# Функция для безопасного применения настроек
apply_nginx_changes() {
    if nginx -t >/dev/null 2>&1; then
        # Включаем автозапуск, если еще не включен
        systemctl enable nginx --quiet

        # Если запущен — релоадим, если нет — стартуем
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx
            echo "Конфигурация Nginx обновлена (reload)."
        else
            systemctl start nginx
            echo "Nginx успешно запущен (start)."
        fi
        return 0
    else
        echo "Ошибка в синтаксисе конфига Nginx! Проверьте логи: nginx -t"
        return 1
    fi
}

setup_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        echo "Ошибка: Nginx не установлен."
        return 1
    fi

    echo "----- Очистка дефолтов и настройка Nginx -----"

    # 1. Тотальная зачистка мусора
    rm -rf /etc/nginx/conf.d/*
    rm -rf /etc/nginx/sites-available
    rm -rf /etc/nginx/sites-enabled

    if ask_yn "Удалить дефолтную директорию /var/www (если не нужна статика)?" "y"; then
        [ -d "/var/www" ] && rm -rf /var/www
        echo "Директория /var/www удалена, не забудьте поправить конфиг сайта"
    fi

    # 2. Применяем основной конфиг (UA, Logs, etc.)
    if [ -f "$MAIN_TEMPLATE" ]; then
        cp "$MAIN_TEMPLATE" "$NGINX_CONF"
        echo "Основной файл $NGINX_CONF обновлен."
    else
        echo "Ошибка: Шаблон $MAIN_TEMPLATE не найден."
        return 1
    fi

    # 3. Цикл добавления сайтов
    while true; do
        echo "--------------------------------------"
        read -p "Введите домен (оставьте пустым для завершения): " domain

        if [ -z "$domain" ]; then
            # Даже если сайты не добавляли, нужно применить изменения основного конфига
            apply_nginx_changes
            echo "Добавление сайтов завершено."
            break
        fi

        if validate_domain "$domain"; then
            target="/etc/nginx/conf.d/$domain.conf"

            if [ ! -f "$SITE_TEMPLATE" ]; then
                echo "Ошибка: Шаблон сайта $SITE_TEMPLATE не найден."
                return 1
            fi

            # Создаем конфиг из шаблона
            sed "s/{{DOMAIN}}/$domain/g" "$SITE_TEMPLATE" > "$target"

            # Проверяем и применяем
            if ! apply_nginx_changes; then
                echo "Откатываю изменения для $domain..."
                rm -f "$target"
                apply_nginx_changes # Возвращаем рабочее состояние
            else
                echo "Сайт $domain успешно настроен."
            fi
        else
            echo "Ошибка: Некорректный формат домена '$domain'. Попробуй еще раз."
        fi
    done

    echo "----- Настройка Nginx завершена -----"
}

setup_nginx
