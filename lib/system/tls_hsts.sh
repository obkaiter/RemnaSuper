#!/usr/bin/env bash

_tls_hsts_inspect_config() {
    local config_file="$1"

    awk '
        function finish_server() {
            if (!has_tls || domain == "") {
                return
            }

            candidate_count++
            if (!has_hsts) {
                missing_count++
            }
            if (has_conflicting_hsts) {
                conflict_count++
            }
            if (!(domain in seen_domains)) {
                seen_domains[domain]=1
                domains=domains (domains == "" ? "" : " ") domain
            }
        }
        {
            line=$0
            sub(/[[:space:]]*#.*/, "", line)

            if (!in_server && line ~ /^[[:space:]]*server[[:space:]]*\{/) {
                in_server=1
                depth=0
                domain=""
                has_tls=0
                has_hsts=0
                has_conflicting_hsts=0
            }
            if (!in_server) {
                next
            }

            if (depth == 1 && line ~ /^[[:space:]]*server_name[[:space:]]+/) {
                names=line
                sub(/^[[:space:]]*server_name[[:space:]]+/, "", names)
                sub(/[[:space:]]*;.*/, "", names)
                name_count=split(names, name_parts, /[[:space:]]+/)
                for (i=1; i<=name_count; i++) {
                    name=name_parts[i]
                    sub(/;$/, "", name)
                    if (name != "_" && name ~ /^[A-Za-z0-9*_.-]+$/ &&
                        name ~ /\./ && name !~ /\.\./) {
                        domain=name
                        break
                    }
                }
            }
            if (depth == 1 && line ~ /^[[:space:]]*listen[[:space:]]+/) {
                listen=line
                sub(/^[[:space:]]*listen[[:space:]]+/, "", listen)
                sub(/;.*/, "", listen)
                listen_count=split(listen, listen_parts, /[[:space:]]+/)
                for (i=1; i<=listen_count; i++) {
                    if (listen_parts[i] == "ssl") {
                        has_tls=1
                    }
                }
            }
            if (depth == 1 && line ~ /^[[:space:]]*add_header[[:space:]]+Strict-Transport-Security([[:space:]]|;)/) {
                if (line ~ /^[[:space:]]*add_header[[:space:]]+Strict-Transport-Security[[:space:]]+"max-age=31536000; includeSubDomains"[[:space:]]+always[[:space:]]*;[[:space:]]*$/) {
                    has_hsts=1
                } else {
                    has_conflicting_hsts=1
                }
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
            if (in_server) {
                exit 4
            }
            if (candidate_count == 0) {
                exit 2
            }
            if (conflict_count > 0) {
                exit 3
            }
            printf "%d|%s\n", missing_count, domains
        }
    ' "$config_file"
}

_tls_hsts_transform_config() {
    local config_file="$1"

    awk '
        function flush_server(    i, line_index) {
            if (has_tls && domain != "" && !has_hsts) {
                for (line_index=1; line_index<server_line_count; line_index++) {
                    print server_lines[line_index]
                }
                print "    add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always;"
                print server_lines[server_line_count]
            } else {
                for (line_index=1; line_index<=server_line_count; line_index++) {
                    print server_lines[line_index]
                }
            }
            for (line_index=1; line_index<=server_line_count; line_index++) {
                delete server_lines[line_index]
            }
            server_line_count=0
        }
        {
            line=$0
            sub(/[[:space:]]*#.*/, "", line)

            if (!in_server && line ~ /^[[:space:]]*server[[:space:]]*\{/) {
                in_server=1
                depth=0
                domain=""
                has_tls=0
                has_hsts=0
                server_line_count=0
            }
            if (!in_server) {
                print $0
                next
            }

            server_lines[++server_line_count]=$0
            if (depth == 1 && line ~ /^[[:space:]]*server_name[[:space:]]+/) {
                names=line
                sub(/^[[:space:]]*server_name[[:space:]]+/, "", names)
                sub(/[[:space:]]*;.*/, "", names)
                name_count=split(names, name_parts, /[[:space:]]+/)
                for (i=1; i<=name_count; i++) {
                    name=name_parts[i]
                    sub(/;$/, "", name)
                    if (name != "_" && name ~ /^[A-Za-z0-9*_.-]+$/ &&
                        name ~ /\./ && name !~ /\.\./) {
                        domain=name
                        break
                    }
                }
            }
            if (depth == 1 && line ~ /^[[:space:]]*listen[[:space:]]+/) {
                listen=line
                sub(/^[[:space:]]*listen[[:space:]]+/, "", listen)
                sub(/;.*/, "", listen)
                listen_count=split(listen, listen_parts, /[[:space:]]+/)
                for (i=1; i<=listen_count; i++) {
                    if (listen_parts[i] == "ssl") {
                        has_tls=1
                    }
                }
            }
            if (depth == 1 && line ~ /^[[:space:]]*add_header[[:space:]]+Strict-Transport-Security[[:space:]]+"max-age=31536000; includeSubDomains"[[:space:]]+always[[:space:]]*;[[:space:]]*$/) {
                has_hsts=1
            }

            braces=line
            depth+=gsub(/\{/, "{", braces)
            depth-=gsub(/\}/, "}", braces)
            if (depth == 0) {
                flush_server()
                in_server=0
            }
        }
        END {
            if (in_server) {
                exit 4
            }
        }
    ' "$config_file"
}

_tls_hsts_restore_config() {
    local backup_file="$1"
    local temp_file="$2"

    cp -p -- "$backup_file" "$temp_file" && mv -f -- "$temp_file" "$NODE_NGINX_CONF"
}

enable_tls_hsts() {
    local config_state inspect_status missing_count domains
    local services running_nginx backup_file temp_file

    header "Заглушка: TLS 1.2, TLS 1.3 и HSTS"

    if [ ! -f "$NODE_NGINX_CONF" ]; then
        error "Файл конфигурации не найден: $NODE_NGINX_CONF"
        pause
        return 1
    fi
    if [ -L "$NODE_NGINX_CONF" ]; then
        error "Файл $NODE_NGINX_CONF является ссылкой; автоматическая замена не поддерживается."
        pause
        return 1
    fi
    check_command awk || { pause; return 1; }
    check_command grep || { pause; return 1; }

    config_state="$(_tls_hsts_inspect_config "$NODE_NGINX_CONF")"
    inspect_status=$?
    case "$inspect_status" in
        0) ;;
        2) error "Не найден TLS server-блок с доменным именем в $NODE_NGINX_CONF." ;;
        3) error "В TLS server-блоке уже задана другая директива Strict-Transport-Security; автоматическое изменение отменено." ;;
        *) error "Не удалось разобрать server-блоки в $NODE_NGINX_CONF." ;;
    esac
    if [ "$inspect_status" -ne 0 ]; then
        pause
        return 1
    fi

    IFS='|' read -r missing_count domains <<< "$config_state"
    if [ "$missing_count" -eq 0 ]; then
        success "Заголовок HSTS уже настроен в TLS server-блоках: $domains"
        pause
        return 0
    fi

    check_docker || { pause; return 1; }
    check_command mktemp || { pause; return 1; }
    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл Docker Compose не найден: $COMPOSE_FILE"
        pause
        return 1
    fi
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

    if ! backup_config_file "$NODE_NGINX_CONF" backup_file; then
        error "Не удалось создать резервную копию nginx.conf."
        pause
        return 1
    fi
    if ! temp_file="$(mktemp "${NODE_NGINX_CONF}.remnasuper.XXXXXX")" ||
        ! cp -p -- "$backup_file" "$temp_file"; then
        [ -n "$temp_file" ] && rm -f -- "$temp_file"
        error "Не удалось подготовить временный файл для nginx.conf."
        pause
        return 1
    fi
    if ! _tls_hsts_transform_config "$backup_file" > "$temp_file"; then
        rm -f -- "$temp_file"
        error "Не удалось подготовить nginx.conf. Исходный файл не изменён."
        pause
        return 1
    fi

    step "Добавление HSTS для доменов: $domains..."
    if ! mv -f -- "$temp_file" "$NODE_NGINX_CONF"; then
        rm -f -- "$temp_file"
        error "Не удалось установить обновлённый nginx.conf."
        pause
        return 1
    fi

    if ! (cd "$NODE_DIR" && docker compose exec -T remnawave-nginx nginx -t); then
        error "Новая конфигурация nginx не прошла проверку; восстановление прежнего файла..."
        if ! _tls_hsts_restore_config "$backup_file" "$temp_file"; then
            error "Не удалось восстановить nginx.conf из $backup_file."
        fi
        rm -f -- "$temp_file"
        pause
        return 1
    fi

    if ! restart_remnanode_compose ||
        ! running_nginx="$(cd "$NODE_DIR" && docker compose ps --status running -q remnawave-nginx)" ||
        [ -z "$running_nginx" ] ||
        ! (cd "$NODE_DIR" && docker compose exec -T remnawave-nginx nginx -t); then
        error "Нода не запустилась с новой конфигурацией; восстановление прежнего nginx.conf..."
        if _tls_hsts_restore_config "$backup_file" "$temp_file"; then
            restart_remnanode_compose || warn "Не удалось перезапустить ноду после отката."
        else
            error "Не удалось восстановить nginx.conf из $backup_file."
        fi
        rm -f -- "$temp_file"
        pause
        return 1
    fi

    success "Заголовок HSTS добавлен в TLS server-блоки: $domains"
    pause
}
