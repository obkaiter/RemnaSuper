#!/usr/bin/env bash

follow_until_interrupt() {
    local interrupted=0
    local command_status

    trap 'interrupted=1' INT
    "$@"
    command_status=$?
    trap - INT

    if [ "$interrupted" -eq 1 ] || [ "$command_status" -gt 128 ]; then
        printf "\n"
        info "Просмотр остановлен."
    fi
    pause
}

view_errors() {
    header "Просмотр ошибок"
    check_docker || { pause; return; }

    follow_until_interrupt docker exec -it remnanode tail -n +1 -f /var/log/supervisor/xray.out.log
}

view_xray_logs() {
    header "Просмотр логов Xray"
    follow_until_interrupt tail -f /var/log/remnanode/access.log
}

