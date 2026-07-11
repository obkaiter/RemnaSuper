#!/usr/bin/env bash

restart_node() {
    header "Перезапуск ноды"
    check_docker || { pause; return; }

    warn "Подключения прервутся примерно на 5-10 секунд."
    restart_remnanode_compose
    pause
}

restart_agent() {
    header "Перезапуск агента"
    check_docker || { pause; return; }

    if [ -d "$AGENT_DIR" ]; then
        if (cd "$AGENT_DIR" && docker compose restart >/dev/null 2>&1); then
            success "Агент перезапущен."
        else
            error "Ошибка при перезапуске агента."
        fi
    else
        error "Папка агента не найдена: $AGENT_DIR"
    fi
    pause
}

initial_setup() {
    header "Первоначальная настройка"
    check_command apt-get || { pause; return; }
    check_command sudo || { pause; return; }

    step "apt-get update..."
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get update; then
        error "apt-get update завершился с ошибкой."
        pause
        return
    fi

    step "apt-get upgrade..."
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -o com.ubuntu.ipt.needrestart=0; then
        error "apt-get upgrade завершился с ошибкой."
        pause
        return
    fi
    success "apt update && apt upgrade выполнены."

    step "Установка cron, mc и wget..."
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cron mc wget; then
        success "cron, mc и wget установлены."
    else
        error "Не удалось установить cron, mc и wget."
    fi

    pause
}

install_remnawave_reverse_proxy() {
    header "Установка remnawave-reverse-proxy"
    check_command curl || { pause; return; }
    check_command bash || { pause; return; }

    step "Запуск install_remnawave.sh..."
    if bash <(curl -Ls https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh); then
        success "remnawave-reverse-proxy установлен."
    else
        error "Установка remnawave-reverse-proxy завершилась с ошибкой."
    fi

    pause
}

follow_until_interrupt() {
    local interrupted=0
    local command_status

    trap 'interrupted=1' INT
    "$@"
    command_status=$?
    trap - INT

    if [ "$interrupted" -eq 1 ] || [ "$command_status" -gt 128 ]; then
        printf "\n"
        info "Просмотр остановлен."
    fi
    pause
}

view_errors() {
    header "Просмотр ошибок"
    check_docker || { pause; return; }

    follow_until_interrupt docker exec -it remnanode tail -n +1 -f /var/log/supervisor/xray.out.log
}

view_xray_logs() {
    header "Просмотр логов Xray"
    follow_until_interrupt tail -f /var/log/remnanode/access.log
}

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

ensure_ss_zapret_running() {
    local health_status=""
    local attempt

    check_docker || return 1

    if [ ! -f "$ZAPRET_DIR/docker-compose.yml" ]; then
        error "ss-zapret не установлен. Сначала выполните пункт 'Установить ss-zapret'."
        return 1
    fi

    if ! (cd "$ZAPRET_DIR" && docker compose up -d); then
        error "Не удалось запустить ss-zapret."
        return 1
    fi

    for ((attempt = 1; attempt <= 30; attempt++)); do
        health_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' zapret-proxy 2>/dev/null || true)"
        case "$health_status" in
            healthy|running) return 0 ;;
            unhealthy|exited|dead) break ;;
        esac
        sleep 1
    done

    error "Контейнер zapret-proxy не готов. Статус: ${health_status:-неизвестен}."
    return 1
}

get_ss_zapret_socks_port() {
    local env_file="$ZAPRET_DIR/.env"
    local socks_port

    [ -f "$env_file" ] || return 1
    socks_port="$(sed -n 's/^SOCKS_PORT=//p' "$env_file" | tail -n 1)"
    if ! [[ "$socks_port" =~ ^[0-9]+$ ]] || [ "$socks_port" -lt 1 ] || [ "$socks_port" -gt 65535 ]; then
        return 1
    fi

    printf "%s" "$socks_port"
}

