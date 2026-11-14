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
    menu_back_item
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

