#!/usr/bin/env bash

install_zapret() {
    header "Установка ss-zapret"
    local env_file="$ZAPRET_DIR/.env"
    local password
    local health_status=""
    local attempt
    local required_variable
    local node_network
    local socks_port

    check_docker || { pause; return; }
    check_command apt-get || { pause; return; }

    node_network="$(docker inspect -f '{{.HostConfig.NetworkMode}}' remnanode 2>/dev/null || true)"
    if [ "$node_network" != "host" ] && ! awk '
        /^services:[[:space:]]*$/ { in_services=1; next }
        in_services && /^[^[:space:]#][^:]*:/ { in_services=0 }
        in_services && /^  remnanode:[[:space:]]*$/ { in_remnanode=1; next }
        in_remnanode && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { in_remnanode=0 }
        in_remnanode && /^[[:space:]]*network_mode:[[:space:]]*["'\'']?host["'\'']?[[:space:]]*$/ { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$COMPOSE_FILE" 2>/dev/null; then
        error "RemnaNode не использует network_mode: host."
        warn "Без host-сети Xray не сможет подключиться к локальному SOCKS5 на 127.0.0.1:1080."
        pause
        return
    fi

    step "Установка git, curl и openssl..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update ||
        ! DEBIAN_FRONTEND=noninteractive apt-get install -y git curl openssl; then
        error "Не удалось установить зависимости ss-zapret."
        pause
        return
    fi

    if [ -e "$ZAPRET_DIR" ] && [ ! -d "$ZAPRET_DIR/.git" ]; then
        error "$ZAPRET_DIR уже существует, но не является репозиторием ss-zapret."
        pause
        return
    fi

    if [ -d "$ZAPRET_DIR/.git" ]; then
        step "Обновление существующего репозитория ss-zapret..."
        if ! git -C "$ZAPRET_DIR" pull --ff-only; then
            error "Не удалось обновить ss-zapret. Проверьте локальные изменения в $ZAPRET_DIR."
            pause
            return
        fi
    else
        step "Клонирование vernette/ss-zapret в $ZAPRET_DIR..."
        if ! git clone "$ZAPRET_REPO" "$ZAPRET_DIR"; then
            error "Не удалось клонировать ss-zapret."
            pause
            return
        fi
    fi

    if [ ! -f "$ZAPRET_DIR/config" ]; then
        step "Создание конфигурации zapret из config.default..."
        cp "$ZAPRET_DIR/config.default" "$ZAPRET_DIR/config" || {
            error "Не удалось создать $ZAPRET_DIR/config."
            pause
            return
        }
    else
        info "Существующий конфиг zapret сохранён: $ZAPRET_DIR/config"
    fi

    if [ ! -f "$env_file" ]; then
        if ! password="$(openssl rand -hex 24)" || [ -z "$password" ]; then
            error "Не удалось сгенерировать пароль для ss-zapret."
            pause
            return
        fi
        step "Создание защищённого .env..."
        {
            printf "SS_PORT=8388\n"
            printf "SOCKS_PORT=1080\n"
            printf "SS_PASSWORD=%s\n" "$password"
            printf "SS_ENCRYPT_METHOD=chacha20-ietf-poly1305\n"
            printf "SS_TIMEOUT=300\n"
        } > "$env_file"
        chmod 600 "$env_file"
    else
        info "Существующий .env сохранён: $env_file"
        for required_variable in SS_PORT SOCKS_PORT SS_PASSWORD SS_ENCRYPT_METHOD SS_TIMEOUT; do
            if ! grep -q "^${required_variable}=" "$env_file"; then
                error "В $env_file отсутствует переменная $required_variable."
                pause
                return
            fi
        done
    fi
    chmod 600 "$env_file"

    socks_port="$(sed -n 's/^SOCKS_PORT=//p' "$env_file" | tail -n 1)"
    if ! [[ "$socks_port" =~ ^[0-9]+$ ]] || [ "$socks_port" -lt 1 ] || [ "$socks_port" -gt 65535 ]; then
        error "Некорректный SOCKS_PORT в $env_file: $socks_port"
        pause
        return
    fi

    step "Проверка Docker Compose конфигурации..."
    if ! (cd "$ZAPRET_DIR" && docker compose config >/dev/null); then
        error "Конфигурация Docker Compose ss-zapret содержит ошибку."
        pause
        return
    fi

    step "Загрузка образа и запуск ss-zapret..."
    if ! (cd "$ZAPRET_DIR" && docker compose pull && docker compose up -d); then
        error "Не удалось запустить контейнер ss-zapret."
        pause
        return
    fi

    step "Ожидание готовности zapret-proxy..."
    for ((attempt = 1; attempt <= 30; attempt++)); do
        health_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' zapret-proxy 2>/dev/null || true)"
        case "$health_status" in
            healthy|running) break ;;
            unhealthy|exited|dead) break ;;
        esac
        sleep 1
    done

    if [ "$health_status" != "healthy" ] && [ "$health_status" != "running" ]; then
        error "Контейнер zapret-proxy не готов. Статус: ${health_status:-неизвестен}."
        (cd "$ZAPRET_DIR" && docker compose logs --tail 30) || true
        pause
        return
    fi
    success "Контейнер zapret-proxy запущен и готов."

    if curl -4 --proxy "socks5h://127.0.0.1:${socks_port}" --connect-timeout 10 --max-time 20 -sS -o /dev/null https://www.youtube.com/; then
        success "SOCKS5-прокси на 127.0.0.1:${socks_port} успешно прошёл проверку."
    else
        warn "SOCKS5 доступен, но проверка YouTube не прошла. Возможно, для провайдера потребуется подобрать стратегию через blockcheck.sh."
    fi

    cat > "$ZAPRET_OUTBOUND_FILE" << EOF
{
  "tag": "zapret",
  "protocol": "socks",
  "settings": {
    "address": "127.0.0.1",
    "port": $socks_port
  }
}
EOF
    chmod 644 "$ZAPRET_OUTBOUND_FILE"

    success "Установка ss-zapret завершена."
    info "Outbound сохранён в $ZAPRET_OUTBOUND_FILE"
    section "Готовый outbound для Xray"
    printf "Добавьте этот объект в массив outbounds конфигурации Xray:\n\n"
    cat "$ZAPRET_OUTBOUND_FILE"
    printf "\n"
    pause
}

