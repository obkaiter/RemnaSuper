#!/usr/bin/env bash

show_diagnostics_menu() {
    clear
    show_brand "Диагностика VPS, Remnanode"

    menu_item 1 "Запустить Node Precheck"
    menu_item 2 "Запустить Davoyan/ipregion"
    menu_item 3 "Запустить IP Check Place"
    menu_item 4 "Запустить bench.sh (проверка скорости канала)"
    menu_item 5 "Проверить доступность сервисов"
    menu_item 6 "iperf3 до российских серверов"
    menu_item 7 "Проверить CPU steal"

    menu_section "Логи"
    menu_item 8 "Просмотр xlogs"
    menu_item 9 "Просмотр логов Xray"

    menu_section "Навигация"
    menu_back_item
}

diagnostics_menu() {
    local choice

    while true; do
        select_menu choice 1 show_diagnostics_menu || return
        case $choice in
            1) run_action "Node Precheck" \
                "Скрипт будет загружен с vpn-hub.pro и выполнен через Bash с правами root. Он считывает сведения об ОС, процессоре, памяти, диске, сетевых интерфейсах, открытых портах и firewall; публичный IP отправляется внешним сервисам для геолокации и проверок. Globalping проверит этот IP по ICMP и TCP/22 из сетей РФ. Тест скорости может скачать до 100 МБ с Cloudflare и до 100 МБ с Selectel, а также отправить до 25 МБ на Cloudflare. Постоянные файлы и настройки не изменяются; тест записи на диск по умолчанию выключен." \
                run_node_precheck ;;
            2) run_action "Запуск Davoyan/ipregion" \
                "Будет скачан и запущен скрипт ipregion из репозитория Davoyan/ipregion." \
                run_ipregion ;;
            3) run_action "Запуск IP Check Place" \
                "Будет скачан и запущен диагностический скрипт IP Check Place на английском языке." \
                run_ip_check_place ;;
            4) run_action "Запуск bench.sh (проверка скорости канала)" \
                "Будет скачан и запущен скрипт bench.sh для проверки скорости канала." \
                run_bench ;;
            5) run_action "Проверка доступности сервисов" \
                "При необходимости apt-get обновит индекс и установит системный Python, пакет venv для его версии, CA-сертификаты и недостающие утилиты. Эти пакеты останутся на сервере. Будет скачан DPI Detector из репозитория Runnin4ik/dpi-detector, зависимости Python будут установлены во временное окружение. Скрипт запустится от root и выполнит выбранные сетевые проверки по внешним адресам. После выхода временные файлы будут удалены." \
                run_dpi_detector ;;
            6) run_action "iperf3 до российских серверов" \
                "RemnaSuper скачает speedtest.sh из itdoginfo/russian-iperf3-servers во временный файл, проверит SHA-256 и запустит скрипт от root. Замер создаст исходящий TCP-трафик к публичным серверам на портах 5201–5209 и отправит ICMP-запросы. Нагрузка может замедлить VPN и расходовать платный трафик." \
                run_iperf3_ru ;;
            7) run_action "Проверить CPU steal" \
                "RemnaSuper дважды прочитает статистику Linux из /proc/stat с интервалом 5 секунд и покажет долю времени, которую гипервизор отнял у виртуальных процессоров." \
                run_cpu_steal ;;
            8) run_action "Просмотр xlogs" \
                "Будет выполнена команда docker exec remnanode xlogs. Для выхода нажмите Ctrl+C." \
                view_xlogs ;;
            9) run_action "Просмотр логов Xray" \
                "Будет выполнена команда tail -f /var/log/remnanode/access.log. Для выхода нажмите Ctrl+C." \
                view_xray_logs ;;
            0) return ;;
        esac
    done
}