apply_zapret_strategy_from_log() {
    local search_log="$1"
    local http_strategy
    local https_strategy
    local quic_strategy
    local strategy_lines=()
    local strategy_block=""
    local config_file="$ZAPRET_DIR/config"
    local backup_file
    local tmp_file
    local index
    local strategy

    http_strategy="$(awk '
        /^\* SUMMARY/ { in_summary=1; next }
        in_summary && /^Please note/ { exit }
        in_summary && /^curl_test_http ipv4 .* : nfqws / {
            sub(/^.* : nfqws /, "")
            sub(/\r$/, "")
            print
            exit
        }
    ' "$search_log")"
    https_strategy="$(awk '
        /^\* SUMMARY/ { in_summary=1; next }
        in_summary && /^Please note/ { exit }
        in_summary && /^curl_test_https_tls(12|13) ipv4 .* : nfqws / {
            sub(/^.* : nfqws /, "")
            sub(/\r$/, "")
            print
            exit
        }
    ' "$search_log")"
    quic_strategy="$(awk '
        /^\* SUMMARY/ { in_summary=1; next }
        in_summary && /^Please note/ { exit }
        in_summary && /^curl_test_http3 ipv4 .* : nfqws / {
            sub(/^.* : nfqws /, "")
            sub(/\r$/, "")
            print
            exit
        }
    ' "$search_log")"

    for strategy in "$http_strategy" "$https_strategy" "$quic_strategy"; do
        if [[ "$strategy" == *'"'* ]] || [[ "$strategy" == *'`'* ]] ||
            [[ "$strategy" == *'$'* ]] || [[ "$strategy" == *'\\'* ]] ||
            [[ "$strategy" == *';'* ]] || [[ "$strategy" == *'|'* ]] ||
            [[ "$strategy" == *'&'* ]]; then
            error "Найденная стратегия содержит небезопасные символы. Конфигурация не изменена."
            return 1
        fi
    done

    [ -n "$http_strategy" ] && strategy_lines+=("--filter-tcp=80 $http_strategy")
    [ -n "$https_strategy" ] && strategy_lines+=("--filter-tcp=443 $https_strategy")
    [ -n "$quic_strategy" ] && strategy_lines+=("--filter-udp=443 $quic_strategy")

    if [ "${#strategy_lines[@]}" -eq 0 ]; then
        warn "Blockcheck не нашёл стратегий, требующих применения. Текущий NFQWS_OPT сохранён."
        return 2
    fi

    for index in "${!strategy_lines[@]}"; do
        strategy_block+="${strategy_lines[$index]}"
        if [ "$index" -lt "$((${#strategy_lines[@]} - 1))" ]; then
            strategy_block+=" --new"
        fi
        strategy_block+=$'\n'
    done
    strategy_block="${strategy_block%$'\n'}"

    if [ ! -f "$config_file" ]; then
        error "Конфигурация ss-zapret не найдена: $config_file"
        return 1
    fi

    backup_file="${config_file}.bak.$(date +%F_%H%M%S)"
    tmp_file="$(mktemp)" || {
        error "Не удалось создать временный файл для конфигурации ss-zapret."
        return 1
    }

    if ! awk -v strategy_block="$strategy_block" '
        /^NFQWS_OPT="/ && !replaced {
            print "NFQWS_OPT=\""
            print strategy_block
            in_block=1
            replaced=1
            next
        }
        in_block {
            if (/^"[[:space:]]*$/) {
                print "\""
                in_block=0
            }
            next
        }
        { print }
        END {
            if (!replaced || in_block) {
                exit 42
            }
        }
    ' "$config_file" > "$tmp_file"; then
        rm -f "$tmp_file"
        error "Не удалось заменить NFQWS_OPT в $config_file."
        return 1
    fi

    if ! bash -n "$tmp_file"; then
        rm -f "$tmp_file"
        error "Сформированная конфигурация не прошла проверку синтаксиса."
        return 1
    fi

    if ! cp "$config_file" "$backup_file" || ! mv "$tmp_file" "$config_file"; then
        rm -f "$tmp_file"
        error "Не удалось сохранить новую конфигурацию ss-zapret."
        return 1
    fi

    success "Найденная стратегия автоматически записана в NFQWS_OPT."
    info "Бэкап предыдущей конфигурации: $backup_file"
    printf "\n${CYAN}Применённая конфигурация:${NC}\n%s\n" "$strategy_block"
    ZAPRET_APPLIED_CONFIG_BACKUP="$backup_file"
    return 0
}

