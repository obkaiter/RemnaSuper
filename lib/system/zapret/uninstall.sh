#!/usr/bin/env bash

_uninstall_ss_zapret() {
    if [[ "$ZAPRET_DIR" != /opt/ss-zapret2 || -L "$ZAPRET_DIR" ]]; then
        error "Небезопасный путь удаления: $ZAPRET_DIR"
        return 1
    fi

    if [ ! -e "$ZAPRET_DIR" ]; then
        info "ss-zapret2 уже удалён."
        return 0
    fi
    check_command realpath && check_command findmnt &&
        validate_remnasuper_directory "$ZAPRET_DIR" || return 1

    if [ -f "$ZAPRET_DIR/docker-compose.yml" ]; then
        check_docker || return 1
        step "Остановка контейнера и удаление образа ss-zapret2..."
        if ! (cd "$ZAPRET_DIR" && docker compose down --rmi all --remove-orphans); then
            error "Не удалось полностью остановить ss-zapret2. Файлы не удалены."
            return 1
        fi
    fi

    step "Удаление $ZAPRET_DIR..."
    if rm -rf --one-file-system -- "$ZAPRET_DIR"; then
        success "ss-zapret2, его конфигурация и Xray outbound удалены."
    else
        error "Не удалось удалить $ZAPRET_DIR."
        return 1
    fi
}

uninstall_ss_zapret() {
    local result=0

    header "Удаление ss-zapret2"
    _uninstall_ss_zapret || result=$?
    pause
    return "$result"
}
