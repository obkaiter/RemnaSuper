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

run_relay_haproxy() {
    local PATH="$PATH:/usr/sbin:/sbin"

    check_command haproxy >&2 && haproxy "$@"
}

write_relay_config() {
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
EOF

    write_relay_defaults || return 1
    write_relay_proxy_config "$@"
}

write_relay_defaults() {
    cat <<'EOF'

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
EOF
}

write_relay_proxy_config() {
    local route domain backend

    cat <<'EOF' || return 1

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

read_generated_relay_routes() {
    LC_ALL=C awk '
        $1 == "frontend" { active = ($2 == "bitwire_entry") }
        $1 ~ /^(backend|listen|defaults|global)$/ { active = 0 }
        active && $1 == "use_backend" && $5 == "req.ssl_sni" && $6 == "-i" {
            if ($2 == "relay_site") print "site", $7
            else if ($2 == "exit_" $7) print "node", $7
        }
    '
}

relay_routing_section() {
    local part="$1"

    LC_ALL=C awk -v part="$part" '
        $0 == "# RemnaSuper TCP routing" { found = 1 }
        (part == "base" && !found) || (part == "routes" && found) { print }
    '
}

write_relay_routing_section() {
    local contstats="$1"
    shift

    printf '# RemnaSuper TCP routing\n' || return 1
    write_relay_defaults || return 1
    if (( contstats )); then
        printf '    option contstats # RemnaSuper traffic\n' || return 1
    fi
    write_relay_proxy_config "$@"
}

read_external_relay_routes() {
    LC_ALL=C awk '
        function collect_sni(first,    i, result) {
            for (i = first; i <= NF; i++) {
                if ($i !~ /^[[:alnum:]]([[:alnum:].-]*[[:alnum:]])?$/ || $i !~ /\./) return ""
                result = result " " $i
            }
            return result
        }
        function record_routes(list, frontend, backend,    i, n, names, key) {
            n = split(list, names, " ")
            for (i = 1; i <= n; i++) {
                key = tolower(names[i]) " " frontend " " backend
                if (!seen[key]++) print "external", key
            }
        }
        { sub(/[[:space:]]+#.*/, "") }
        $1 ~ /^(frontend|listen|backend|defaults|global|peers|resolvers|userlist|cache|mailers|program|ring|log-forward|log-profile|traces|acme|crt-store|http-errors|fcgi-app)$/ {
            section++
            frontend = $1 ~ /^(frontend|listen)$/ && $2 ~ /^[[:alnum:]_.:-]+$/ ? $2 : ""
        }
        !frontend { next }
        $1 == "acl" {
            key = section SUBSEP $2
            list = $3 ~ /^(req\.ssl_sni|req_ssl_sni|ssl_fc_sni)$/ ? collect_sni(4 + ($4 == "-i")) : ""
            if (list == "") unsupported[key] = 1
            else names[key] = names[key] list
        }
        $1 == "use_backend" && $2 ~ /^[[:alnum:]_.:-]+$/ && $3 == "if" {
            if (NF == 4) {
                count++
                acl_keys[count] = section SUBSEP $4
                frontend_names[count] = frontend
                backend_names[count] = $2
            } else if ($4 == "{" && $5 ~ /^(req\.ssl_sni|req_ssl_sni|ssl_fc_sni)$/ && $NF == "}") {
                NF--
                record_routes(collect_sni(6 + ($6 == "-i")), frontend, $2)
            }
        }
        END {
            for (i = 1; i <= count; i++) {
                key = acl_keys[i]
                if (!unsupported[key]) record_routes(names[key], frontend_names[i], backend_names[i])
            }
        }
    ' "$RELAY_HAPROXY_CONFIG"
}

read_relay_connections() {
    local connections_variable="$1" mode_variable="$2" routes='' generated scope=external
    local -a controlled_routes=()

    if [[ ! -f "$RELAY_HAPROXY_CONFIG" || ! -r "$RELAY_HAPROXY_CONFIG" ]]; then
        error "Не удалось прочитать конфигурацию HAProxy: $RELAY_HAPROXY_CONFIG."
        return 1
    fi
    if [[ ! -L "$RELAY_HAPROXY_CONFIG" ]]; then
        if grep -Fxq '# RemnaSuper TCP routing' "$RELAY_HAPROXY_CONFIG"; then
            scope=managed
        elif grep -Fxq '# RemnaSuper HAProxy' "$RELAY_HAPROXY_CONFIG"; then
            scope=legacy
        elif ! grep -Eq '^[[:space:]]*(frontend|listen|backend)([[:space:]]|$)' "$RELAY_HAPROXY_CONFIG"; then
            scope=empty
        fi
    fi
    if [[ "$scope" == managed || "$scope" == legacy ]]; then
        generated="$(relay_stats_config strip "$RELAY_HAPROXY_CONFIG")" || return 1
        if [[ "$scope" == managed ]]; then
            generated="$(relay_routing_section routes <<< "$generated")" || return 1
        fi
        routes="$(read_generated_relay_routes <<< "$generated")" || return 1
        if [[ -n "$routes" ]]; then
            mapfile -t controlled_routes <<< "$routes"
        fi
        if [[ "$scope" == managed ]]; then
            cmp -s <(printf '%s\n' "$generated") <(write_relay_routing_section 0 "${controlled_routes[@]}") || scope=external
        else
            cmp -s <(printf '%s\n' "$generated") <(write_relay_config "${controlled_routes[@]}") || scope=external
        fi
    fi
    if [[ "$scope" == external ]]; then
        routes="$(read_external_relay_routes)" || return 1
    fi
    if [[ -n "$routes" ]]; then
        mapfile -t "$connections_variable" <<< "$routes" || return 1
    else
        mapfile -t "$connections_variable" < /dev/null || return 1
    fi
    printf -v "$mode_variable" '%s' "$scope"
}

check_relay_routing_editable() {
    local mode="$1" listeners

    if [[ "$mode" == external ]]; then
        error "Подключения из ручной конфигурации можно просматривать. Для изменения маршрутов в $RELAY_HAPROXY_CONFIG отредактируйте соответствующий frontend."
        return 1
    fi
    if [[ "$mode" == empty ]]; then
        check_command ss || return 1
        listeners="$(ss -H -ltn 'sport = :443')" || return 1
        if [[ -n "$listeners" ]]; then
            error "TCP/443 уже занят. RemnaSuper не может добавить слушатель релея."
            return 1
        fi
    fi
}

wait_relay_listener() {
    local attempt listeners

    for attempt in {1..8}; do
        listeners="$(ss -H -4 -ltnp 'sport = :443')" || return 1
        if [[ "$listeners" == *'"haproxy"'* ]]; then
            return 0
        fi
        (( attempt == 8 )) || sleep 1
    done
    error "HAProxy не открыл TCP/443 после применения конфигурации."
    return 1
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
    if (( ! offline )) && ! (cd / && run_relay_haproxy -c -f "$candidate"); then
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
        if [[ ( "$generator" == relay_stats_config && "$1" == add ) || "$generator" == write_relay_routing_config ]]; then
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
    if [[ ( "$generator" == relay_stats_config && "$1" == add ) || -n "$previous_worker" ]]; then
        wait_relay_stats_socket "$previous_worker" || return 1
    elif ! systemctl is-active --quiet haproxy; then
        error "HAProxy не запустился с новой конфигурацией."
        return 1
    fi
    if [[ "$generator" == write_relay_routing_config && "$1" == empty ]]; then
        wait_relay_listener || return 1
    fi
    applied=1
    return 0
)

write_relay_routing_config() {
    local mode="$1" managed_lines contstats=0
    shift

    managed_lines="$(relay_stats_config owned "$RELAY_HAPROXY_CONFIG")" || return 1
    case "$mode" in
        legacy)
            write_relay_config "$@" | relay_stats_config restore - '' 0 "$managed_lines"
            return $?
            ;;
        managed) relay_routing_section base < "$RELAY_HAPROXY_CONFIG" || return 1 ;;
        empty) cat -- "$RELAY_HAPROXY_CONFIG" && printf '\n' || return 1 ;;
        *) return 1 ;;
    esac
    if [[ "$managed_lines" == *'option contstats # RemnaSuper traffic'* ]] ||
        relay_stats_config contstats "$RELAY_HAPROXY_CONFIG"; then
        contstats=1
    fi
    write_relay_routing_section "$contstats" "$@"
}

apply_relay_config() {
    check_relay_routing_editable "$1" || return 1
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
    local route mode found=0
    local -a connections=() updated=()

    lock_relay && check_command systemctl && read_relay_connections connections mode || return 1
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
        apply_relay_config "$mode" "${connections[@]}" "node $domain" || return 1
        success "Добавлено подключение $domain → $domain:443."
    else
        if (( ! found )); then
            error "Подключение с SNI $domain уже отсутствует."
            return 1
        fi
        apply_relay_config "$mode" "${updated[@]}" || return 1
        success "Подключение с SNI $domain удалено."
    fi
)
