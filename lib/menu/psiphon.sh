#!/usr/bin/env bash

show_psiphon_menu() {
    clear
    show_brand "Управление Psiphon"

    section "Управление"
    menu_item 1 "Установить Psiphon"
    menu_item 2 "Показать состояние"
    menu_item 3 "Сменить выходной IP"
    menu_item 4 "Выбрать регион выхода"
    menu_item 5 "Настроить пул регионов"
    menu_item 6 "Настроить допустимые регионы"
    menu_item 7 "Проверить скорость"
    menu_item 8 "Показать логи клиента"
    menu_item 9 "Показать логи watchdog"
    menu_item 10 "Показать Xray outbound"
    menu_danger_item 11 "Удалить Psiphon"

    section "Навигация"
    menu_back_item
    prompt_choice "0-11"
}

psiphon_menu() {
    local choice

    while true; do
        show_psiphon_menu
        read -r choice
        case $choice in
            1) run_action "Установка Psiphon" \
                "Будет скачан и запущен актуальный установщик из репозитория Chara-Freedom/vps-psiphon. Он установит Docker-контейнер Psiphon, systemd-сервис и watchdog, опубликует SOCKS5 только на приватном адресе хоста и создаст Xray outbound для TCP-трафика. HTTP-прокси публиковаться не будет." \
                install_psiphon ;;
            2) run_action "Состояние Psiphon" \
                "Будут показаны состояния контейнера, сервиса и watchdog, SOCKS5-адрес, регион, выходной IP, оценка страны Google, наличие captcha и объём трафика. Для проверки выполняются сетевые запросы через туннель." \
                show_psiphon_status ;;
            3) run_action "Ротация Psiphon" \
                "Туннель Psiphon будет перезапущен для выбора нового выхода; при настроенном пуле будет выбран следующий регион. Текущие соединения через этот outbound прервутся примерно на 45 секунд." \
                rotate_psiphon ;;
            4) run_action "Регион выхода Psiphon" \
                "После ввода кода страны или auto будет очищена кешированная конфигурация Psiphon и перезапущен туннель. Текущие соединения через этот outbound прервутся примерно на 45 секунд." \
                set_psiphon_region ;;
            5) run_action "Пул регионов Psiphon" \
                "Будет изменён список стран, по которому Psiphon переходит при последующих ротациях. Пустой список отключит пул. Текущий туннель сразу не перезапускается." \
                set_psiphon_region_pool ;;
            6) run_action "Допустимые регионы Psiphon" \
                "Будет изменён список стран, которые watchdog допускает по оценке Google. Значение any разрешит любую страну, а пустая строка восстановит вычисляемый список по умолчанию. Запрещённые регионы из конфигурации по-прежнему имеют приоритет." \
                set_psiphon_accept_regions ;;
            7) run_action "Проверка скорости Psiphon" \
                "Через туннель Psiphon будут скачаны тестовые данные Cloudflare: один поток 50 МБ и четыре параллельных потока по 50 МБ. Проверка может занять до нескольких минут и израсходует около 250 МБ трафика." \
                test_psiphon_speed ;;
            8) run_action "Логи клиента Psiphon" \
                "Будет запрошено количество строк и показан конец журнала Docker-контейнера Psiphon. Системные настройки изменены не будут." \
                show_psiphon_client_logs ;;
            9) run_action "Логи watchdog Psiphon" \
                "Будет запрошено количество строк и показан конец журнала проверок и ротаций watchdog. Системные настройки изменены не будут." \
                show_psiphon_watchdog_logs ;;
            10) run_action "Xray outbound для Psiphon" \
                "JSON-outbound с тегом psiphon-out будет обновлён из текущих SOCKS5-настроек Psiphon и показан для добавления в массив outbounds конфигурации Xray. Работа сервисов и сетевые настройки изменены не будут." \
                show_psiphon_outbound ;;
            11) run_action "Удаление Psiphon" \
                "Штатная команда vps-psiphon uninstall остановит и удалит сервисы, watchdog, контейнер, Docker-образ, конфигурацию, состояние, логи и Xray outbound Psiphon." \
                uninstall_psiphon ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
