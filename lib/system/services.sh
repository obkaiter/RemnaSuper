#!/usr/bin/env bash

restart_node() {
    header "Перезапуск ноды"
    check_docker || { pause; return; }

    warn "Подключения прервутся примерно на 5-10 секунд."
    restart_remnanode_compose
    pause
}

