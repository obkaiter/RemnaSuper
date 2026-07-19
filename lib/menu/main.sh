#!/usr/bin/env bash

show_menu() {
    clear
    show_brand "Главное меню"

    section "Первоначальная настройка"
    menu_item 1 "apt update && apt upgrade"
    menu_item 2 "Установить remnawave-reverse-proxy"
    menu_item 3 "Установить сертификаты в RemnaNode"
    menu_item 4 "Управление Node Accelerator"
    menu_item 5 "Установить fail2ban"
    menu_item 6 "Исправить логи в RemnaNode"

    section "Управление"
    menu_item 7 "Управление ss-zapret2"
    menu_item 8 "Установить tspu checker"
    menu_item 9 "Установка/удаление geofiles"
    menu_item 10 "Перезапустить ноду"
    menu_item 11 "Перезапустить агента"

    section "Диагностика"
    menu_item 12 "Запустить ipregion"
    menu_item 13 "IP Check Place"
    menu_item 14 "Проверка скорости канала (bench.sh)"
    menu_item 15 "Просмотр ошибок Xray"
    menu_item 16 "Просмотр логов Xray"

    section "Навигация"
    menu_exit_item
    prompt_choice "0-16"
}

main_menu() {
    local choice

    while true; do
        show_menu
        read -r choice
        case $choice in
            1) run_action "apt update && apt upgrade" \
                "Будут обновлены пакеты системы (apt-get update и apt-get upgrade), затем установлены cron, mc и wget." \
                initial_setup ;;
            2) run_action "Установка remnawave-reverse-proxy" \
                "Будет скачан и запущен официальный install_remnawave.sh из репозитория eGamesAPI/remnawave-reverse-proxy." \
                install_remnawave_reverse_proxy ;;
            3) run_action "Установка сертификатов в RemnaNode" \
                "Домен сертификата будет найден в docker-compose.yml, файл будет сохранён в бэкап, сертификаты подключены к RemnaNode, после чего нода будет перезапущена." \
                install_remnanode_certificates ;;
            4) node_accelerator_menu ;;
            5) run_action "Установка fail2ban" \
                "Будет установлен fail2ban, включена защита SSH с четырьмя попытками входа за 10 минут и блокировкой на один час, после чего сервис будет добавлен в автозапуск и запущен." \
                install_fail2ban ;;
            6) run_action "Исправление логов RemnaNode" \
                "Будут созданы access.log и error.log, каталог логов подключён к RemnaNode в docker-compose.yml, нода и агент перезапущены, затем будет предложена настройка ротации логов." \
                fix_logs ;;
            7) zapret_menu ;;
            8) run_action "Установка tspu checker" \
                "Будут установлены hping3, nmap, netcat-openbsd, openssl, dnsutils и curl; репозиторий ku78/tspu-checker будет клонирован в /opt/tspu-checker, затем tspu_check.sh будет запущен." \
                install_tspu_checker ;;
            9) geofiles_menu ;;
            10) run_action "Перезапуск ноды" \
                "Docker Compose перезапустит сервисы RemnaNode. Текущие подключения могут прерваться на 5-10 секунд." \
                restart_node ;;
            11) run_action "Перезапуск агента" \
                "Docker Compose перезапустит сервисы агента в /opt/remnawave/node-agent." \
                restart_agent ;;
            12) run_action "Запуск ipregion" \
                "Будет скачан и запущен скрипт ipregion из репозитория Davoyan/ipregion." \
                run_ipregion ;;
            13) run_action "IP Check Place" \
                "Будет скачан и запущен диагностический скрипт IP Check Place на английском языке." \
                run_ip_check_place ;;
            14) run_action "Проверка скорости канала (bench.sh)" \
                "Будет скачан и запущен скрипт bench.sh для проверки скорости канала." \
                run_bench ;;
            15) run_action "Просмотр ошибок Xray" \
                "Будет открыт непрерывный вывод /var/log/supervisor/xray.out.log из контейнера remnanode. Для выхода нажмите Ctrl+C." \
                view_errors ;;
            16) run_action "Просмотр логов Xray" \
                "Будет выполнена команда tail -f /var/log/remnanode/access.log. Для выхода нажмите Ctrl+C." \
                view_xray_logs ;;
            0) run_action "Выход" \
                "Работа RemnaSuper будет завершена." \
                exit_menu ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
