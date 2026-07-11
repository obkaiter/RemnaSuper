#!/usr/bin/env bash

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
            1) run_geofiles_action "Установка Loyalsoldier-geofiles" \
                "Будут скачаны geosite.dat и geoip.dat проекта Loyalsoldier, подключены к RemnaNode и добавлены в автоматическое еженедельное обновление." \
                install_loyalsoldier_geofiles ;;
            2) run_geofiles_action "Установка xray-routing geofiles" \
                "Будут скачаны geosite.dat и geoip.dat проекта xray-routing, подключены к RemnaNode и добавлены в автоматическое еженедельное обновление." \
                install_xray_routing_geofiles ;;
            3) run_geofiles_action "Установка всех geofiles" \
                "Будут установлены наборы Loyalsoldier и xray-routing, подключены к RemnaNode и добавлены в автоматическое еженедельное обновление." \
                install_all_geofiles ;;
            4) run_geofiles_action "Удаление Loyalsoldier-geofiles" \
                "Файлы Loyalsoldier будут удалены, их volumes исключены из docker-compose.yml, а задание автоматического обновления будет удалено." \
                uninstall_loyalsoldier_geofiles ;;
            5) run_geofiles_action "Удаление xray-routing geofiles" \
                "Файлы xray-routing будут удалены, их volumes исключены из docker-compose.yml, а задание автоматического обновления будет удалено." \
                uninstall_xray_routing_geofiles ;;
            6) run_geofiles_action "Удаление всех geofiles" \
                "Все установленные наборы geofiles, их volumes и задания автоматического обновления будут удалены." \
                uninstall_all_geofiles ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

