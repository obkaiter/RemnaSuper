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

