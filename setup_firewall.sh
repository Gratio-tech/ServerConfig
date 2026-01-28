#!/usr/bin/env bash

#!/usr/bin/env bash
set -e
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/utils.sh"

FW_CONFIG="$SCRIPT_DIR/configs/firewall.conf"

setup_docker_support() {
    local tool=$1
    echo "----- Настройка специфики Docker для $tool -----"

    if [ "$tool" == "ufw" ]; then
        # 1. Разрешаем Forwarding (критично для Docker)
        sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

        # 2. Разрешаем трафик с интерфейса Docker (docker0)
        ufw route allow in on docker0
        ufw route allow out on docker0

        # 3. Дополнительно: Разрешаем трафик для всех подсетей Docker (для GitLab Runner).
        # GitLab Runner создает динамические мосты (br-xxx), а не использует только docker0.
        # Обычно Docker использует подсети из диапазона 172.16.0.0/12.
        # Разрешаем маршрутизацию из этих подсетей в любую точку.
        ufw route allow from 172.16.0.0/12 to any
        ufw route allow from any to 172.16.0.0/12

    elif [ "$tool" == "firewalld" ]; then
        # Firewalld обычно работает через зоны
        firewall-cmd --permanent --zone=public --add-masquerade

        # Добавляем docker0 в доверенные
        firewall-cmd --permanent --zone=trusted --add-interface=docker0

        # Для GitLab Runner и динамических сетей в firewalld сложнее заранее узнать имя интерфейса.
        # Добавляем весь диапазон IP docker-сетей в trusted source.
        firewall-cmd --permanent --zone=trusted --add-source=172.16.0.0/12
    fi
}

setup_firewall() {
    echo "----- Настройка файрвола -----"

    local p_in p_out
    while true; do
        read -p "Входящий трафик (allow/a или deny/d) [deny]: " p_in
        p_in=${p_in:-deny}
        if POLICY_IN=$(validate_policy "$p_in"); then break; else echo "Ошибка: введите 'a' или 'd'"; fi
    done

    while true; do
        read -p "Исходящий трафик (allow/a или deny/d) [allow]: " p_out
        p_out=${p_out:-allow}
        if POLICY_OUT=$(validate_policy "$p_out"); then break; else echo "Ошибка: введите 'a' или 'd'"; fi
    done

    NEW_SSH_PORT=$(get_current_ssh_port)

    if command -v ufw >/dev/null 2>&1; then
        FW_TOOL="ufw"
        ufw --force reset
        sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules
        ufw default "$POLICY_IN" incoming
        ufw default "$POLICY_OUT" outgoing
        ufw allow "$NEW_SSH_PORT/tcp"

        if [ "$INSTALLED_DOCKER" == "true" ] || command -v docker >/dev/null 2>&1; then
            setup_docker_support "ufw"
        fi

    elif command -v firewall-cmd >/dev/null 2>&1; then
        FW_TOOL="firewalld"
        systemctl start firewalld
        firewall-cmd --permanent --add-icmp-block=echo-request
        [ "$POLICY_IN" == "deny" ] && firewall-cmd --set-default-zone=drop || firewall-cmd --set-default-zone=public
        firewall-cmd --permanent --add-port="$NEW_SSH_PORT/tcp"

        if [ "$INSTALLED_DOCKER" == "true" ] || command -v docker >/dev/null 2>&1; then
            setup_docker_support "firewalld"
        fi
    fi

    if [ -f "$FW_CONFIG" ]; then
        while IFS='|' read -r action direction port_proto || [ -n "$action" ]; do
            [[ "$action" =~ ^#.* ]] || [ -z "$action" ] && continue
            if [ "$FW_TOOL" == "ufw" ]; then
                ufw "$action" "$direction" "$port_proto"
            else
                [ "$direction" == "in" ] && [ "$action" == "allow" ] && firewall-cmd --permanent --add-port="$port_proto"
                [ "$direction" == "out" ] && [ "$action" == "allow" ] && echo "Предупреждение: firewalld out rules требуют прямой настройки rich rules, пропущено: $port_proto"
            fi
        done < "$FW_CONFIG"
    fi

    [ "$FW_TOOL" == "ufw" ] && ufw --force enable || firewall-cmd --reload
    echo "Файрвол настроен (IN: $POLICY_IN, OUT: $POLICY_OUT)."
}

setup_firewall