search_zapret_strategy() {
    header "Поиск стратегии ss-zapret"
    local interrupted=0
    local search_status
    local restart_status
    local apply_status=2
    local search_log
    local rollback_status=1

    ZAPRET_APPLIED_CONFIG_BACKUP=""

    ensure_ss_zapret_running || { pause; return; }
    check_command tee || { pause; return; }

    step "Проверка компонентов blockcheck..."
    if ! (cd "$ZAPRET_DIR" && docker compose exec ss-zapret sh -c '
        [ -x /opt/zapret/nfq/nfqws ] && [ -x /opt/zapret/mdig/mdig ]
    '); then
        error "В контейнере отсутствуют nfqws или mdig. Обновите образ через пункт установки ss-zapret."
        pause
        return
    fi

    if ! (cd "$ZAPRET_DIR" && docker compose exec ss-zapret sh -c '
        command -v nslookup >/dev/null 2>&1 || command -v host >/dev/null 2>&1
    '); then
        step "Установка bind-tools внутри контейнера для blockcheck..."
        if ! (cd "$ZAPRET_DIR" && docker compose exec ss-zapret apk add --no-cache bind-tools); then
            error "Не удалось установить bind-tools внутри контейнера ss-zapret."
            pause
            return
        fi
    fi

    step "Остановка zapret перед поиском стратегии..."
    if ! (cd "$ZAPRET_DIR" && docker compose exec ss-zapret sh /opt/zapret/init.d/sysv/zapret stop); then
        error "Не удалось остановить zapret внутри контейнера."
        pause
        return
    fi

    search_log="$(mktemp)" || {
        error "Не удалось создать временный файл для результата blockcheck."
        (cd "$ZAPRET_DIR" && docker compose restart) || true
        pause
        return
    }

    step "Запуск интерактивного blockcheck.sh..."
    trap 'interrupted=1' INT
    (cd "$ZAPRET_DIR" && docker compose exec -T ss-zapret sh -c 'SKIP_TPWS=1 /opt/zapret/blockcheck.sh') 2>&1 | tee "$search_log"
    search_status="${PIPESTATUS[0]}"
    trap - INT

    if [ "$interrupted" -eq 0 ] && [ "$search_status" -eq 0 ]; then
        step "Автоматическое применение найденной стратегии..."
        apply_zapret_strategy_from_log "$search_log"
        apply_status=$?
    fi
    rm -f "$search_log"

    step "Повторный запуск ss-zapret..."
    if (cd "$ZAPRET_DIR" && docker compose restart) && ensure_ss_zapret_running; then
        restart_status=0
    else
        restart_status=1
    fi

    if [ "$restart_status" -ne 0 ] && [ "$apply_status" -eq 0 ] &&
        [ -f "$ZAPRET_APPLIED_CONFIG_BACKUP" ]; then
        warn "Новая стратегия не запустилась. Восстановление предыдущей конфигурации..."
        if cp "$ZAPRET_APPLIED_CONFIG_BACKUP" "$ZAPRET_DIR/config" &&
            (cd "$ZAPRET_DIR" && docker compose restart) && ensure_ss_zapret_running; then
            rollback_status=0
        fi
    fi

    if [ "$restart_status" -ne 0 ] && [ "$rollback_status" -eq 0 ]; then
        error "Новая стратегия не применена: предыдущая конфигурация автоматически восстановлена."
    elif [ "$restart_status" -ne 0 ]; then
        error "Поиск завершён, но контейнер ss-zapret не удалось перезапустить."
    elif [ "$interrupted" -eq 1 ] || [ "$search_status" -gt 128 ]; then
        warn "Поиск стратегии прерван. Контейнер ss-zapret снова запущен."
    elif [ "$search_status" -eq 0 ] && [ "$apply_status" -eq 0 ]; then
        success "Поиск завершён, найденная стратегия применена, ss-zapret перезапущен."
    elif [ "$search_status" -eq 0 ] && [ "$apply_status" -eq 2 ]; then
        success "Поиск завершён. Изменение стратегии не потребовалось, ss-zapret перезапущен."
    elif [ "$search_status" -eq 0 ]; then
        error "Поиск завершён, но автоматически применить стратегию не удалось."
    else
        error "blockcheck.sh завершился с ошибкой: $search_status"
    fi
    pause
}

run_zapret_censorcheck() {
    header "Censorcheck ss-zapret"
    local socks_port
    local script_file
    local interrupted=0
    local check_status

    ensure_ss_zapret_running || { pause; return; }
    check_command curl || { pause; return; }
    check_command bash || { pause; return; }
    check_command apt-get || { pause; return; }

    if ! command -v dig >/dev/null 2>&1 ||
        ! command -v jq >/dev/null 2>&1 ||
        ! command -v column >/dev/null 2>&1; then
        step "Установка зависимостей censorcheck..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get update ||
            ! DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils jq bsdextrautils; then
            error "Не удалось установить зависимости censorcheck: dig, jq и column."
            pause
            return
        fi
    fi

    if ! socks_port="$(get_ss_zapret_socks_port)"; then
        error "Не удалось определить SOCKS_PORT в $ZAPRET_DIR/.env."
        pause
        return
    fi

    script_file="$(mktemp)" || {
        error "Не удалось создать временный файл для censorcheck."
        pause
        return
    }

    step "Загрузка официального censorcheck.sh..."
    if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$script_file" "$CENSORCHECK_URL"; then
        rm -f "$script_file"
        error "Не удалось скачать censorcheck.sh."
        pause
        return
    fi

    step "Запуск censorcheck через localhost:${socks_port}..."
    trap 'interrupted=1' INT
    bash "$script_file" --mode dpi --proxy "localhost:${socks_port}"
    check_status=$?
    trap - INT
    rm -f "$script_file"

    if [ "$interrupted" -eq 1 ] || [ "$check_status" -gt 128 ]; then
        warn "Censorcheck прерван."
    elif [ "$check_status" -eq 0 ]; then
        success "Censorcheck завершён."
    else
        error "Censorcheck завершился с ошибкой: $check_status"
    fi
    pause
}

uninstall_ss_zapret() {
    header "Удаление ss-zapret"

    check_docker || { pause; return; }
    if [ "$ZAPRET_DIR" != "/opt/ss-zapret" ]; then
        error "Небезопасный путь удаления: $ZAPRET_DIR"
        pause
        return
    fi

    if [ ! -e "$ZAPRET_DIR" ]; then
        warn "ss-zapret не установлен: $ZAPRET_DIR не найден."
        pause
        return
    fi

    if [ -f "$ZAPRET_DIR/docker-compose.yml" ]; then
        step "Остановка контейнера и удаление образа ss-zapret..."
        if ! (cd "$ZAPRET_DIR" && docker compose down --rmi all --remove-orphans); then
            error "Не удалось полностью остановить ss-zapret. Файлы не удалены."
            pause
            return
        fi
    fi

    step "Удаление $ZAPRET_DIR..."
    if rm -rf -- "$ZAPRET_DIR"; then
        success "ss-zapret, его конфигурация и Xray outbound удалены."
    else
        error "Не удалось удалить $ZAPRET_DIR."
    fi
    pause
}

install_tspu_checker() {
    header "Установка tspu checker"
    check_command apt || { pause; return; }
    check_command git || { pause; return; }
    check_command sudo || { pause; return; }

    sudo apt install -y hping3 nmap netcat-openbsd openssl dnsutils curl || {
        error "Не удалось установить зависимости tspu checker."
        pause
        return
    }
    cd /opt || { error "Не удалось перейти в /opt."; pause; return; }
    git clone https://github.com/ku78/tspu-checker.git || {
        error "Не удалось клонировать tspu-checker."
        pause
        return
    }
    cd tspu-checker || { error "Каталог /opt/tspu-checker не найден."; pause; return; }
    chmod +x tspu_check.sh
    sudo ./tspu_check.sh
    pause
}

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

run_node_accelerator() {
    header "Выполнение Node Accelerator"
    check_command curl || { pause; return; }
    check_command sudo || { pause; return; }

    step "Запуск Node Accelerator..."
    curl -fsSL https://raw.githubusercontent.com/jestivald/node-accelerator/main/install.sh | sudo bash -s all

    local pipe_status=("${PIPESTATUS[@]}")
    local curl_exit="${pipe_status[0]}"
    local bash_exit="${pipe_status[1]}"
    if [ "$curl_exit" -eq 0 ] && [ "$bash_exit" -eq 0 ]; then
        success "Node Accelerator выполнен."
    else
        error "Node Accelerator завершился с ошибкой. curl: $curl_exit, bash: $bash_exit"
    fi

    pause
}

exit_menu() {
    header "Завершение"
    success "Готово."
    exit 0
}
