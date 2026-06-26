#!/bin/sh

if [ -t 1 ]; then
    CYAN="$(printf '\033[36m')"
    RESET="$(printf '\033[0m')"
else
    CYAN=""
    RESET=""
fi

cyan() {
    printf '%s%s%s' "$CYAN" "$1" "$RESET"
}

get_os_name() {
    if command -v lsb_release >/dev/null 2>&1; then
        lsb_release -ds 2>/dev/null && return
    fi

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${PRETTY_NAME:-Linux}"
        return
    fi

    uname -s
}

get_default_iface() {
    ip route show default 2>/dev/null | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

get_ipv4() {
    iface="$1"
    if [ -n "$iface" ]; then
        ip -4 addr show "$iface" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }'
        return
    fi

    hostname -I 2>/dev/null | awk '{ print $1 }'
}

get_ssh_port() {
    if command -v sshd >/dev/null 2>&1; then
        port="$(sshd -T 2>/dev/null | awk 'tolower($1) == "port" { print $2; exit }')"
        if [ -n "$port" ]; then
            printf '%s\n' "$port"
            return
        fi
    fi

    awk '$1 == "Port" { print $2; exit }' /etc/ssh/sshd_config 2>/dev/null || true
}

OS_NAME="$(get_os_name)"
LOAD_1="$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)"
PROC_COUNT="$(ps -e 2>/dev/null | awk 'NR > 1 { count++ } END { print count + 0 }')"
ROOT_USAGE="$(df -h / 2>/dev/null | awk 'NR == 2 { print $5 " of " $2 }')"
LOGGED_USERS="$(who 2>/dev/null | wc -l | awk '{ print $1 }')"
MEM_USAGE="$(free -m 2>/dev/null | awk 'NR == 2 && $2 > 0 { printf "%.0f%%", $3 * 100 / $2 }')"
SWAP_USAGE="$(free -m 2>/dev/null | awk 'NR == 3 { if ($2 > 0) printf "%.0f%%", $3 * 100 / $2; else printf "0%%" }')"
DEFAULT_IFACE="$(get_default_iface)"
IPV4_ADDR="$(get_ipv4 "$DEFAULT_IFACE")"
SSH_PORT="$(get_ssh_port)"

[ -n "$LOAD_1" ] || LOAD_1="N/A"
[ -n "$ROOT_USAGE" ] || ROOT_USAGE="N/A"
[ -n "$MEM_USAGE" ] || MEM_USAGE="N/A"
[ -n "$SWAP_USAGE" ] || SWAP_USAGE="N/A"
[ -n "$DEFAULT_IFACE" ] || DEFAULT_IFACE="default"
[ -n "$IPV4_ADDR" ] || IPV4_ADDR="N/A"
[ -n "$SSH_PORT" ] || SSH_PORT="22"

echo ""
printf 'OS name: %s (%s %s %s)\n' "$(cyan "$OS_NAME")" "$(uname -s)" "$(uname -r)" "$(uname -m)"
printf 'System load: %s    Processes: %s\n' "$(cyan "$LOAD_1")" "$(cyan "$PROC_COUNT")"
printf 'Usage of /: %s    Users logged in: %s\n' "$(cyan "$ROOT_USAGE")" "$(cyan "$LOGGED_USERS")"
printf 'Memory usage: %s    Swap usage: %s\n' "$(cyan "$MEM_USAGE")" "$(cyan "$SWAP_USAGE")"
printf 'IPv4 address for %s: %s\n' "$(cyan "$DEFAULT_IFACE")" "$(cyan "$IPV4_ADDR")"
echo ""
printf 'SSH port: %s\n' "$(cyan "$SSH_PORT")"

echo ""
echo "Open network ports:"
echo "--------------------------------------------------"

netstat -tunlp 2>/dev/null | grep -v '127.0.0.' | grep -v '::1' | tail -n +3 | \
awk '{
    split($4, a, ":");
    port = a[length(a)];

    split($7, b, "/");
    prog = b[2] ? b[2] : b[1];

    printf "  %-6s %-5s %s\n", port, $1, prog
}' | sort -n

echo "--------------------------------------------------"

if [ -f /var/lib/update-notifier/updates-available ]; then
    cat /var/lib/update-notifier/updates-available
fi

# __CUSTOM_USER_BLOCK_START__
echo ""
echo "--------------------------------------------------"
printf '%s\n' CUSTOM_USER_TEST
echo ""
echo "To change this text edit /etc/update-motd.d/00-header"
echo "--------------------------------------------------"
# __CUSTOM_USER_BLOCK_END__

echo ""
