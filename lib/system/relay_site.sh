#!/usr/bin/env bash

install_relay_nginx() (
    check_command dpkg-query || return 1
    if relay_package_installed nginx; then
        return 0
    fi

    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ ! -e "$RELAY_NGINX_DEFAULT" && ! -L "$RELAY_NGINX_DEFAULT" ]]; then
        if ! mkdir -p -- "${RELAY_NGINX_DEFAULT%/*}" || ! ln -s /dev/null "$RELAY_NGINX_DEFAULT"; then
            error "Не удалось отключить стандартный сайт нового nginx."
            return 1
        fi
        trap 'rm -f -- "$RELAY_NGINX_DEFAULT"' EXIT
    fi
    install_relay_package nginx || return 1
    trap - EXIT
)

create_relay_site_certificate() (
    local domain="$1" certificate_dir="$2" temp_dir

    if [[ -s "$certificate_dir/fullchain.pem" && -s "$certificate_dir/privkey.pem" ]]; then
        return 0
    fi
    if [[ -e "$certificate_dir" || -L "$certificate_dir" ]]; then
        error "В $certificate_dir отсутствует сертификат или ключ."
        return 1
    fi

    check_command openssl || return 1
    umask 077
    mkdir -p -- "$RELAY_SITE_TLS_DIR" || return 1
    temp_dir="$(mktemp -d "$RELAY_SITE_TLS_DIR/.cert.XXXXXX")" || return 1
    trap 'rm -f -- "$temp_dir/fullchain.pem" "$temp_dir/privkey.pem"; rmdir -- "$temp_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=$domain" \
        -addext "subjectAltName=DNS:$domain" -out "$temp_dir/fullchain.pem" -keyout "$temp_dir/privkey.pem" ||
        ! chmod 600 -- "$temp_dir/privkey.pem" || ! mv -T -- "$temp_dir" "$certificate_dir"; then
        error "Не удалось создать самоподписанный сертификат для $domain."
        return 1
    fi
    trap - EXIT
)

write_relay_site_config() {
    local domain="$1" certificate_dir="$2"

    cat <<EOF
# RemnaSuper nginx
server {
    listen unix:$RELAY_SITE_SOCKET ssl;
    server_name $domain;

    ssl_certificate $certificate_dir/fullchain.pem;
    ssl_certificate_key $certificate_dir/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root $RELAY_SITE_ROOT;
    index index.html;
}
EOF
}

check_relay_site() {
    local domain="$1" attempt

    for attempt in 1 2 3 4; do
        if curl --noproxy '*' --unix-socket "$RELAY_SITE_SOCKET" --insecure --silent \
            --connect-timeout 2 --max-time 5 --output /dev/null "https://$domain/"; then
            return 0
        fi
        if (( attempt < 4 )); then
            sleep 1
        fi
    done
    error "nginx не ответил по HTTPS через $RELAY_SITE_SOCKET."
    return 1
}

cleanup_relay_site() {
    if [[ -n "$candidate" ]]; then
        rm -f -- "$candidate"
    fi
    if (( config_added && ! applied )); then
        if ! rm -f -- "$RELAY_NGINX_CONFIG"; then
            error "Не удалось удалить новую конфигурацию nginx."
        elif (( activation_attempted )); then
            if (( nginx_was_active )); then
                systemctl reload nginx || error "Не удалось вернуть прежние настройки nginx."
            else
                systemctl stop nginx || error "Не удалось остановить nginx."
            fi
        fi
    fi
}

install_relay_site() (
    local domain="$1"
    local route certificate_dir candidate=
    local site_routed=0 config_added=0 activation_attempted=0 nginx_was_active=0 applied=0
    local -a connections=()

    lock_relay && check_command systemctl && read_relay_connections connections || return 1
    valid_relay_domain "$domain" || return 1
    for route in "${connections[@]}"; do
        case "$route" in
            "site $domain") site_routed=1 ;;
            'site '*|"node $domain")
                error "Сайт-заглушка уже настроен для другого домена или SNI $domain занят подключением."
                return 1
                ;;
        esac
    done
    if [[ -e "$RELAY_NGINX_CONFIG" || -L "$RELAY_NGINX_CONFIG" ]]; then
        if [[ -L "$RELAY_NGINX_CONFIG" ]] || ! grep -Fxq '# RemnaSuper nginx' "$RELAY_NGINX_CONFIG" ||
            ! grep -Fxq "    server_name $domain;" "$RELAY_NGINX_CONFIG"; then
            error "Существующая конфигурация $RELAY_NGINX_CONFIG не подходит для домена $domain."
            return 1
        fi
    fi

    check_command curl && install_relay_nginx && check_command nginx || return 1
    trap cleanup_relay_site EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ ! -f "$RELAY_NGINX_CONFIG" ]]; then
        certificate_dir="$RELAY_LETSENCRYPT_DIR/$domain"
        if [[ ! -s "$certificate_dir/fullchain.pem" || ! -s "$certificate_dir/privkey.pem" ]]; then
            certificate_dir="$RELAY_SITE_TLS_DIR/$domain"
            create_relay_site_certificate "$domain" "$certificate_dir" || return 1
        fi
        if [[ ! -d "$RELAY_SITE_ROOT" ]] && ! install -d -m 755 -- "$RELAY_SITE_ROOT"; then
            error "Не удалось создать каталог сайта-заглушки $RELAY_SITE_ROOT."
            return 1
        fi
        if ! mkdir -p -- "${RELAY_NGINX_CONFIG%/*}"; then
            error "Не удалось подготовить каталоги сайта-заглушки."
            return 1
        fi
        if [[ ! -e "$RELAY_SITE_ROOT/index.html" && ! -L "$RELAY_SITE_ROOT/index.html" ]]; then
            install -m 644 /dev/null "$RELAY_SITE_ROOT/index.html" || return 1
        fi
        candidate="$(mktemp "${RELAY_NGINX_CONFIG}.XXXXXX")" || return 1
        if ! write_relay_site_config "$domain" "$certificate_dir" > "$candidate" ||
            ! ln -- "$candidate" "$RELAY_NGINX_CONFIG"; then
            error "Не удалось записать конфигурацию сайта-заглушки."
            return 1
        fi
        config_added=1
    fi

    nginx -t || return 1
    if systemctl is-active --quiet nginx; then
        nginx_was_active=1
        if (( config_added )); then
            activation_attempted=1
            systemctl reload nginx || return 1
        fi
    else
        activation_attempted=1
        systemctl start nginx || return 1
    fi
    check_relay_site "$domain" || return 1
    systemctl enable nginx || return 1
    if (( site_routed )); then
        systemctl start haproxy || return 1
    else
        apply_relay_config "${connections[@]}" "site $domain" || return 1
    fi
    applied=1
    success "Сайт-заглушка настроен для https://$domain/."
    info "DNS-запись A домена должна указывать на IPv4-адрес релея."
    info "Загрузите файлы сайта в $RELAY_SITE_ROOT."
    if grep -Fq "$RELAY_SITE_TLS_DIR/$domain/" "$RELAY_NGINX_CONFIG"; then
        warn "Используется самоподписанный сертификат. Браузеры будут предупреждать о недоверенном соединении."
    fi
)
