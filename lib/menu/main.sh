#!/usr/bin/env bash

show_menu() {
    clear
    show_brand "Главное меню"

    menu_section "Настройка"
    menu_item 1 "Первоначальная настройка"
    menu_item 14 "Настройка релея"

    menu_section "Управление"
    menu_item 2 "Управление Psiphon"
    menu_item 3 "Управление Tor"
    menu_item 4 "Управление warp"
    menu_item 5 "Управление ss-zapret2"
    menu_item 6 "Перезапустить ноду"

    menu_section "Диагностика"
    menu_item 7 "Запустить Davoyan/ipregion"
    menu_item 8 "Запустить IP Check Place"
    menu_item 9 "Запустить bench.sh (проверка скорости канала)"
    menu_item 10 "Проверить доступность сервисов"
    menu_item 11 "Просмотр xlogs"
    menu_item 12 "Просмотр логов Xray"
    menu_item 13 "iperf3 до российских серверов"

    menu_section "Навигация"
    menu_danger_item 0 "Выход"
}

main_menu() {
    local choice

    while true; do
        select_menu choice 1 show_menu || return
        case $choice in
            1) initial_setup_menu ;;
            14) relay_menu ;;
            2) psiphon_menu ;;
            3) tor_menu ;;
            4) warp_menu ;;
            5) zapret_menu ;;
            6) run_action "Перезапуск ноды" \
                "Docker Compose перезапустит сервисы RemnaNode. Текущие подключения могут прерваться на 5-10 секунд." \
                restart_node ;;
            7) run_action "Запуск Davoyan/ipregion" \
                "Будет скачан и запущен скрипт ipregion из репозитория Davoyan/ipregion." \
                run_ipregion ;;
            8) run_action "Запуск IP Check Place" \
                "Будет скачан и запущен диагностический скрипт IP Check Place на английском языке." \
                run_ip_check_place ;;
            9) run_action "Запуск bench.sh (проверка скорости канала)" \
                "Будет скачан и запущен скрипт bench.sh для проверки скорости канала." \
                run_bench ;;
            10) run_action "Проверка доступности сервисов" \
                "При необходимости apt-get обновит индекс и установит системный Python, пакет venv для его версии, CA-сертификаты и недостающие утилиты. Эти пакеты останутся на сервере. Будет скачан DPI Detector из репозитория Runnin4ik/dpi-detector, зависимости Python будут установлены во временное окружение. Скрипт запустится от root и выполнит выбранные сетевые проверки по внешним адресам. После выхода временные файлы будут удалены." \
                run_dpi_detector ;;
            11) run_action "Просмотр xlogs" \
                "Будет выполнена команда docker exec remnanode xlogs. Для выхода нажмите Ctrl+C." \
                view_xlogs ;;
            12) run_action "Просмотр логов Xray" \
                "Будет выполнена команда tail -f /var/log/remnanode/access.log. Для выхода нажмите Ctrl+C." \
                view_xray_logs ;;
            13) run_action "iperf3 до российских серверов" \
                "RemnaSuper скачает speedtest.sh из itdoginfo/russian-iperf3-servers во временный файл, проверит SHA-256 и запустит скрипт от root. Замер создаст исходящий TCP-трафик к публичным серверам на портах 5201–5209 и отправит ICMP-запросы. Нагрузка может замедлить VPN и расходовать платный трафик." \
                run_iperf3_ru ;;
            0) run_action "Выход" \
                "Работа RemnaSuper будет завершена." \
                exit_menu ;;
        esac
    done
}
