#!/usr/bin/env bash

confirm_action() {
    local title="$1"
    local description="$2"
    local read_status

    clear
    show_brand "$title"
    printf "%s\n" "$description"
    printf "\n${CYAN}Нажимте Enter чтобы продолжить${NC}"

    trap 'trap - INT; printf "\n"; info "Действие отменено. Возврат в предыдущее меню."; return 130' INT
    read -r
    read_status=$?
    trap - INT

    if [ "$read_status" -ne 0 ]; then
        printf "\n"
        info "Действие отменено. Возврат в предыдущее меню."
        return 1
    fi
}

run_action() {
    local title="$1"
    local description="$2"
    local action="$3"
    shift 3

    confirm_action "$title" "$description" || return
    "$action" "$@"
}

run_geofiles_action() {
    local title="$1"
    local description="$2"
    local action="$3"

    confirm_action "$title" "$description" || return
    "$action"
    pause
}
