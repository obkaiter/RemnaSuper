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
