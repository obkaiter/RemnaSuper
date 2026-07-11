#!/usr/bin/env bash

show_zapret_menu() {
    clear
    show_brand "Управление ss-zapret2"

    section "Управление"
    menu_item 1 "Установить ss-zapret2"
    menu_item 2 "Поиск стратегии"
    menu_item 3 "Показать текущую стратегию"
    menu_danger_item 4 "Удалить ss-zapret2"

    section "Навигация"
    menu_back_item
    prompt_choice "0-4"
}

zapret_menu() {
    local choice

    while true; do
        show_zapret_menu
        read -r choice
        case $choice in
            1) run_action "Установка ss-zapret2" \
                "Будет установлен Docker-контейнер vernette/ss-zapret2 с локальным SOCKS5, проверена его доступность и создан готовый outbound для Xray. При наличии прежнего ss-zapret он будет остановлен, его .env перенесён, а старые файлы сохранены." \
                install_zapret ;;
            2) run_action "Поиск стратегии ss-zapret2" \
                "Будут проверены компоненты blockcheck2, обработка zapret2 будет временно остановлена, затем запустится интерактивный поиск nfqws2. Первая рекомендованная стратегия для каждого протокола автоматически попадёт в NFQWS2_OPT, после чего контейнер будет перезапущен." \
                search_zapret_strategy ;;
            3) run_action "Текущая стратегия ss-zapret2" \
                "Будет прочитан параметр NFQWS2_OPT из /opt/ss-zapret2/config и показана текущая стратегия. Конфигурация и состояние контейнера изменены не будут." \
                show_current_zapret_strategy ;;
            4) run_action "Удаление ss-zapret2" \
                "Контейнер ss-zapret2 будет остановлен, Docker-образ и каталог /opt/ss-zapret2 со всеми настройками и Xray outbound будут удалены. Сохранённый каталог прежней версии /opt/ss-zapret затронут не будет." \
                uninstall_ss_zapret ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
