#!/usr/bin/env bash

confirm_action() {
    local title="$1"
    local description="$2"
    local read_status

    clear
    show_brand "$title"
    printf "%s\n" "$description"
    printf "\n${CYAN}Нажимте Enter чтобы продолжить${NC}"

    trap 'trap - INT; printf "\n"; info "Действие отменено. Возврат в предыдущее меню."; return 130' INT
    read -r
    read_status=$?
    trap - INT

    if [ "$read_status" -ne 0 ]; then
        printf "\n"
        info "Действие отменено. Возврат в предыдущее меню."
        return 1
    fi
}

run_action() {
    local title="$1"
    local description="$2"
    local action="$3"

    confirm_action "$title" "$description" || return
    "$action"
}

run_geofiles_action() {
    local title="$1"
    local description="$2"
    local action="$3"

    confirm_action "$title" "$description" || return
    "$action"
    pause
}

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

show_menu() {
    clear
    show_brand "Главное меню"

    section "Первоначальная настройка"
    menu_item 1 "Выполнить первоначальную настройку"
    menu_item 2 "Установить remnawave-reverse-proxy"
    menu_item 3 "Установить сертификаты в RemnaNode"
    menu_item 4 "Выполнить Node Accelerator"
    menu_item 5 "Исправить логи в RemnaNode"
    menu_item 6 "Настроить ротацию логов"
    menu_item 7 "Установить ss-zapret"
    menu_item 8 "Установить tspu checker"

    section "Управление"
    menu_item 9 "Перезапустить ноду"
    menu_item 10 "Перезапустить агента"
    menu_item 11 "Просмотр ошибок Xray"
    menu_item 12 "Просмотр логов Xray"

    section "Прочее"
    menu_item 13 "Установка/удаление geofiles"

    section "Навигация"
    menu_exit_item
    prompt_choice "0-13"
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
            3) run_action "Установка сертификатов в RemnaNode" \
                "Домен сертификата будет найден в docker-compose.yml, файл будет сохранён в бэкап, сертификаты подключены к RemnaNode, после чего нода будет перезапущена." \
                install_remnanode_certificates ;;
            4) run_action "Node Accelerator" \
                "Будет скачан скрипт Node Accelerator из репозитория jestivald/node-accelerator и запущен с параметром all." \
                run_node_accelerator ;;
            5) run_action "Исправление логов RemnaNode" \
                "Будут созданы access.log и error.log, каталог логов подключён к RemnaNode в docker-compose.yml, затем нода и агент будут перезапущены." \
                fix_logs ;;
            6) run_action "Настройка ротации логов" \
                "Будет предложен профиль logrotate. Выбранная конфигурация будет записана в /etc/logrotate.d/remnanode и проверена на ошибки." \
                setup_logrotate ;;
            7) run_action "Установка ss-zapret" \
                "Будет установлен Docker-контейнер vernette/ss-zapret с локальным SOCKS5 на 127.0.0.1:1080, проверена его доступность и создан готовый outbound для Xray." \
                install_zapret ;;
            8) run_action "Установка tspu checker" \
                "Будут установлены hping3, nmap, netcat-openbsd, openssl, dnsutils и curl; репозиторий ku78/tspu-checker будет клонирован в /opt/tspu-checker, затем tspu_check.sh будет запущен." \
                install_tspu_checker ;;
            9) run_action "Перезапуск ноды" \
                "Docker Compose перезапустит сервисы RemnaNode. Текущие подключения могут прерваться на 5-10 секунд." \
                restart_node ;;
            10) run_action "Перезапуск агента" \
                "Docker Compose перезапустит сервисы агента в /opt/remnawave/node-agent." \
                restart_agent ;;
            11) run_action "Просмотр ошибок Xray" \
                "Будет открыт непрерывный вывод /var/log/supervisor/xray.out.log из контейнера remnanode. Для выхода нажмите Ctrl+C." \
                view_errors ;;
            12) run_action "Просмотр логов Xray" \
                "Будет выполнена команда tail -f /var/log/remnanode/access.log. Для выхода нажмите Ctrl+C." \
                view_xray_logs ;;
            13) geofiles_menu ;;
            0) run_action "Выход" \
                "Работа RemnaSuper будет завершена." \
                exit_menu ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
