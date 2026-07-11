#!/usr/bin/env bash

install_zapret() {
    header "Установка ss-zapret2"
    local env_file="$ZAPRET_DIR/.env"
    local legacy_env_file=""
    local legacy_compose_file=""
    local legacy_was_running=0
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
        error "Не удалось установить зависимости ss-zapret2."
        pause
        return
    fi

    if [ -d "$ZAPRET_LEGACY_DIR" ] && [ "$ZAPRET_LEGACY_DIR" != "$ZAPRET_DIR" ]; then
        [ -f "$ZAPRET_LEGACY_DIR/.env" ] && legacy_env_file="$ZAPRET_LEGACY_DIR/.env"
        if [ -f "$ZAPRET_LEGACY_DIR/docker-compose.yml" ]; then
            legacy_compose_file="$ZAPRET_LEGACY_DIR/docker-compose.yml"
            if (cd "$ZAPRET_LEGACY_DIR" && docker compose ps --status running -q 2>/dev/null | grep -q .); then
                legacy_was_running=1
            fi
        fi
        info "Обнаружена прежняя версия в $ZAPRET_LEGACY_DIR; её файлы будут сохранены."
    fi

    if [ -e "$ZAPRET_DIR" ] && [ ! -d "$ZAPRET_DIR/.git" ]; then
        error "$ZAPRET_DIR уже существует, но не является репозиторием ss-zapret2."
        pause
        return
    fi

    if [ -d "$ZAPRET_DIR/.git" ]; then
        step "Обновление существующего репозитория ss-zapret2..."
        if ! git -C "$ZAPRET_DIR" pull --ff-only; then
            error "Не удалось обновить ss-zapret2. Проверьте локальные изменения в $ZAPRET_DIR."
            pause
            return
        fi
    else
        step "Клонирование vernette/ss-zapret2 в $ZAPRET_DIR..."
        if ! git clone "$ZAPRET_REPO" "$ZAPRET_DIR"; then
            error "Не удалось клонировать ss-zapret2."
            pause
            return
        fi
    fi

    if [ ! -f "$ZAPRET_DIR/config" ]; then
        step "Создание конфигурации zapret2 из config.default..."
        cp "$ZAPRET_DIR/config.default" "$ZAPRET_DIR/config" || {
            error "Не удалось создать $ZAPRET_DIR/config."
            pause
            return
        }
    else
        info "Существующий конфиг zapret2 сохранён: $ZAPRET_DIR/config"
    fi

    if [ ! -f "$env_file" ]; then
        if [ -n "$legacy_env_file" ]; then
            step "Перенос настроек SOCKS5 и Shadowsocks из прежней версии..."
            if ! cp "$legacy_env_file" "$env_file"; then
                error "Не удалось перенести настройки из $legacy_env_file."
                pause
                return
            fi
        else
            if ! password="$(openssl rand -hex 24)" || [ -z "$password" ]; then
                error "Не удалось сгенерировать пароль для ss-zapret2."
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
                printf "SS_VERBOSE=0\n"
            } > "$env_file"
        fi
    else
        info "Существующий .env сохранён: $env_file"
    fi

    for required_variable in SS_PORT SOCKS_PORT SS_PASSWORD SS_ENCRYPT_METHOD SS_TIMEOUT; do
        if ! grep -q "^${required_variable}=" "$env_file"; then
            error "В $env_file отсутствует переменная $required_variable."
            pause
            return
        fi
    done
    if ! grep -q '^SS_VERBOSE=' "$env_file"; then
        printf "\nSS_VERBOSE=0\n" >> "$env_file"
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
        error "Конфигурация Docker Compose ss-zapret2 содержит ошибку."
        pause
        return
    fi

    if [ -n "$legacy_compose_file" ]; then
        step "Остановка прежней версии ss-zapret перед переходом на ss-zapret2..."
        if ! (cd "$ZAPRET_LEGACY_DIR" && docker compose down --remove-orphans); then
            error "Не удалось остановить прежний ss-zapret. Переход прерван, чтобы избежать конфликта портов."
            pause
            return
        fi
    fi

    step "Загрузка образа и запуск ss-zapret2..."
    if ! (cd "$ZAPRET_DIR" && docker compose pull && docker compose up -d); then
        error "Не удалось запустить контейнер ss-zapret2."
        if [ "$legacy_was_running" -eq 1 ] && (cd "$ZAPRET_LEGACY_DIR" && docker compose up -d); then
            warn "Прежний ss-zapret автоматически запущен снова."
        fi
        pause
        return
    fi

    step "Ожидание готовности $ZAPRET_CONTAINER..."
    for ((attempt = 1; attempt <= 30; attempt++)); do
        health_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$ZAPRET_CONTAINER" 2>/dev/null || true)"
        case "$health_status" in
            healthy|running) break ;;
            unhealthy|exited|dead) break ;;
        esac
        sleep 1
    done

    if [ "$health_status" != "healthy" ] && [ "$health_status" != "running" ]; then
        error "Контейнер $ZAPRET_CONTAINER не готов. Статус: ${health_status:-неизвестен}."
        (cd "$ZAPRET_DIR" && docker compose logs --tail 30) || true
        if [ "$legacy_was_running" -eq 1 ]; then
            (cd "$ZAPRET_DIR" && docker compose down --remove-orphans) || true
            if (cd "$ZAPRET_LEGACY_DIR" && docker compose up -d); then
                warn "Прежний ss-zapret автоматически запущен снова."
            fi
        fi
        pause
        return
    fi
    success "Контейнер $ZAPRET_CONTAINER запущен и готов."

    if curl -4 --proxy "socks5h://127.0.0.1:${socks_port}" --connect-timeout 10 --max-time 20 -sS -o /dev/null https://www.youtube.com/; then
        success "SOCKS5-прокси на 127.0.0.1:${socks_port} успешно прошёл проверку."
    else
        warn "SOCKS5 доступен, но проверка YouTube не прошла. Возможно, для провайдера потребуется подобрать стратегию через blockcheck2.sh."
    fi

    cat > "$ZAPRET_OUTBOUND_FILE" << EOF
{
  "tag": "zapret",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": $socks_port
      }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "none",
    "tcpSettings": {
      "header": {
        "type": "none"
      }
    }
  }
}
EOF
    chmod 644 "$ZAPRET_OUTBOUND_FILE"

    success "Установка ss-zapret2 завершена."
    info "Outbound сохранён в $ZAPRET_OUTBOUND_FILE"
    section "Готовый outbound для Xray"
    printf "Добавьте этот объект в массив outbounds конфигурации Xray:\n\n"
    cat "$ZAPRET_OUTBOUND_FILE"
    printf "\n"
    pause
}
