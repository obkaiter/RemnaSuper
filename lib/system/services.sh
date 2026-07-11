#!/usr/bin/env bash

restart_node() {
    header "Перезапуск ноды"
    check_docker || { pause; return; }

    warn "Подключения прервутся примерно на 5-10 секунд."
    restart_remnanode_compose
    pause
}

restart_agent() {
    header "Перезапуск агента"
    check_docker || { pause; return; }

    if [ -d "$AGENT_DIR" ]; then
        if (cd "$AGENT_DIR" && docker compose restart >/dev/null 2>&1); then
            success "Агент перезапущен."
        else
            error "Ошибка при перезапуске агента."
        fi
    else
        error "Папка агента не найдена: $AGENT_DIR"
    fi
    pause
}

