#!/usr/bin/env bash

install_remnanode_certificates() {
    header "Установка сертификатов в RemnaNode"
    local certificate_domains=()
    local domain
    local fullchain_volume
    local privkey_volume

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден."
        pause
        return
    fi

    mapfile -t certificate_domains < <(
        awk '
            /^services:[[:space:]]*$/ { in_services=1; next }
            in_services && /^[^[:space:]#][^:]*:/ { in_services=0 }
            in_services && /^  remnawave-nginx:[[:space:]]*$/ {
                in_nginx=1
                in_volumes=0
                next
            }
            in_nginx && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
                in_nginx=0
                in_volumes=0
            }
            in_nginx && /^    volumes:[[:space:]]*$/ {
                in_volumes=1
                next
            }
            in_volumes && /^    [A-Za-z0-9_.-]+:/ { in_volumes=0 }
            in_volumes {
                marker="/etc/letsencrypt/live/"
                start=index($0, marker)
                if (!start) {
                    next
                }

                path=substr($0, start + length(marker))
                slash=index(path, "/")
                if (!slash) {
                    next
                }

                domain=substr(path, 1, slash - 1)
                filename=substr(path, slash + 1)
                if (filename ~ /^(fullchain|privkey)\.pem:/ && !seen[domain]++) {
                    print domain
                }
            }
        ' "$COMPOSE_FILE"
    )

    if [ "${#certificate_domains[@]}" -eq 0 ]; then
        error "Не удалось найти сертификаты в volumes сервиса remnawave-nginx."
        pause
        return
    fi

    if [ "${#certificate_domains[@]}" -gt 1 ]; then
        error "В volumes сервиса remnawave-nginx найдены сертификаты нескольких доменов: ${certificate_domains[*]}"
        pause
        return
    fi

    domain="${certificate_domains[0]}"
    if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
        [[ "$domain" != *.* ]] || [[ "$domain" == *..* ]]; then
        error "В remnawave-nginx найдено некорректное доменное имя: $domain"
        pause
        return
    fi

    info "Домен найден в remnawave-nginx: $domain"
    fullchain_volume="/etc/letsencrypt/live/${domain}/fullchain.pem:/etc/nginx/ssl/${domain}/fullchain.pem:ro"
    privkey_volume="/etc/letsencrypt/live/${domain}/privkey.pem:/etc/nginx/ssl/${domain}/privkey.pem:ro"

    backup_compose
    # Новые записи добавляются сразу после volumes, поэтому добавляем их в обратном порядке.
    add_remnanode_volume "$privkey_volume" || { pause; return; }
    add_remnanode_volume "$fullchain_volume" || { pause; return; }

    restart_remnanode_compose
    pause
}

