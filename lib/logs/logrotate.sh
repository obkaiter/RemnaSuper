#!/usr/bin/env bash

show_logrotate_menu() {
    header "Настройка ротации логов"
    if [ -f "$ROTATE_CONF" ]; then
        printf "${CYAN}Текущий конфиг:${NC}\n\n"
        cat "$ROTATE_CONF"
        printf "\n"
    fi

    menu_section "Профиль"
    menu_item 1 "Малая нода (<100): ежедневно, хранить 7 дней"
    menu_item 2 "Средняя нода (100-500): ежедневно, хранить 3 дня"
    menu_item 3 "Высокая нагрузка (>500): ротация по размеру 100МБ"
    menu_item 4 "Кастомный конфиг в nano"
    info "Стандартные профили после ротации перезапускают работающий контейнер remnanode, чтобы Xray открыл новые файлы. Подключения могут кратковременно прерваться."
    menu_back_item
}

write_logrotate_profile() {
    local rotation_policy="$1"
    local retention="$2"
    local dateext="$3"
    local tmp_file

    tmp_file="$(mktemp "$(dirname "$ROTATE_CONF")/.remnanode.XXXXXX")" || {
        error "Не удалось создать временный файл конфигурации logrotate."
        return 1
    }
    if ! {
        printf '%s %s {\n' "$LOG_DIR/access.log" "$LOG_DIR/error.log"
        printf '    %s\n' "$rotation_policy"
        printf '    rotate %s\n' "$retention"
        printf '%s\n' \
            '    missingok' \
            '    notifempty' \
            '    compress' \
            '    delaycompress' \
            '    create 644 root root' \
            '    sharedscripts'
        if [ "$dateext" = true ]; then
            printf '%s\n' '    dateext'
        fi
        cat <<EOF
    postrotate
        if [ -f "$NODE_DIR/docker-compose.yml" ] &&
            docker compose -f "$NODE_DIR/docker-compose.yml" ps -q remnanode 2>/dev/null | grep -q .; then
            docker compose -f "$NODE_DIR/docker-compose.yml" restart remnanode
        fi
    endscript
}
EOF
    } > "$tmp_file"; then
        rm -f -- "$tmp_file"
        error "Не удалось сформировать конфигурацию logrotate."
        return 1
    fi

    if ! chmod 644 "$tmp_file" || ! mv -f -- "$tmp_file" "$ROTATE_CONF"; then
        rm -f -- "$tmp_file"
        error "Не удалось сохранить конфигурацию logrotate."
        return 1
    fi
}

setup_logrotate() {
    local profile

    select_menu profile 0 show_logrotate_menu || return
    [[ "$profile" != 0 ]] || return 0
    if ! mkdir -p "$(dirname "$ROTATE_CONF")"; then
        error "Не удалось создать каталог для конфигурации logrotate."
        pause
        return 1
    fi
    case $profile in
        1)
            write_logrotate_profile daily 7 true || { pause; return 1; }
            success "Профиль 'Малая нода' применен."
            ;;
        2)
            write_logrotate_profile daily 3 true || { pause; return 1; }
            success "Профиль 'Средняя нода' применен."
            ;;
        3)
            write_logrotate_profile 'size 100M' 5 false || { pause; return 1; }
            success "Профиль 'Высокая нагрузка' применен."
            ;;
        4)
            check_command nano || { pause; return; }
            info "Редактирование: $ROTATE_CONF"
            nano "$ROTATE_CONF"
            success "Сохранено."
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

