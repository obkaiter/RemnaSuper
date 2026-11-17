#!/usr/bin/env bash

lock_relay() {
    local lock_fd

    check_command flock || return 1
    if [[ "$INSTALL_DIR" != /opt/RemnaSuper || -L "$INSTALL_DIR" ]] ||
        ! mkdir -p -- "$INSTALL_DIR" || ! { exec {lock_fd}<"$INSTALL_DIR"; } || ! flock -n "$lock_fd"; then
        error "Не удалось заблокировать настройки релея. Проверьте каталог установки и другие сеансы RemnaSuper."
        return 1
    fi
}

prepare_relay_directories() {
    local directory

    if [[ "$RELAY_DIR" != /opt/RemnaSuper/haproxy || -L "$INSTALL_DIR" || -L "$RELAY_DIR" ]]; then
        error "Небезопасный каталог модуля HAProxy: $RELAY_DIR."
        return 1
    fi
    for directory in "$RELAY_DIR" "$RELAY_DIR/"{config,database,logs,run,systemd,backups,exports}; do
        if [[ -L "$directory" ]] || ! (umask 077; mkdir -p -- "$directory"); then
            error "Не удалось подготовить каталог $directory."
            return 1
        fi
    done
}

validate_relay_payload() {
    local source="$1" file

    for file in collector/{collector,database,haproxy_stats,reports}.py "systemd/$RELAY_SERVICE"; do
        if [[ ! -s "$source/$file" ]]; then
            error "В составе RemnaSuper отсутствует haproxy/$file."
            return 1
        fi
    done
}

relay_service_registered() {
    [[ -L "$RELAY_SERVICE_LINK" && "$(readlink -- "$RELAY_SERVICE_LINK")" == "$RELAY_DIR/systemd/$RELAY_SERVICE" ]]
}

cleanup_relay_deployment() {
    local reload_needed=0

    if (( ! deployed )); then
        if (( unit_changed )); then
            if [[ -n "$unit_backup" ]]; then
                if ! cp -p -- "$unit_backup" "$staging/unit" ||
                    ! mv -Tf -- "$staging/unit" "$RELAY_DIR/systemd/$RELAY_SERVICE"; then
                    error "Не удалось вернуть прежний unit сборщика."
                fi
            else
                rm -f -- "$RELAY_DIR/systemd/$RELAY_SERVICE"
            fi
            reload_needed=1
        fi
        if (( code_changed )); then
            if [[ -n "$old_code" ]]; then
                if ! ln -s -- "$old_code" "$staging/collector.restore" ||
                    ! mv -Tf -- "$staging/collector.restore" "$RELAY_DIR/collector"; then
                    error "Не удалось вернуть прежний код сборщика."
                fi
            else
                rm -f -- "$RELAY_DIR/collector"
            fi
        fi
        if relay_service_registered; then
            if (( reload_needed )); then
                systemctl daemon-reload || error "Не удалось перечитать прежний unit сборщика."
            fi
            if (( collector_was_active && (code_changed || unit_changed) )); then
                systemctl restart "$RELAY_SERVICE" || error "Не удалось запустить прежнюю версию сборщика."
            fi
        fi
    fi
    if [[ "$(readlink -- "$RELAY_DIR/collector")" != "${staging##*/}" ]]; then
        rm -rf -- "$staging"
    fi
}

deploy_relay_payload() (
    local source="$1" file staging old_code='' unit_backup=''
    local code_needed=0 unit_needed=0 code_changed=0 unit_changed=0 deployed=0 collector_was_active=0

    validate_relay_payload "$source" && prepare_relay_directories || return 1
    if [[ -L "$RELAY_DIR/collector" ]]; then
        old_code="$(readlink -- "$RELAY_DIR/collector")" || return 1
        if [[ ! "$old_code" =~ ^code\.[A-Za-z0-9]{8}$ ]]; then
            error "Неизвестная ссылка на код сборщика: $RELAY_DIR/collector."
            return 1
        fi
    elif [[ -e "$RELAY_DIR/collector" && ! "$source" -ef "$RELAY_DIR" ]]; then
        error "Не удалось обновить код: $RELAY_DIR/collector уже существует."
        return 1
    fi
    for file in collector/{collector,database,haproxy_stats,reports}.py; do
        cmp -s "$source/$file" "$RELAY_DIR/$file" || code_needed=1
    done
    if [[ -L "$RELAY_DIR/systemd/$RELAY_SERVICE" ]]; then
        error "Unit сборщика является символической ссылкой: $RELAY_DIR/systemd/$RELAY_SERVICE."
        return 1
    fi
    cmp -s "$source/systemd/$RELAY_SERVICE" "$RELAY_DIR/systemd/$RELAY_SERVICE" || unit_needed=1
    (( code_needed || unit_needed )) || return 0

    staging="$(mktemp -d "$RELAY_DIR/code.XXXXXXXX")" || return 1
    trap cleanup_relay_deployment EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if relay_service_registered && systemctl is-active --quiet "$RELAY_SERVICE"; then
        collector_was_active=1
    fi
    if (( code_needed )); then
        for file in collector/{collector,database,haproxy_stats,reports}.py; do
            install -m 600 -- "$source/$file" "$staging/${file##*/}" || return 1
        done
        ln -s -- "${staging##*/}" "$staging/collector.next" &&
            mv -Tf -- "$staging/collector.next" "$RELAY_DIR/collector" || return 1
        code_changed=1
    fi
    if (( unit_needed )); then
        if [[ -f "$RELAY_DIR/systemd/$RELAY_SERVICE" ]]; then
            backup_config_file "$RELAY_DIR/systemd/$RELAY_SERVICE" unit_backup "$RELAY_DIR/backups" || return 1
        fi
        install -m 644 -- "$source/systemd/$RELAY_SERVICE" "$staging/unit" &&
            mv -Tf -- "$staging/unit" "$RELAY_DIR/systemd/$RELAY_SERVICE" || return 1
        unit_changed=1
        if relay_service_registered; then
            systemctl daemon-reload || return 1
        fi
    fi
    if (( collector_was_active )); then
        systemctl restart "$RELAY_SERVICE" && systemctl is-active --quiet "$RELAY_SERVICE" || return 1
    fi
    deployed=1
    if [[ -n "$old_code" && "$old_code" != "$(readlink -- "$RELAY_DIR/collector")" ]]; then
        rm -rf -- "${RELAY_DIR:?}/${old_code:?}" || warn "Не удалось удалить предыдущую версию кода сборщика."
    fi
)

sync_relay_payload() (
    lock_relay && deploy_relay_payload "$1"
)
