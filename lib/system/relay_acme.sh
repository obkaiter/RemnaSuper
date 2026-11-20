#!/usr/bin/env bash

relay_certificate_usable() {
    local domain="$1" fullchain="$2" key="$3" certificate_public_key private_public_key

    [[ -s "$fullchain" && -s "$key" ]] || return 1
    openssl verify -purpose sslserver -verify_hostname "$domain" -untrusted "$fullchain" "$fullchain" \
        >/dev/null 2>&1 || return 1
    certificate_public_key="$(openssl x509 -in "$fullchain" -pubkey -noout 2>/dev/null)" || return 1
    private_public_key="$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null)" || return 1
    [[ -n "$certificate_public_key" && "$certificate_public_key" == "$private_public_key" ]]
}

install_relay_acme_client() (
    local client="$RELAY_ACME_HOME/acme.sh" download

    if [[ -L "$RELAY_ACME_HOME" || -L "$client" ]]; then
        error "Каталог или скрипт acme.sh является символической ссылкой."
        return 1
    fi
    if [[ -x "$client" ]]; then
        return 0
    fi
    if [[ -e "$client" ]]; then
        error "Не удалось использовать существующий скрипт $client."
        return 1
    fi
    install -d -m 700 -- "$RELAY_ACME_HOME" || return 1
    download="$(mktemp "$RELAY_ACME_HOME/.acme.XXXXXX")" || return 1
    trap 'rm -f -- "$download"' EXIT
    step "Загрузка acme.sh из официального репозитория GitHub..."
    if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$download" "$RELAY_ACME_URL" ||
        ! printf '%s  %s\n' "$RELAY_ACME_SHA256" "$download" | sha256sum -c --status ||
        ! chmod 700 -- "$download" || ! mv -T -- "$download" "$client"; then
        error "Не удалось скачать и проверить acme.sh."
        return 1
    fi
)

write_relay_acme_nginx_config() {
    local domain="$1"

    printf '# RemnaSuper ACME\nserver {\n    listen 80;\n' || return 1
    if grep -q . /proc/net/if_inet6 2>/dev/null; then
        printf '    listen [::]:80;\n' || return 1
    fi
    cat <<EOF
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $RELAY_ACME_WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF
}

check_relay_acme_webroot() (
    local domain="$1" webroot="$RELAY_ACME_WEBROOT/.well-known/acme-challenge" probe token answer attempt

    probe="$(mktemp "$webroot/remnasuper-XXXXXX")" || return 1
    trap 'rm -f -- "$probe"' EXIT
    token="${probe##*/}"
    printf '%s' "$token" > "$probe" && chmod 644 -- "$probe" || return 1
    for attempt in 1 2 3 4; do
        if answer="$(curl --silent --fail --noproxy '*' --connect-timeout 2 --max-time 5 \
            --resolve "$domain:80:127.0.0.1" "http://$domain/.well-known/acme-challenge/$token")" &&
            [[ "$answer" == "$token" ]]; then
            return 0
        fi
        (( attempt == 4 )) || sleep 1
    done
    error "nginx не отдал файл проверки для $domain на TCP/80. Проверьте слушатель и настройки HTTP-сайта."
    return 1
)

install_relay_acme_cron() (
    local candidate

    candidate="$(mktemp "${RELAY_ACME_CRON}.XXXXXX")" || return 1
    trap 'rm -f -- "$candidate"' EXIT
    printf 'PATH=/usr/sbin:/usr/bin:/sbin:/bin\n27 3 * * * root flock -n %s %s/acme.sh --cron --home %s\n' \
        "$INSTALL_DIR" "$RELAY_ACME_HOME" "$RELAY_ACME_HOME" > "$candidate" || return 1
    if [[ -e "$RELAY_ACME_CRON" || -L "$RELAY_ACME_CRON" ]]; then
        if [[ -L "$RELAY_ACME_CRON" ]] || ! cmp -s "$candidate" "$RELAY_ACME_CRON"; then
            error "Путь $RELAY_ACME_CRON занят другим заданием cron."
            return 1
        fi
    else
        chmod 644 -- "$candidate" && ln -- "$candidate" "$RELAY_ACME_CRON" || return 1
    fi
    systemctl enable --now cron
)

