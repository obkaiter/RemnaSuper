#!/usr/bin/env bash

fix_logs() {
    header "Исправление логов RemnaNode"
    check_docker || { pause; return; }

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден."
        warn "Проверьте путь к ноде: $NODE_DIR"
        pause
        return
    fi

    info "Создание директории: $LOG_DIR"
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    touch "$LOG_DIR/access.log" "$LOG_DIR/error.log"
    chmod 644 "$LOG_DIR"/*.log
    success "Директория готова."

    backup_compose
    add_remnanode_volume "/var/log/remnanode:/var/log/remnanode:rw" || { pause; return; }

    info "Перезапуск сервисов..."
    restart_remnanode_compose
    if [ -d "$AGENT_DIR" ]; then
        (cd "$AGENT_DIR" && docker compose restart >/dev/null 2>&1)
    fi
    success "Сервисы перезапущены."

    info "Проверка логов, ожидание 8 секунд..."
    sleep 8
    if [ -s "$LOG_DIR/access.log" ]; then
        success "Лог-файл заполняется, агент собирает IP."
        printf "\n${GREEN}Последние 3 записи:${NC}\n"
        divider
        tail -n 3 "$LOG_DIR/access.log"
        divider
    else
        warn "Файл пока пуст."
        printf "   1. В панели не применен конфиг с loglevel: 'info'\n"
        printf "   2. Нет активных подключений\n"
    fi
    pause
}

check_status() {
    header "Информация о логах"

    section "Лог-файл"
    if [ -f "$LOG_DIR/access.log" ]; then
        local size lines
        size=$(du -h "$LOG_DIR/access.log" 2>/dev/null | cut -f1)
        lines=$(wc -l < "$LOG_DIR/access.log" 2>/dev/null)
        success "$LOG_DIR/access.log ($size, $lines строк)"
        printf "\n${CYAN}Последние 5 записей:${NC}\n"
        tail -n 5 "$LOG_DIR/access.log" 2>/dev/null || printf "(пусто)\n"
    else
        warn "Файл не найден."
    fi

    section "Занято места"
    if [ -d "$LOG_DIR" ]; then
        du -sh "$LOG_DIR" 2>/dev/null
        ls -lh "$LOG_DIR"/*.log* 2>/dev/null | awk '{print "  " $9 " -> " $5}'
    else
        warn "Директория логов не найдена."
    fi

    pause
}

setup_logrotate() {
    header "Настройка ротации логов"
    if [ -f "$ROTATE_CONF" ]; then
        printf "${CYAN}Текущий конфиг:${NC}\n\n"
        cat "$ROTATE_CONF"
        printf "\n"
    fi

    section "Профиль"
    menu_item 1 "Малая нода (<100): ежедневно, хранить 7 дней"
    menu_item 2 "Средняя нода (100-500): ежедневно, хранить 3 дня"
    menu_item 3 "Высокая нагрузка (>500): ротация по размеру 100МБ"
    menu_item 4 "Кастомный конфиг в nano"
    menu_back_item
    prompt_choice "0-4"
    read -r profile

    mkdir -p "$(dirname "$ROTATE_CONF")"
    case $profile in
        1)
            cat > "$ROTATE_CONF" << 'EOF'
/var/log/remnanode/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 644 root root
    dateext
}
EOF
            success "Профиль 'Малая нода' применен."
            ;;
        2)
            cat > "$ROTATE_CONF" << 'EOF'
/var/log/remnanode/*.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    create 644 root root
    dateext
}
EOF
            success "Профиль 'Средняя нода' применен."
            ;;
        3)
            cat > "$ROTATE_CONF" << 'EOF'
/var/log/remnanode/access.log {
    size 100M
    rotate 5
    missingok
    notifempty
    compress
    delaycompress
    create 644 root root
}
EOF
            success "Профиль 'Высокая нагрузка' применен."
            ;;
        4)
            check_command nano || { pause; return; }
            info "Редактирование: $ROTATE_CONF"
            nano "$ROTATE_CONF"
            success "Сохранено."
            ;;
        0)
            return
            ;;
        *)
            warn "Неверный выбор."
            sleep 1
            return
            ;;
    esac

    info "Проверка синтаксиса..."
    if logrotate -d "$ROTATE_CONF" >/dev/null 2>&1; then
        success "Конфиг валиден."
    else
        error "Ошибка в конфиге. Подробности:"
        logrotate -d "$ROTATE_CONF" 2>&1 | head -8
    fi
    pause
}

collect_debug() {
    header "Сбор диагностики"
    check_docker || { pause; return; }

    local debug_dir="/tmp/remnawave-debug-$(date +%F_%H%M%S)"
    local archive="${debug_dir}.tar.gz"

    mkdir -p "$debug_dir"
    info "Сбор в: $debug_dir"
    [ -f "$COMPOSE_FILE" ] && cp "$COMPOSE_FILE" "$debug_dir/"
    if [ -d "$NODE_DIR" ]; then
        (cd "$NODE_DIR" && docker compose logs --tail 100 > "$debug_dir/node.log" 2>&1)
    fi
    if [ -d "$AGENT_DIR" ]; then
        (cd "$AGENT_DIR" && docker compose logs --tail 100 > "$debug_dir/agent.log" 2>&1)
    fi
    if [ -d "$LOG_DIR" ]; then
        mkdir -p "$debug_dir/remnanode-logs"
        [ -f "$LOG_DIR/access.log" ] && cp "$LOG_DIR/access.log" "$debug_dir/remnanode-logs/"
        [ -f "$LOG_DIR/error.log" ] && cp "$LOG_DIR/error.log" "$debug_dir/remnanode-logs/"
    fi

    tar -czf "$archive" -C "$(dirname "$debug_dir")" "$(basename "$debug_dir")" 2>/dev/null
    success "Архив: $archive"
    ls -lh "$archive"
    pause
}

cleanup_logs() {
    header "Очистка логов"
    menu_item 1 "Удалить *.gz старше 7 дней"
    menu_item 2 "Удалить все архивы"
    menu_item 3 "Очистить текущий access.log"
    menu_back_item
    prompt_choice "0-3"
    read -r action

    case $action in
        1)
            find "$LOG_DIR" -name "*.gz" -mtime +7 -delete 2>/dev/null
            success "Очищено."
            ;;
        2)
            find "$LOG_DIR" -name "*.log.*" -delete 2>/dev/null
            success "Удалено."
            ;;
        3)
            : > "$LOG_DIR/access.log" 2>/dev/null
            success "Обнулено."
            ;;
        0)
            info "Отменено."
            ;;
        *)
            warn "Неверный выбор."
            ;;
    esac
    pause
}
