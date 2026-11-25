#!/usr/bin/env bash

fix_logs() {
    local compose_backup restore configured_hash

    header "Исправить логи (access.log, xray.out.log)"
    check_docker || { pause; return; }

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден."
        warn "Проверьте путь к ноде: $NODE_DIR"
        pause
        return
    fi

    if ! backup_compose compose_backup; then
        error "Не удалось создать резервную копию docker-compose.yml."
        pause
        return
    fi

    info "Создание директории: $LOG_DIR"
    if ! mkdir -p -- "$LOG_DIR" || ! chmod 755 -- "$LOG_DIR" ||
        ! touch -- "$LOG_DIR/access.log" "$LOG_DIR/error.log" ||
        ! chmod 644 -- "$LOG_DIR/access.log" "$LOG_DIR/error.log"; then
        error "Не удалось подготовить файлы логов."
        return 1
    fi
    success "Директория готова."

    add_remnanode_volume "$LOG_DIR:$LOG_DIR:rw" || { pause; return 1; }
    configured_hash="$(sha256sum -- "$COMPOSE_FILE")" || return 1

    info "Перезапуск сервисов..."
    if ! restart_remnanode_compose; then
        if [[ "$configured_hash" != "$(sha256sum -- "$COMPOSE_FILE")" ]]; then
            error "Compose-файл изменился во время перезапуска. Проверьте состояние ноды. Резервная копия: $compose_backup"
            return 76
        fi
        restore="$(mktemp "${COMPOSE_FILE}.restore.XXXXXXXX")" || return 1
        if ! cp -p -- "$compose_backup" "$restore" || ! mv -fT -- "$restore" "$COMPOSE_FILE"; then
            rm -f -- "$restore"
            error "Не удалось вернуть прежний Compose-файл. Резервная копия: $compose_backup"
            return 76
        fi
        if ! (cd -- "$NODE_DIR" && docker compose up -d >/dev/null 2>&1); then
            error "Compose-файл восстановлен. Повторный запуск контейнеров не удался."
            return 76
        fi
        warn "Прежний Compose-файл восстановлен."
        return 1
    fi
    if [ -d "$AGENT_DIR" ]; then
        if ! (cd -- "$AGENT_DIR" && docker compose restart >/dev/null 2>&1); then
            error "Нода перезапущена, перезапустить агент не удалось."
            return 75
        fi
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
    setup_logrotate
}