cleanup_relay_acme() {
    if [[ -n "$challenge_candidate" ]]; then
        rm -f -- "$challenge_candidate"
    fi
    if (( challenge_added && ! certificate_ready )); then
        if ! rm -f -- "$RELAY_ACME_NGINX_CONFIG"; then
            error "Не удалось удалить временную конфигурацию HTTP-01."
        elif (( nginx_activation_attempted )); then
            if (( nginx_was_active )); then
                systemctl reload nginx || error "Не удалось вернуть прежние настройки nginx."
            else
                systemctl stop nginx || error "Не удалось восстановить прежнее состояние nginx."
            fi
        fi
    fi
}

ensure_relay_acme_certificate() (
    local domain="$1" certificate_dir="$2" client="$RELAY_ACME_HOME/acme.sh"
    local challenge_candidate='' nginx_test issue_status
    local challenge_added=0 nginx_was_active=0 nginx_activation_attempted=0 certificate_ready=0

    install_relay_packages cron && install_relay_acme_client || return 1
    trap cleanup_relay_acme EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    install -d -m 755 -- "$RELAY_ACME_WEBROOT/.well-known/acme-challenge" || return 1
    if [[ -e "$RELAY_ACME_NGINX_CONFIG" || -L "$RELAY_ACME_NGINX_CONFIG" ]]; then
        if [[ -L "$RELAY_ACME_NGINX_CONFIG" ]] ||
            ! grep -Fxq '# RemnaSuper ACME' "$RELAY_ACME_NGINX_CONFIG" ||
            ! grep -Fxq "    server_name $domain;" "$RELAY_ACME_NGINX_CONFIG"; then
            error "Путь $RELAY_ACME_NGINX_CONFIG занят настройками другого сайта."
            return 1
        fi
    else
        challenge_candidate="$(mktemp "${RELAY_ACME_NGINX_CONFIG}.XXXXXX")" || return 1
        if ! write_relay_acme_nginx_config "$domain" > "$challenge_candidate" ||
            ! ln -- "$challenge_candidate" "$RELAY_ACME_NGINX_CONFIG"; then
            error "Не удалось установить конфигурацию nginx для HTTP-01."
            return 1
        fi
        challenge_added=1
    fi
    if ! nginx_test="$(nginx -t 2>&1)"; then
        printf '%s\n' "$nginx_test" >&2
        return 1
    fi
    if [[ "$nginx_test" == *"conflicting server name \"$domain\""* ]]; then
        error "Домен $domain уже обслуживается другим HTTP-сайтом nginx. Конфигурация этого сайта сохранена."
        return 1
    fi
    nginx_activation_attempted=1
    if systemctl is-active --quiet nginx; then
        nginx_was_active=1
        systemctl reload nginx || return 1
    else
        systemctl start nginx || return 1
    fi
    check_relay_acme_webroot "$domain" || return 1

    if ! relay_certificate_usable "$domain" "$certificate_dir/fullchain.pem" "$certificate_dir/privkey.pem"; then
        if [[ -L "$certificate_dir" || -L "$certificate_dir/privkey.pem" || -L "$certificate_dir/fullchain.pem" ]]; then
            error "Небезопасный путь для сертификата acme.sh: $certificate_dir."
            return 1
        fi
        umask 077
        install -d -m 700 -- "$certificate_dir" || return 1
        if [[ -f "$certificate_dir/privkey.pem" ]]; then
            chmod 600 -- "$certificate_dir/privkey.pem" || return 1
        fi
        step "Запрос сертификата Let's Encrypt для $domain через HTTP-01..."
        issue_status=0
        "$client" --home "$RELAY_ACME_HOME" --server letsencrypt --issue -d "$domain" \
            --webroot "$RELAY_ACME_WEBROOT" --keylength ec-256 || issue_status=$?
        if (( issue_status != 0 && issue_status != 2 )); then
            error "Let's Encrypt не выдал сертификат для $domain. Проверьте DNS домена и доступность TCP/80 из интернета."
            return 1
        fi
        if ! "$client" --home "$RELAY_ACME_HOME" --install-cert -d "$domain" --ecc \
            --key-file "$certificate_dir/privkey.pem" --fullchain-file "$certificate_dir/fullchain.pem" \
            --reloadcmd 'nginx -t && systemctl reload nginx' ||
            ! relay_certificate_usable "$domain" "$certificate_dir/fullchain.pem" "$certificate_dir/privkey.pem"; then
            error "Не удалось установить действующий сертификат для $domain."
            return 1
        fi
    fi
    certificate_ready=1
    install_relay_acme_cron || return 1
)
