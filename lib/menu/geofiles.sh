#!/usr/bin/env bash

show_geofiles_menu() {
    clear
    show_brand "Geofiles"

    menu_section "Установка"
    menu_item 1 "Установить все geofiles"
    menu_item 2 "Установить Loyalsoldier-geofiles"
    menu_item 3 "Установить xray-routing geofiles"
    menu_item 7 "Установить Chocolate4U security geofiles"

    menu_section "Удаление"
    menu_danger_item 4 "Удалить все geofiles"
    menu_danger_item 5 "Удалить Loyalsoldier-geofiles"
    menu_danger_item 6 "Удалить xray-routing geofiles"
    menu_danger_item 8 "Удалить Chocolate4U security geofiles"

    menu_section "Навигация"
    menu_back_item
}

geofiles_menu() {
    local choice

    while true; do
        select_menu choice 1 show_geofiles_menu || return
        case $choice in
            1) run_geofiles_action "Установка всех geofiles" \
                "Будут скачаны наборы Loyalsoldier, xray-routing и Chocolate4U, добавлены их задания ежедневного обновления в cron и volumes для RemnaNode. Если найден docker-compose.yml, перед изменением будет создана резервная копия, а контейнеры будут перезапущены. Активные подключения могут прерваться." \
                install_all_geofiles ;;
            2) run_geofiles_action "Установка Loyalsoldier-geofiles" \
                "Будут скачаны geosite.dat и geoip.dat проекта Loyalsoldier, добавлены задания ежедневного обновления в cron и volumes для RemnaNode. Если найден docker-compose.yml, перед изменением будет создана резервная копия, а контейнеры будут перезапущены. Активные подключения могут прерваться." \
                install_loyalsoldier_geofiles ;;
            3) run_geofiles_action "Установка xray-routing geofiles" \
                "Будут скачаны geosite.dat и geoip.dat проекта xray-routing, добавлены задания ежедневного обновления в cron и volumes для RemnaNode. Если найден docker-compose.yml, перед изменением будет создана резервная копия, а контейнеры будут перезапущены. Активные подключения могут прерваться." \
                install_xray_routing_geofiles ;;
            4) run_geofiles_action "Удаление всех geofiles" \
                "Сначала уберите ссылки на эти файлы из профиля Xray. Затем будут удалены файлы всех наборов, их задания cron и volumes. Перед изменением docker-compose.yml будет создана резервная копия, после изменения контейнеры будут перезапущены. Активные подключения могут прерваться." \
                uninstall_all_geofiles ;;
            5) run_geofiles_action "Удаление Loyalsoldier-geofiles" \
                "Сначала уберите ссылки на файлы Loyalsoldier из профиля Xray. Будут удалены файлы, задания cron и volumes. Перед изменением docker-compose.yml будет создана резервная копия, после изменения контейнеры будут перезапущены. Активные подключения могут прерваться." \
                uninstall_loyalsoldier_geofiles ;;
            6) run_geofiles_action "Удаление xray-routing geofiles" \
                "Сначала уберите ссылки на файлы xray-routing из профиля Xray. Будут удалены файлы, задания cron и volumes. Перед изменением docker-compose.yml будет создана резервная копия, после изменения контейнеры будут перезапущены. Активные подключения могут прерваться." \
                uninstall_xray_routing_geofiles ;;
            7) run_geofiles_action "Установка Chocolate4U security geofiles" \
                "Будут скачаны security.dat и security-ip.dat проекта Chocolate4U/Iran-v2ray-rules, добавлены задания ежедневного обновления в cron и volumes для RemnaNode. Если найден docker-compose.yml, перед изменением будет создана резервная копия, а контейнеры будут перезапущены. Активные подключения могут прерваться. Правила Xray будут выведены для ручного добавления." \
                install_security_geofiles ;;
            8) run_geofiles_action "Удаление Chocolate4U security geofiles" \
                "Сначала уберите ссылки на security.dat и security-ip.dat из профиля Xray. Будут удалены оба файла, их задания cron и volumes. Перед изменением docker-compose.yml будет создана резервная копия, после изменения контейнеры будут перезапущены. Активные подключения могут прерваться." \
                uninstall_security_geofiles ;;
            0) return ;;
        esac
    done
}

