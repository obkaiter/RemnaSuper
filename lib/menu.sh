#!/usr/bin/env bash

run_and_pause() {
    "$@"
    pause
}

show_geofiles_menu() {
    clear
    show_brand "Geofiles"

    section "Установка"
    menu_item 1 "Установить Loyalsoldier-geofiles"
    menu_item 2 "Установить xray-routing geofiles"
    menu_item 3 "Установить все geofiles"

    section "Удаление"
    menu_danger_item 4 "Удалить Loyalsoldier-geofiles"
    menu_danger_item 5 "Удалить xray-routing geofiles"
    menu_danger_item 6 "Удалить все geofiles"

    section "Навигация"
    menu_back_item
    prompt_choice "0-6"
}

geofiles_menu() {
    local choice

    while true; do
        show_geofiles_menu
        read -r choice
        case $choice in
            1) run_and_pause install_loyalsoldier_geofiles ;;
            2) run_and_pause install_xray_routing_geofiles ;;
            3) run_and_pause install_all_geofiles ;;
            4) run_and_pause uninstall_loyalsoldier_geofiles ;;
            5) run_and_pause uninstall_xray_routing_geofiles ;;
            6) run_and_pause uninstall_all_geofiles ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

show_menu() {
    clear
    show_brand "Главное меню"

    section "Логи"
    menu_item 1 "Исправить логи в RemnaNode"
    menu_item 2 "Информация о логах"
    menu_item 3 "Настроить logrotate"
    menu_item 4 "Собрать диагностику"
    menu_item 5 "Очистить старые логи"

    section "Управление"
    menu_item 6 "Перезапустить ноду"
    menu_item 7 "Перезапустить агента"
    menu_item 8 "Восстановить docker-compose.yml из бэкапа"
    menu_item 9 "Выполнить первоначальную настройку"
    menu_item 10 "Установить remnawave-reverse-proxy"
    menu_item 11 "Просмотр ошибок Xray"

    section "Прочее"
    menu_item 12 "Установка/удаление geofiles"
    menu_item 13 "Выполнить Node Accelerator"

    section "Навигация"
    menu_exit_item
    prompt_choice "0-13"
}

main_menu() {
    local choice

    while true; do
        show_menu
        read -r choice
        case $choice in
            1) fix_logs ;;
            2) check_status ;;
            3) setup_logrotate ;;
            4) collect_debug ;;
            5) cleanup_logs ;;
            6) restart_node ;;
            7) restart_agent ;;
            8) restore_backup ;;
            9) initial_setup ;;
            10) install_remnawave_reverse_proxy ;;
            11) view_errors ;;
            12) geofiles_menu ;;
            13) run_node_accelerator ;;
            0) exit_menu ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
