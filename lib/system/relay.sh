#!/usr/bin/env bash

valid_relay_domain() {
    local domain="$1"
    local LC_ALL=C
    local label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'

    [[ ${#domain} -le 253 && "$domain" =~ ^($label\.)+$label$ && "${domain##*.}" =~ [a-z] ]]
}

relay_package_installed() {
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == 'install ok installed' ]]
}

write_relay_config() {
    local route domain backend

    cat <<'EOF' || return 1
# RemnaSuper HAProxy
# ==================================================
# Центральный TCP-мост
# ==================================================

global
    # Логи в stdout для systemd/journald
    log stdout format raw local0

    # Максимум одновременных соединений
    maxconn 10000

    user haproxy
    group haproxy

    # Локальный сокет статистики
    stats socket /run/haproxy/admin.sock mode 660 level operator
    stats timeout 30s

defaults
    log global
    mode tcp
    option tcplog

    # Время установки соединения с зарубежной нодой
    timeout connect 8s

    # Таймауты неактивности соединений
    timeout client 2h
    timeout server 2h
    timeout tunnel 2h

# ==================================================
# FRONTEND: точка входа пользователей
# ==================================================

frontend bitwire_entry
    bind 0.0.0.0:443
    mode tcp

    tcp-request inspect-delay 5s
EOF

    if (( $# )); then
        printf '\n    # Разрешённые SNI\n' || return 1
        for route in "$@"; do
            printf '    acl relay_sni req.ssl_sni -i %s\n' "${route#* }" || return 1
        done
        cat <<'EOF' || return 1

    # Отклоняем неизвестные SNI
    tcp-request content reject if { req.ssl_hello_type 1 } !relay_sni

    # Пропускаем только распознанный TLS ClientHello
    tcp-request content accept if { req.ssl_hello_type 1 } relay_sni
EOF
    fi

    cat <<'EOF' || return 1

    # Отклоняем трафик, не прошедший проверку
    tcp-request content reject if WAIT_END
EOF

    if (( $# )); then
        printf '\n    # Маршрутизация\n' || return 1
        for route in "$@"; do
            domain="${route#* }"
            backend="exit_$domain"
            [[ "$route" != 'site '* ]] || backend=relay_site
            printf '    use_backend %s if { req.ssl_sni -i %s }\n' "$backend" "$domain" || return 1
        done
    fi
    printf '\n    # Никакого default_backend\n' || return 1

    for route in "$@"; do
        domain="${route#* }"
        if [[ "$route" == 'site '* ]]; then
            printf '\n# Сайт-заглушка — %s\nbackend relay_site\n    mode tcp\n    server nginx %s\n' \
                "$domain" "$RELAY_SITE_SOCKET" || return 1
        else
            printf '\n# %s\nbackend exit_%s\n    mode tcp\n    server node %s:443 check inter 10s fall 3 rise 2\n' \
                "$domain" "$domain" "$domain" || return 1
        fi
    done
}

read_relay_connections() {
    local -n connections_result="$1"
    local routes

    if ! command -v haproxy >/dev/null 2>&1; then
        error "Сначала установите HAProxy в меню «Настройка релея»."
        return 1
    fi
    if [[ -L "$RELAY_HAPROXY_CONFIG" ]] ||
        ! grep -Fxq '# RemnaSuper HAProxy' "$RELAY_HAPROXY_CONFIG" 2>/dev/null; then
        error "Сначала настройте HAProxy через пункт «Установить HAProxy»."
        return 1
    fi

    routes="$(LC_ALL=C awk '
        $1 == "use_backend" && $5 == "req.ssl_sni" && $6 == "-i" {
            if ($2 == "relay_site") print "site", $7
            else if ($2 == "exit_" $7) print "node", $7
        }
    ' "$RELAY_HAPROXY_CONFIG")" || return 1
    connections_result=()
    if [[ -n "$routes" ]]; then
        mapfile -t connections_result <<< "$routes"
    fi
    if ! cmp -s <(relay_stats_config strip "$RELAY_HAPROXY_CONFIG") <(write_relay_config "${connections_result[@]}"); then
        error "Файл $RELAY_HAPROXY_CONFIG изменён вручную. Восстановите конфигурацию RemnaSuper из резервной копии для управления подключениями."
        return 1
    fi
}

cleanup_relay_config() {
    if (( ! applied )) && [[ ! -e "$candidate" ]]; then
        if [[ -n "$backup_file" ]]; then
            if ! cp -p -- "$backup_file" "$candidate" || ! mv -T -- "$candidate" "$RELAY_HAPROXY_CONFIG"; then
                error "Не удалось вернуть конфигурацию HAProxy из $backup_file."
                rm -f -- "$candidate"
                return 1
            fi
        elif ! rm -f -- "$RELAY_HAPROXY_CONFIG"; then
            error "Не удалось удалить новую конфигурацию HAProxy."
            return
        fi
        if (( was_active && ! offline )); then
            systemctl reload haproxy || error "Не удалось перечитать прежнюю конфигурацию HAProxy."
        elif (( ! offline )); then
            systemctl stop haproxy || error "Не удалось остановить HAProxy."
        fi
    fi
    rm -f -- "$candidate"
}

commit_relay_config() (
    local offline="$1" generator="$2"
    shift 2
    local candidate backup_file='' was_active=0 applied=0 previous_worker=''

    prepare_relay_directories || return 1
    candidate="$(mktemp "${RELAY_HAPROXY_CONFIG}.XXXXXX")" || return 1
    trap cleanup_relay_config EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$generator" "$@" > "$candidate" || return 1
    if cmp -s "$candidate" "$RELAY_HAPROXY_CONFIG"; then
        return 0
    fi
    if [[ -L "$RELAY_HAPROXY_CONFIG" ]]; then
        error "Не удалось изменить символическую ссылку $RELAY_HAPROXY_CONFIG."
        return 1
    fi
    if (( ! offline )) && ! (cd / && haproxy -c -f "$candidate"); then
        error "Конфигурация HAProxy не прошла проверку."
        return 1
    fi
    if [[ -e "$RELAY_HAPROXY_CONFIG" ]]; then
        if ! backup_config_file "$RELAY_HAPROXY_CONFIG" backup_file "$RELAY_DIR/backups" ||
            ! chmod --reference="$RELAY_HAPROXY_CONFIG" "$candidate" ||
            ! chown --reference="$RELAY_HAPROXY_CONFIG" "$candidate"; then
            error "Не удалось подготовить конфигурацию HAProxy к замене."
            return 1
        fi
    fi
    if systemctl is-active --quiet haproxy; then
        was_active=1
        if [[ "$generator" == relay_stats_config && "$1" == add ]]; then
            previous_worker="$(relay_traffic_command probe --worker 2>/dev/null)" || previous_worker=''
        fi
    fi
    if ! mv -T -- "$candidate" "$RELAY_HAPROXY_CONFIG"; then
        error "Не удалось заменить $RELAY_HAPROXY_CONFIG."
        return 1
    fi

    if (( offline )); then
        applied=1
        return 0
    fi
    if (( was_active )); then
        systemctl reload haproxy || return 1
    else
        systemctl start haproxy || return 1
    fi
    if [[ "$generator" == relay_stats_config && "$1" == add ]]; then
        wait_relay_stats_socket "$previous_worker" || return 1
    elif ! systemctl is-active --quiet haproxy; then
        error "HAProxy не запустился с новой конфигурацией."
        return 1
    fi
    applied=1
    return 0
)

write_relay_routing_config() {
    local managed_lines

    managed_lines="$(relay_stats_config owned "$RELAY_HAPROXY_CONFIG")" || return 1
    write_relay_config "$@" | relay_stats_config restore - '' 0 "$managed_lines"
}

apply_relay_config() {
    commit_relay_config 0 write_relay_routing_config "$@"
}

install_relay_packages() {
    local package
    local -a missing=() options=(-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

    check_command dpkg-query || return 1
    for package in "$@"; do
        if ! relay_package_installed "$package"; then
            missing+=("$package")
        fi
    done
    (( ${#missing[@]} )) || return 0
    check_command apt-get || return 1
    step "Установка пакетов: ${missing[*]}."
    if apt-get "${options[@]}" update &&
        apt-get "${options[@]}" install -y --no-install-recommends "${missing[@]}"; then
        return 0
    fi
    error "Не удалось установить пакеты: ${missing[*]}."
    return 1
}

change_relay_connection() (
    local action="$1" domain="$2"
    local route found=0
    local -a connections=() updated=()

    lock_relay && check_command systemctl && read_relay_connections connections || return 1
    for route in "${connections[@]}"; do
        if [[ "${route#* }" == "$domain" ]]; then
            found=1
        else
            updated+=("$route")
        fi
    done
    if [[ "$action" == add ]]; then
        if ! valid_relay_domain "$domain" || (( found )); then
            error "Укажите корректный SNI, которого ещё нет в конфигурации."
            return 1
        fi
        apply_relay_config "${connections[@]}" "node $domain" || return 1
        success "Добавлено подключение $domain → $domain:443."
    else
        if (( ! found )); then
            error "Подключение с SNI $domain уже отсутствует."
            return 1
        fi
        apply_relay_config "${updated[@]}" || return 1
        success "Подключение с SNI $domain удалено."
    fi
)
