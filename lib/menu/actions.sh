#!/usr/bin/env bash

confirm_action() {
    local title="$1"
    local description="$2"
    local required_reply="${3:-}" reply read_status

    clear
    show_brand "$title"
    printf "%s\n" "$description" | LC_ALL=C.UTF-8 fold -s -w 220
    if [[ -n "$required_reply" ]]; then
        printf "\n${CYAN}Введите %s и нажмите Enter. Ctrl+C — отменить${NC}\n" "$required_reply"
    else
        printf "\n${CYAN}Enter — продолжить, Ctrl+C — отменить${NC}"
    fi

    trap 'trap - INT; printf "\n"; info "Действие отменено. Возврат в предыдущее меню."; return 130' INT
    IFS= read -r reply
    read_status=$?
    trap - INT

    if [[ "$read_status" -ne 0 || ( -n "$required_reply" && "$reply" != "$required_reply" ) ]]; then
        printf "\n"
        info "Действие отменено. Возврат в предыдущее меню."
        return 1
    fi
}

run_action() {
    local title="$1"
    local description="$2"
    local action="$3"
    local remnasuper_action_header_state=first
    shift 3

    confirm_action "$title" "$description" || return
    "$action" "$@"
}

run_geofiles_action() {
    local title="$1"
    local description="$2"
    local action="$3"
    local remnasuper_action_header_state=first
    local action_status=0

    confirm_action "$title" "$description" || return
    "$action" || action_status=$?
    pause
    return "$action_status"
}
