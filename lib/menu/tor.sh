#!/usr/bin/env bash

show_tor_menu() {
    clear
    show_brand "Управление Tor"

    section "Управление"
    menu_item 1 "Установить и настроить Tor"
    menu_item 2 "Быстро сменить выходной IP"
    menu_item 3 "Показать Xray outbound"
    menu_danger_item 4 "Удалить Tor"

    section "Навигация"
    menu_back_item
    prompt_choice "0-4"
}

tor_menu() {
    local choice

    while true; do
        show_tor_menu
        read -r choice
        case $choice in
            1) run_action "Установка Tor" \
                "Будут установлены пакеты Tor, добавлена локальная конфигурация SOCKS5 127.0.0.1:9050 и ControlPort 127.0.0.1:9051, включён и перезапущен сервис, проверен выход через сеть Tor и создан готовый Xray outbound для TCP-трафика. Порты доступны только на localhost; RemnaNode должен использовать network_mode: host." \
                install_tor ;;
            2) run_action "Быстрая смена IP Tor" \
                "Tor получит локальную команду SIGNAL NEWNYM. Текущие Tor-соединения не разрываются, а новые соединения получат новую цепочку; один и тот же выходной IP иногда может быть выбран повторно." \
                change_tor_ip ;;
            3) run_action "Xray outbound для Tor" \
                "Будет показан сохранённый JSON-outbound с тегом tor для добавления в массив outbounds конфигурации Xray. Системные настройки изменены не будут." \
                show_tor_outbound ;;
            4) run_action "Удаление Tor" \
                "Будут удалены конфигурация и Xray outbound, созданные RemnaSuper. Пакеты Tor будут удалены только если их установил RemnaSuper; существовавшая ранее сторонняя установка Tor будет сохранена и перезапущена без настроек RemnaSuper." \
                uninstall_tor ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
