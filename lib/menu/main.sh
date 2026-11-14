#!/usr/bin/env bash

show_menu() {
    clear
    show_brand "Главное меню"

    section "Настройка"
    menu_item 1 "Первоначальная настройка"

    section "Управление"
    menu_item 2 "Управление Psiphon"
    menu_item 3 "Управление Tor"
    menu_item 4 "Управление ss-zapret2"
    menu_item 5 "Перезапустить ноду"

    section "Диагностика"
    menu_item 6 "Запустить Davoyan/ipregion"
    menu_item 7 "Запустить IP Check Place"
    menu_item 8 "Запустить bench.sh (проверка скорости канала)"
    menu_item 9 "Проверить доступность сервисов"
    menu_item 10 "Просмотр ошибок Xray"
    menu_item 11 "Просмотр логов Xray"
    menu_item 12 "Комплексная диагностика соединения между двумя VPS"

    section "Навигация"
    menu_exit_item
    prompt_choice "0-12"
}

main_menu() {
    local choice

    while true; do
        show_menu
        read -r choice
        case $choice in
            1) initial_setup_menu ;;
            2) psiphon_menu ;;
            3) tor_menu ;;
            4) zapret_menu ;;
            5) run_action "Перезапуск ноды" \
                "Docker Compose перезапустит сервисы RemnaNode. Текущие подключения могут прерваться на 5-10 секунд." \
                restart_node ;;
            6) run_action "Запуск Davoyan/ipregion" \
                "Будет скачан и запущен скрипт ipregion из репозитория Davoyan/ipregion." \
                run_ipregion ;;
            7) run_action "Запуск IP Check Place" \
                "Будет скачан и запущен диагностический скрипт IP Check Place на английском языке." \
                run_ip_check_place ;;
            8) run_action "Запуск bench.sh (проверка скорости канала)" \
                "Будет скачан и запущен скрипт bench.sh для проверки скорости канала." \
                run_bench ;;
            9) run_action "Проверка доступности сервисов" \
                "Встроенная диагностика проверит Discord, YouTube, Telegram и Instagram: DNS-адреса, ICMP-пинг, HTTP-статус, конечный IP и задержки DNS/TCP/TLS/TTFB. Внешние скрипты и пакеты не скачиваются и не устанавливаются." \
                run_connectivity_check ;;
            10) run_action "Просмотр ошибок Xray" \
                "Будет открыт непрерывный вывод /var/log/supervisor/xray.out.log из контейнера remnanode. Для выхода нажмите Ctrl+C." \
                view_errors ;;
            11) run_action "Просмотр логов Xray" \
                "Будет выполнена команда tail -f /var/log/remnanode/access.log. Для выхода нажмите Ctrl+C." \
                view_xray_logs ;;
            12) run_action "Парная диагностика двух VPS" \
                "Недостающие пакеты Python 3, iperf3, UFW и сетевых утилит будут предложены для отдельной постоянной установки через apt-get. UFW должен быть активен с входящей политикой deny: автоматически он не включается. Временно откроются адресные TCP/UDP-порты только для второй VPS; агент закроет собственные правила и слушатели, удалит тестовые файлы и сообщит, если очистка не удалась. Выбор готового профиля даёт ориентир 5, 15 или 30 минут без общего ограничения времени; средний и полный передают по 1 GiB файлами в каждую сторону, плюс TCP/UDP-трафик. Нагрузка может замедлить VPN и расходовать платный трафик. Отчёты сохраняются." \
                run_network_diagnostics ;;
            0) run_action "Выход" \
                "Работа RemnaSuper будет завершена." \
                exit_menu ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
