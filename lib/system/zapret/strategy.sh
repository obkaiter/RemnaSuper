#!/usr/bin/env bash

_read_zapret_strategy_from_config() {
    local config_file="$1"

    awk '
        /^NFQWS2_OPT="/ && !found {
            found=1
            line=$0
            sub(/^NFQWS2_OPT="/, "", line)
            if (line ~ /"[[:space:]]*$/) {
                sub(/"[[:space:]]*$/, "", line)
                closed=1
                print line
                exit
            }
            if (length(line) > 0) {
                print line
            }
            in_block=1
            next
        }
        in_block {
            if (/^"[[:space:]]*$/) {
                closed=1
                exit
            }
            print
        }
        END {
            if (!found || !closed) {
                exit 42
            }
        }
    ' "$config_file"
}

_write_zapret_strategy_to_config() {
    local strategy_block="$1"
    local config_file="$ZAPRET_DIR/config"
    local backup_file
    local tmp_file

    if [ ! -f "$config_file" ]; then
        error "Конфигурация ss-zapret2 не найдена: $config_file"
        return 1
    fi

    backup_file="${config_file}.bak.$(date +%F_%H%M%S)"
    tmp_file="$(mktemp)" || {
        error "Не удалось создать временный файл для конфигурации ss-zapret2."
        return 1
    }

    if ! awk -v strategy_block="$strategy_block" '
        /^NFQWS2_OPT="/ && !replaced {
            print "NFQWS2_OPT=\""
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
        error "Не удалось заменить NFQWS2_OPT в $config_file."
        return 1
    fi

    if ! bash -n "$tmp_file"; then
        rm -f "$tmp_file"
        error "Сформированная конфигурация не прошла проверку синтаксиса."
        return 1
    fi

    if ! cp "$config_file" "$backup_file" || ! mv "$tmp_file" "$config_file"; then
        rm -f "$tmp_file"
        error "Не удалось сохранить новую конфигурацию ss-zapret2."
        return 1
    fi

    ZAPRET_APPLIED_CONFIG_BACKUP="$backup_file"
    return 0
}

apply_zapret_strategy_from_log() {
    local search_log="$1"
    local http_strategy
    local https_strategy
    local quic_strategy
    local strategy_lines=()
    local strategy_block=""
    local index
    local strategy

    http_strategy="$(awk '
        /^\* SUMMARY/ { in_summary=1; next }
        in_summary && /^Please note/ { exit }
        in_summary && /^curl_test_http ipv4 .* : nfqws2 / {
            sub(/^.* : nfqws2 /, "")
            sub(/^--wf-l3=ipv4[[:space:]]+/, "")
            sub(/^--wf-tcp-out=80[[:space:]]+/, "")
            sub(/\r$/, "")
            print
            exit
        }
    ' "$search_log")"
    https_strategy="$(awk '
        /^\* SUMMARY/ { in_summary=1; next }
        in_summary && /^Please note/ { exit }
        in_summary && /^curl_test_https_tls(12|13) ipv4 .* : nfqws2 / {
            sub(/^.* : nfqws2 /, "")
            sub(/^--wf-l3=ipv4[[:space:]]+/, "")
            sub(/^--wf-tcp-out=443[[:space:]]+/, "")
            sub(/\r$/, "")
            print
            exit
        }
    ' "$search_log")"
    quic_strategy="$(awk '
        /^\* SUMMARY/ { in_summary=1; next }
        in_summary && /^Please note/ { exit }
        in_summary && /^curl_test_http3 ipv4 .* : nfqws2 / {
            sub(/^.* : nfqws2 /, "")
            sub(/^--wf-l3=ipv4[[:space:]]+/, "")
            sub(/^--wf-udp-out=443[[:space:]]+/, "")
            sub(/\r$/, "")
            print
            exit
        }
    ' "$search_log")"

    for strategy in "$http_strategy" "$https_strategy" "$quic_strategy"; do
        if [[ "$strategy" == *'"'* ]] || [[ "$strategy" == *'`'* ]] ||
            [[ "$strategy" == *'$'* ]] || [[ "$strategy" == *\\* ]] ||
            [[ "$strategy" == *';'* ]] || [[ "$strategy" == *'|'* ]] ||
            [[ "$strategy" == *'&'* ]]; then
            error "Найденная стратегия содержит небезопасные символы. Конфигурация не изменена."
            return 1
        fi
    done

    [ -n "$http_strategy" ] && strategy_lines+=("--filter-tcp=80 --filter-l7=http $http_strategy")
    [ -n "$https_strategy" ] && strategy_lines+=("--filter-tcp=443 --filter-l7=tls $https_strategy")
    [ -n "$quic_strategy" ] && strategy_lines+=("--filter-udp=443 --filter-l7=quic $quic_strategy")

    if [ "${#strategy_lines[@]}" -eq 0 ]; then
        warn "Blockcheck2 не нашёл стратегий, требующих применения. Текущий NFQWS2_OPT сохранён."
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

    if ! _write_zapret_strategy_to_config "$strategy_block"; then
        return 1
    fi

    success "Найденная стратегия автоматически записана в NFQWS2_OPT."
    info "Бэкап предыдущей конфигурации: $ZAPRET_APPLIED_CONFIG_BACKUP"
    printf "\n${CYAN}Применённая конфигурация:${NC}\n%s\n" "$strategy_block"
    return 0
}

show_current_zapret_strategy() {
    header "Текущая стратегия ss-zapret2"
    local config_file="$ZAPRET_DIR/config"
    local current_strategy

    if [ ! -f "$config_file" ]; then
        error "Конфигурация ss-zapret2 не найдена: $config_file"
        pause
        return
    fi

    if ! current_strategy="$(_read_zapret_strategy_from_config "$config_file")"; then
        error "Параметр NFQWS2_OPT не найден или имеет некорректный формат в $config_file."
        pause
        return
    fi

    section "NFQWS2_OPT"
    if [ -n "$current_strategy" ]; then
        printf "%s\n" "$current_strategy"
    else
        warn "Текущая стратегия пуста."
    fi
    pause
}

install_zapret_strategy_manually() {
    header "Ручная установка стратегии ss-zapret2"
    local config_file="$ZAPRET_DIR/config"
    local strategy_file
    local current_strategy
    local strategy_block
    local editor

    check_docker || { pause; return; }

    if [ ! -f "$config_file" ]; then
        error "Конфигурация ss-zapret2 не найдена: $config_file"
        pause
        return
    fi

    if command -v nano >/dev/null 2>&1; then
        editor="nano"
    elif command -v editor >/dev/null 2>&1; then
        editor="editor"
    elif command -v vi >/dev/null 2>&1; then
        editor="vi"
    else
        error "Текстовый редактор не найден. Установите nano и повторите попытку."
        pause
        return
    fi

    if ! current_strategy="$(_read_zapret_strategy_from_config "$config_file")"; then
        error "Параметр NFQWS2_OPT не найден или имеет некорректный формат в $config_file."
        pause
        return
    fi

    strategy_file="$(mktemp)" || {
        error "Не удалось создать временный файл для ручной стратегии."
        pause
        return
    }
    chmod 600 "$strategy_file"
    printf "%s\n" "$current_strategy" > "$strategy_file"

    info "Открывается редактор $editor. Укажите только параметры стратегии, без NFQWS2_OPT= и внешних кавычек."
    if ! "$editor" "$strategy_file"; then
        rm -f "$strategy_file"
        warn "Редактирование отменено. Конфигурация не изменена."
        pause
        return
    fi

    if ! grep -q '[^[:space:]]' "$strategy_file"; then
        rm -f "$strategy_file"
        error "Стратегия не может быть пустой. Конфигурация не изменена."
        pause
        return
    fi

    strategy_block="$(tr -d '\r' < "$strategy_file")"
    rm -f "$strategy_file"

    if [[ "$strategy_block" == *'"'* ]] || [[ "$strategy_block" == *'`'* ]] ||
        [[ "$strategy_block" == *'$'* ]] || [[ "$strategy_block" == *\\* ]] ||
        [[ "$strategy_block" == *';'* ]] || [[ "$strategy_block" == *'|'* ]] ||
        [[ "$strategy_block" == *'&'* ]]; then
        error "Стратегия содержит недопустимые управляющие символы. Конфигурация не изменена."
        pause
        return
    fi

    if ! printf "%s\n" "$strategy_block" | awk '
        NF && $0 !~ /^[[:space:]]*--/ { exit 1 }
    '; then
        error "Каждая непустая строка стратегии должна начинаться с '--'. Конфигурация не изменена."
        pause
        return
    fi

    if [ "$strategy_block" = "$current_strategy" ]; then
        info "Стратегия не была изменена."
        pause
        return
    fi

    ZAPRET_APPLIED_CONFIG_BACKUP=""
    step "Проверка и сохранение ручной стратегии..."
    if ! _write_zapret_strategy_to_config "$strategy_block"; then
        pause
        return
    fi

    step "Перезапуск ss-zapret2 с новой стратегией..."
    if (cd "$ZAPRET_DIR" && docker compose restart) && ensure_ss_zapret_running; then
        success "Ручная стратегия применена, контейнер ss-zapret2 запущен и готов."
        info "Бэкап предыдущей конфигурации: $ZAPRET_APPLIED_CONFIG_BACKUP"
        pause
        return
    fi

    warn "Контейнер не запустился с новой стратегией. Восстановление предыдущей конфигурации..."
    if [ -f "$ZAPRET_APPLIED_CONFIG_BACKUP" ] &&
        cp "$ZAPRET_APPLIED_CONFIG_BACKUP" "$config_file" &&
        (cd "$ZAPRET_DIR" && docker compose restart) &&
        ensure_ss_zapret_running; then
        error "Ручная стратегия не применена: предыдущая конфигурация автоматически восстановлена."
    else
        error "Не удалось запустить новую стратегию и автоматически восстановить предыдущую конфигурацию."
    fi
    pause
}

search_zapret_strategy() {
    header "Поиск стратегии ss-zapret2"
    local interrupted=0
    local search_status
    local restart_status
    local apply_status=2
    local search_log
    local rollback_status=1

    ZAPRET_APPLIED_CONFIG_BACKUP=""

    ensure_ss_zapret_running || { pause; return; }
    check_command tee || { pause; return; }

    step "Проверка компонентов blockcheck2..."
    if ! (cd "$ZAPRET_DIR" && docker compose exec "$ZAPRET_SERVICE" sh -c "
        [ -x '$ZAPRET_CONTAINER_DIR/nfq2/nfqws2' ] && [ -x '$ZAPRET_CONTAINER_DIR/mdig/mdig' ]
    "); then
        error "В контейнере отсутствуют nfqws2 или mdig. Обновите образ через пункт установки ss-zapret2."
        pause
        return
    fi

    if ! (cd "$ZAPRET_DIR" && docker compose exec "$ZAPRET_SERVICE" sh -c '
        command -v nslookup >/dev/null 2>&1 || command -v host >/dev/null 2>&1
    '); then
        step "Установка bind-tools внутри контейнера для blockcheck2..."
        if ! (cd "$ZAPRET_DIR" && docker compose exec "$ZAPRET_SERVICE" apk add --no-cache bind-tools); then
            error "Не удалось установить bind-tools внутри контейнера ss-zapret2."
            pause
            return
        fi
    fi

    step "Остановка zapret2 перед поиском стратегии..."
    if ! (cd "$ZAPRET_DIR" && docker compose exec "$ZAPRET_SERVICE" sh "$ZAPRET_CONTAINER_DIR/init.d/sysv/zapret2" stop); then
        error "Не удалось остановить zapret2 внутри контейнера."
        pause
        return
    fi

    search_log="$(mktemp)" || {
        error "Не удалось создать временный файл для результата blockcheck2."
        (cd "$ZAPRET_DIR" && docker compose restart) || true
        pause
        return
    }

    step "Запуск интерактивного blockcheck2.sh..."
    trap 'interrupted=1' INT
    (cd "$ZAPRET_DIR" && docker compose exec -T "$ZAPRET_SERVICE" sh "$ZAPRET_CONTAINER_DIR/blockcheck2.sh") 2>&1 | tee "$search_log"
    search_status="${PIPESTATUS[0]}"
    trap - INT

    if [ "$interrupted" -eq 0 ] && [ "$search_status" -eq 0 ]; then
        step "Автоматическое применение найденной стратегии..."
        apply_zapret_strategy_from_log "$search_log"
        apply_status=$?
    fi
    rm -f "$search_log"

    step "Повторный запуск ss-zapret2..."
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
        error "Поиск завершён, но контейнер ss-zapret2 не удалось перезапустить."
    elif [ "$interrupted" -eq 1 ] || [ "$search_status" -gt 128 ]; then
        warn "Поиск стратегии прерван. Контейнер ss-zapret2 снова запущен."
    elif [ "$search_status" -eq 0 ] && [ "$apply_status" -eq 0 ]; then
        success "Поиск завершён, найденная стратегия применена, ss-zapret2 перезапущен."
    elif [ "$search_status" -eq 0 ] && [ "$apply_status" -eq 2 ]; then
        success "Поиск завершён. Изменение стратегии не потребовалось, ss-zapret2 перезапущен."
    elif [ "$search_status" -eq 0 ]; then
        error "Поиск завершён, но автоматически применить стратегию не удалось."
    else
        error "blockcheck2.sh завершился с ошибкой: $search_status"
    fi
    pause
}
