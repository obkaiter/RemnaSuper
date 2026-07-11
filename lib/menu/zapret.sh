#!/usr/bin/env bash

show_zapret_menu() {
    clear
    show_brand "zapret"

    section "Управление"
    menu_item 1 "Установить ss-zapret"
    menu_item 2 "Поиск стратегии"
    menu_danger_item 3 "Удалить ss-zapret"

    section "Навигация"
    menu_back_item
    prompt_choice "0-3"
}

zapret_menu() {
    local choice

    while true; do
        show_zapret_menu
        read -r choice
        case $choice in
            1) run_action "Установка ss-zapret" \
                "Будет установлен Docker-контейнер vernette/ss-zapret с локальным SOCKS5, проверена его доступность и создан готовый outbound для Xray." \
                install_zapret ;;
            2) run_action "Поиск стратегии ss-zapret" \
                "Будут проверены компоненты blockcheck, обработка zapret будет временно остановлена, затем запустится интерактивный поиск nfqws без TPWS. Первая рекомендованная стратегия для каждого протокола автоматически попадёт в NFQWS_OPT, после чего контейнер будет перезапущен." \
                search_zapret_strategy ;;
            3) run_action "Удаление ss-zapret" \
                "Контейнер ss-zapret будет остановлен, Docker-образ и каталог /opt/ss-zapret со всеми настройками и Xray outbound будут удалены." \
                uninstall_ss_zapret ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

