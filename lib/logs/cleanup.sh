#!/usr/bin/env bash

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

