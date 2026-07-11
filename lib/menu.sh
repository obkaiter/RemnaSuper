#!/usr/bin/env bash

confirm_action() {
    local title="$1"
    local description="$2"

    clear
    show_brand "$title"
    printf "%s\n" "$description"
    printf "\n${CYAN}Нажимте Enter чтобы продолжить${NC}"
    read -r
}

run_action() {
    local title="$1"
    local description="$2"
    local action="$3"

    confirm_action "$title" "$description"
    "$action"
}

show_menu() {
    clear
    show_brand "Главное меню"

    section "Первоначальная настройка"
    menu_item 1 "Выполнить первоначальную настройку"
    menu_item 2 "Установить remnawave-reverse-proxy"
    menu_item 4 "Установить сертификаты в RemnaNode"
    menu_item 5 "Выполнить Node Accelerator"
    menu_item 6 "Исправить логи в RemnaNode"
    menu_item 7 "Настроить ротацию логов"
    menu_item 8 "Установить zapret"
    menu_item 9 "Установить tspu checker"

    section "Управление"
    menu_item 10 "Перезапустить ноду"
    menu_item 11 "Перезапустить агента"
    menu_item 12 "Просмотр ошибок Xray"
    menu_item 13 "Просмотр логов Xray"

    section "Навигация"
    menu_exit_item
    prompt_choice "0-2, 4-13"
}

main_menu() {
    local choice

    while true; do
        show_menu
        read -r choice
        case $choice in
            1) run_action "Первоначальная настройка" \
                "Будут обновлены пакеты системы (apt-get update и apt-get upgrade), затем установлены cron, mc и wget." \
                initial_setup ;;
            2) run_action "Установка remnawave-reverse-proxy" \
                "Будет скачан и запущен официальный install_remnawave.sh из репозитория eGamesAPI/remnawave-reverse-proxy." \
                install_remnawave_reverse_proxy ;;
            4) run_action "Установка сертификатов в RemnaNode" \
                "Домен сертификата будет найден в docker-compose.yml, файл будет сохранён в бэкап, сертификаты подключены к RemnaNode, после чего нода будет перезапущена." \
                install_remnanode_certificates ;;
            5) run_action "Node Accelerator" \
                "Будет скачан скрипт Node Accelerator из репозитория jestivald/node-accelerator и запущен с параметром all." \
                run_node_accelerator ;;
            6) run_action "Исправление логов RemnaNode" \
                "Будут созданы access.log и error.log, каталог логов подключён к RemnaNode в docker-compose.yml, затем нода и агент будут перезапущены." \
                fix_logs ;;
            7) run_action "Настройка ротации логов" \
                "Будет предложен профиль logrotate. Выбранная конфигурация будет записана в /etc/logrotate.d/remnanode и проверена на ошибки." \
                setup_logrotate ;;
            8) run_action "Установка zapret" \
                "Будет скачан и запущен installer.sh из репозитория Snowy-Fluffy/zapret.installer." \
                install_zapret ;;
            9) run_action "Установка tspu checker" \
                "Будут установлены hping3, nmap, netcat-openbsd, openssl, dnsutils и curl; репозиторий ku78/tspu-checker будет клонирован в /opt/tspu-checker, затем tspu_check.sh будет запущен." \
                install_tspu_checker ;;
            10) run_action "Перезапуск ноды" \
                "Docker Compose перезапустит сервисы RemnaNode. Текущие подключения могут прерваться на 5-10 секунд." \
                restart_node ;;
            11) run_action "Перезапуск агента" \
                "Docker Compose перезапустит сервисы агента в /opt/remnawave/node-agent." \
                restart_agent ;;
            12) run_action "Просмотр ошибок Xray" \
                "Будет открыт непрерывный вывод /var/log/supervisor/xray.out.log из контейнера remnanode. Для выхода нажмите Ctrl+C." \
                view_errors ;;
            13) run_action "Просмотр логов Xray" \
                "Будет выполнена команда tail -f /var/log/remnanode/access.log. Для выхода нажмите Ctrl+C." \
                view_xray_logs ;;
            0) run_action "Выход" \
                "Работа RemnaSuper будет завершена." \
                exit_menu ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
