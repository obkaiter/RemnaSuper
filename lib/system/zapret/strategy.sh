#!/usr/bin/env bash

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

