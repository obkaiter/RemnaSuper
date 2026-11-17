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
    install_relay_packages nginx || return 1
    trap - EXIT
)

write_relay_site_config() {
    local domain="$1" certificate_dir="$2" nginx_socket="$3"

    cat <<EOF
# RemnaSuper nginx
server {
    listen unix:$nginx_socket ssl;
    server_name $domain;

    ssl_certificate $certificate_dir/fullchain.pem;
    ssl_certificate_key $certificate_dir/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root $RELAY_SITE_ROOT;
    index index.html;
}
EOF
}

relay_site_host_socket() {
    local chroot socket_path="$RELAY_SITE_SOCKET"

    chroot="$(LC_ALL=C awk '$1 == "chroot" { path = $2; gsub(/^["\047]|["\047]$/, "", path) } END { print path }' \
        "$RELAY_HAPROXY_CONFIG")" || return 1
    if [[ -n "$chroot" ]]; then
        if [[ "$chroot" != /* ]] || ! chroot="$(realpath -e -- "$chroot")" || [[ ! -d "$chroot" ]]; then
            error "Не удалось определить каталог chroot HAProxy." >&2
            return 1
        fi
        socket_path="${chroot%/}$RELAY_SITE_SOCKET"
    fi
    if [[ ! "$socket_path" =~ ^/[A-Za-z0-9_./-]+$ ]] || (( ${#socket_path} > 107 )); then
        error "Недопустимый путь локального сокета nginx: $socket_path." >&2
        return 1
    fi
    printf '%s\n' "$socket_path"
}

configured_relay_site_certificate() {
    LC_ALL=C awk '
        $1 == "ssl_certificate" { cert = $2; cert_count++ }
        $1 == "ssl_certificate_key" { key = $2; key_count++ }
        END {
            if (cert_count != 1 || key_count != 1) exit 1
            sub(/;$/, "", cert)
            sub(/;$/, "", key)
            gsub(/^["\047]|["\047]$/, "", cert)
            gsub(/^["\047]|["\047]$/, "", key)
            printf "%s\n%s\n", cert, key
        }
    ' "$RELAY_NGINX_CONFIG"
}

configured_relay_site_socket() {
    LC_ALL=C awk '
        $1 == "listen" && $2 ~ /^unix:/ { socket = substr($2, 6); count++ }
        END { if (count != 1) exit 1; print socket }
    ' "$RELAY_NGINX_CONFIG"
}

rewrite_relay_site_config() {
    local certificate_dir="$1" nginx_socket="$2" source="$3"

    LC_ALL=C awk -v dir="$certificate_dir" -v socket="$nginx_socket" '
        dir != "" && $1 == "ssl_certificate" { print "    ssl_certificate " dir "/fullchain.pem;"; next }
        dir != "" && $1 == "ssl_certificate_key" { print "    ssl_certificate_key " dir "/privkey.pem;"; next }
        $1 == "listen" && $2 ~ /^unix:/ { sub(/unix:[^[:space:];]+/, "unix:" socket) }
        { print }
    ' "$source"
}

check_relay_site() {
    local domain="$1" nginx_socket="$2" attempt

    for attempt in 1 2 3 4; do
        if curl --noproxy '*' --unix-socket "$nginx_socket" --silent \
            --connect-timeout 2 --max-time 5 --output /dev/null "https://$domain/"; then
            return 0
        fi
        if (( attempt < 4 )); then
            sleep 1
        fi
    done
    error "Не удалось проверить HTTPS и сертификат $domain через $nginx_socket."
    return 1
}

cleanup_relay_site() {
    if (( config_changed && ! applied )); then
        if [[ -n "$nginx_backup" ]]; then
            if ! cp -p -- "$nginx_backup" "$candidate" || ! mv -T -- "$candidate" "$RELAY_NGINX_CONFIG"; then
                error "Не удалось восстановить конфигурацию nginx из $nginx_backup."
            fi
        elif ! rm -f -- "$RELAY_NGINX_CONFIG"; then
            error "Не удалось удалить новую конфигурацию nginx."
        fi
        if (( activation_attempted )); then
            if (( nginx_was_active )); then
                systemctl reload nginx || error "Не удалось вернуть прежние настройки nginx."
            else
                systemctl stop nginx || error "Не удалось остановить nginx."
            fi
        fi
    fi
    if [[ -n "$candidate" ]]; then
        rm -f -- "$candidate"
    fi
}

install_relay_site() (
    local domain="$1"
    local PATH="$PATH:/usr/sbin:/sbin"
    local route mode initial_haproxy_config current_haproxy_config nginx_socket configured_socket=''
    local certificate_dir='' configured_certificate='' candidate='' nginx_backup='' nginx_source="$RELAY_NGINX_CONFIG"
    local acme_dir="$RELAY_SITE_TLS_DIR/acme/$domain" letsencrypt_dir="$RELAY_LETSENCRYPT_DIR/$domain"
    local site_routed=0 config_changed=0 activation_attempted=0 nginx_was_active=0 applied=0
    local -a connections=()

    lock_relay && check_command systemctl && read_relay_connections connections mode &&
        check_relay_routing_editable "$mode" && run_relay_haproxy -v >/dev/null || return 1
    initial_haproxy_config="$(sha256sum -- "$RELAY_HAPROXY_CONFIG")" || return 1
    nginx_socket="$(relay_site_host_socket)" || return 1
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
        if ! configured_certificate="$(configured_relay_site_certificate)"; then
            error "Не удалось однозначно определить сертификат и ключ в $RELAY_NGINX_CONFIG."
            return 1
        fi
        if ! configured_socket="$(configured_relay_site_socket)"; then
            error "Не удалось однозначно определить локальный сокет в $RELAY_NGINX_CONFIG."
            return 1
        fi
    fi

    install_relay_packages curl openssl ca-certificates && install_relay_nginx && check_command nginx || return 1
    trap cleanup_relay_site EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if relay_certificate_usable "$domain" "${configured_certificate%%$'\n'*}" "${configured_certificate#*$'\n'}"; then
        if [[ "$configured_certificate" == "$acme_dir/fullchain.pem"$'\n'"$acme_dir/privkey.pem" ]]; then
            ensure_relay_acme_certificate "$domain" "$acme_dir" || return 1
        fi
    elif relay_certificate_usable "$domain" "$letsencrypt_dir/fullchain.pem" "$letsencrypt_dir/privkey.pem"; then
        certificate_dir="$letsencrypt_dir"
    else
        certificate_dir="$acme_dir"
        if [[ -n "$configured_certificate" ]] && ! nginx -t >/dev/null 2>&1; then
            candidate="$(mktemp "${RELAY_NGINX_CONFIG}.XXXXXX")" || return 1
            backup_config_file "$RELAY_NGINX_CONFIG" nginx_backup || return 1
            if systemctl is-active --quiet nginx; then
                nginx_was_active=1
            fi
            step "Временно отключается HTTPS-блок заглушки, чтобы выпустить сертификат для $domain."
            mv -T -- "$RELAY_NGINX_CONFIG" "$candidate" || return 1
            nginx_source="$nginx_backup"
            config_changed=1
            activation_attempted=1
        fi
        ensure_relay_acme_certificate "$domain" "$acme_dir" || return 1
    fi

    mkdir -p -- "${nginx_socket%/*}" || return 1
    if [[ -z "$configured_certificate" ]]; then
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
        if ! write_relay_site_config "$domain" "$certificate_dir" "$nginx_socket" > "$candidate" ||
            ! ln -- "$candidate" "$RELAY_NGINX_CONFIG"; then
            error "Не удалось записать конфигурацию сайта-заглушки."
            return 1
        fi
        config_changed=1
    elif [[ "$configured_socket" != "$nginx_socket" ]] || (( config_changed )) ||
        [[ -n "$certificate_dir" && "$configured_certificate" != "$certificate_dir/fullchain.pem"$'\n'"$certificate_dir/privkey.pem" ]]; then
        if [[ -z "$nginx_backup" ]]; then
            candidate="$(mktemp "${RELAY_NGINX_CONFIG}.XXXXXX")" || return 1
            backup_config_file "$RELAY_NGINX_CONFIG" nginx_backup || return 1
        fi
        if ! rewrite_relay_site_config "$certificate_dir" "$nginx_socket" "$nginx_source" > "$candidate" ||
            ! chmod --reference="$nginx_source" "$candidate" ||
            ! chown --reference="$nginx_source" "$candidate" ||
            ! mv -T -- "$candidate" "$RELAY_NGINX_CONFIG"; then
            error "Не удалось обновить локальный сокет или пути сертификата в конфигурации сайта."
            return 1
        fi
        config_changed=1
    fi

    nginx -t || return 1
    activation_attempted=1
    if systemctl is-active --quiet nginx; then
        nginx_was_active=1
        systemctl reload nginx || return 1
    else
        systemctl start nginx || return 1
    fi
    check_relay_site "$domain" "$nginx_socket" || return 1
    systemctl enable nginx || return 1
    current_haproxy_config="$(sha256sum -- "$RELAY_HAPROXY_CONFIG")" || return 1
    if [[ "$initial_haproxy_config" != "$current_haproxy_config" ]]; then
        error "Конфигурация HAProxy изменилась во время настройки nginx. Повторите установку заглушки."
        return 1
    fi
    if (( site_routed )); then
        systemctl start haproxy || return 1
    else
        apply_relay_config "$mode" "${connections[@]}" "site $domain" || return 1
    fi
    applied=1
    success "Сайт-заглушка настроен для https://$domain/."
    info "DNS-запись A домена должна указывать на IPv4-адрес релея."
    info "Загрузите файлы сайта в $RELAY_SITE_ROOT."
)
