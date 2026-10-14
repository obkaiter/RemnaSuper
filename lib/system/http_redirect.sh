#!/usr/bin/env bash

_http_redirect_inspect_config() {
    local config_file="$1"

    awk '
        function finish_server() {
            if (listens_on_80) {
                port_80_count++
                port_80_name=server_name
                port_80_redirect=redirect
            } else if (domain == "" && server_name != "" && server_name != "_") {
                domain=server_name
            }
        }
        {
            line=$0
            sub(/[[:space:]]*#.*/, "", line)
            if (!in_server && line ~ /^[[:space:]]*server[[:space:]]*\{/) {
                in_server=1
                depth=0
                server_name=""
                listens_on_80=0
                redirect=0
            }
            if (!in_server) {
                next
            }
            if (depth == 1 && line ~ /^[[:space:]]*server_name[[:space:]]+/) {
                field_count=split(line, fields, /[[:space:]]+/)
                for (i=1; i<=field_count; i++) {
                    if (fields[i] == "server_name") {
                        server_name=fields[i+1]
                        sub(/;.*/, "", server_name)
                        break
                    }
                }
            }
            if (depth == 1 && line ~ /^[[:space:]]*listen[[:space:]]+/) {
                listen=line
                sub(/^[[:space:]]*listen[[:space:]]+/, "", listen)
                sub(/[[:space:];].*/, "", listen)
                if (listen == "80" || listen ~ /:80$/) {
                    listens_on_80=1
                }
            }
            if (depth == 1 && line ~ /^[[:space:]]*return[[:space:]]+301[[:space:]]+https:\/\/[$]host[$]request_uri[[:space:]]*;/) {
                redirect=1
            }
            braces=line
            depth+=gsub(/\{/, "{", braces)
            depth-=gsub(/\}/, "}", braces)
            if (depth == 0) {
                finish_server()
                in_server=0
            }
        }
        END {
            if (in_server || domain == "") {
                exit 2
            }
            if (port_80_count > 1 || (port_80_count == 1 &&
                !(port_80_redirect && port_80_name == domain))) {
                exit 3
            }
            printf "%s|%d\n", domain, port_80_count
        }
    ' "$config_file"
}

_http_redirect_restore_config() {
    local backup_file="$1"
    local temp_file="$2"

    cp -p "$backup_file" "$temp_file" && mv -f "$temp_file" "$NODE_NGINX_CONF"
}

enable_http_redirect() {
    local config_state inspect_status domain redirect_present
    local services running_nginx ufw_rules rule_existed=0
    local temp_file backup_file

    header "HTTP 301 на 80 порте"

    if [ ! -f "$COMPOSE_FILE" ] || [ ! -f "$NODE_NGINX_CONF" ]; then
        error "RemnaNode не найдена: нужны $COMPOSE_FILE и $NODE_NGINX_CONF."
        pause
        return 1
    fi
    if [ -L "$NODE_NGINX_CONF" ]; then
        error "Файл $NODE_NGINX_CONF является ссылкой; автоматическая замена не поддерживается."
        pause
        return 1
    fi
    check_docker || { pause; return 1; }
    check_command awk || { pause; return 1; }
    check_command ufw || { pause; return 1; }
    check_command mktemp || { pause; return 1; }

    if ! (cd "$NODE_DIR" && docker compose config >/dev/null); then
        error "Конфигурация Docker Compose RemnaNode не прошла проверку."
        pause
        return 1
    fi
    if ! services="$(cd "$NODE_DIR" && docker compose config --services)" ||
        ! grep -Fxq remnanode <<< "$services" ||
        ! grep -Fxq remnawave-nginx <<< "$services"; then
        error "В Docker Compose нужны сервисы remnanode и remnawave-nginx."
        pause
        return 1
    fi
    if ! running_nginx="$(cd "$NODE_DIR" && docker compose ps --status running -q remnawave-nginx)" ||
        [ -z "$running_nginx" ]; then
        error "Сервис remnawave-nginx должен быть запущен для проверки nginx.conf."
        pause
        return 1
    fi

    config_state="$(_http_redirect_inspect_config "$NODE_NGINX_CONF")"
    inspect_status=$?
    case "$inspect_status" in
        0) ;;
        3) error "Порт 80 уже занят другим блоком server в $NODE_NGINX_CONF." ;;
        *) error "Не удалось найти домен в server_name или разобрать $NODE_NGINX_CONF." ;;
    esac
    if [ "$inspect_status" -ne 0 ]; then
        pause
        return 1
    fi
    IFS='|' read -r domain redirect_present <<< "$config_state"
    if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
        [[ "$domain" != *.* ]] || [[ "$domain" == *..* ]]; then
        error "Некорректное доменное имя в server_name: $domain"
        pause
        return 1
    fi
    info "Домен RemnaNode: $domain"

    if ! ufw_rules="$(LC_ALL=C ufw show added)"; then
        error "Не удалось проверить существующие правила UFW."
        pause
        return 1
    fi
    if grep -Fxq 'ufw allow 80/tcp' <<< "$ufw_rules"; then
        rule_existed=1
    fi

    if [ "$redirect_present" -eq 0 ]; then
        if ! temp_file="$(mktemp "${NODE_NGINX_CONF}.remnasuper.XXXXXX")" ||
            ! backup_file="$(mktemp "${NODE_NGINX_CONF}.bak.XXXXXX")"; then
            [ -n "$temp_file" ] && rm -f "$temp_file"
            error "Не удалось создать временные файлы рядом с nginx.conf."
            pause
            return 1
        fi
        if ! cp -p "$NODE_NGINX_CONF" "$temp_file" ||
            ! cp -p "$NODE_NGINX_CONF" "$backup_file" ||
            ! printf '\nserver {\n    listen 80;\n    server_name %s;\n    return 301 https://$host$request_uri;\n}\n' "$domain" >> "$temp_file" ||
            ! _http_redirect_inspect_config "$temp_file" >/dev/null; then
            rm -f "$temp_file" "$backup_file"
            error "Не удалось подготовить nginx.conf. Исходный файл не изменён."
            pause
            return 1
        fi
    fi

    step "Открытие TCP-порта 80 в UFW..."
    if ! ufw allow 80/tcp; then
        [ "$redirect_present" -eq 0 ] && rm -f "$temp_file" "$backup_file"
        error "Не удалось добавить правило UFW для порта 80."
        pause
        return 1
    fi

    if [ "$redirect_present" -eq 1 ]; then
        success "Перенаправление HTTP 301 уже настроено; правило UFW проверено."
        pause
        return 0
    fi

    step "Обновление $NODE_NGINX_CONF..."
    if ! mv -f "$temp_file" "$NODE_NGINX_CONF"; then
        error "Не удалось установить nginx.conf."
        if ! _http_redirect_restore_config "$backup_file" "$temp_file"; then
            error "Не удалось восстановить nginx.conf из $backup_file."
        fi
        if [ "$rule_existed" -eq 0 ] && ! ufw --force delete allow 80/tcp; then
            warn "Не удалось удалить новое правило UFW для порта 80."
        fi
        rm -f "$temp_file"
        pause
        return 1
    fi

    if ! restart_remnanode_compose ||
        ! running_nginx="$(cd "$NODE_DIR" && docker compose ps --status running -q remnawave-nginx)" ||
        [ -z "$running_nginx" ] ||
        ! (cd "$NODE_DIR" && docker compose exec -T remnawave-nginx nginx -t); then
        error "Нода не запустилась с новым nginx.conf; восстановление прежней конфигурации..."
        if _http_redirect_restore_config "$backup_file" "$temp_file"; then
            restart_remnanode_compose || warn "Не удалось перезапустить ноду после отката."
        else
            error "Не удалось восстановить nginx.conf из $backup_file."
        fi
        if [ "$rule_existed" -eq 0 ] && ! ufw --force delete allow 80/tcp; then
            warn "Не удалось удалить новое правило UFW для порта 80."
        fi
        rm -f "$temp_file"
        pause
        return 1
    fi

    success "HTTP-запросы на порт 80 перенаправляются на HTTPS для $domain."
    info "Резервная копия nginx.conf: $backup_file"
    pause
}
