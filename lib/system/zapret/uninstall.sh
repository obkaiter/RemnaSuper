#!/usr/bin/env bash

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

