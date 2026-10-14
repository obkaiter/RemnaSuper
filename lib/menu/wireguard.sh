#!/usr/bin/env bash

show_wireguard_menu() {
    clear
    show_brand "Управление WireGuard"
    section "Сервер выхода"
    menu_item 1 "Установить WireGuard"
    menu_item 2 "Добавить вход"
    menu_item 3 "Просмотр текущих подключений"
    menu_item 4 "Перезапустить сервер WireGuard"
    menu_danger_item 5 "Удалить сервер WireGuard"
    section "Навигация"
    menu_back_item
    prompt_choice "0-5"
}

wg_menu_action() {
    local title="$1" description="$2" action="$3"
    shift 3
    run_action "$title" "$description" "$action" "$@"
    pause
}

wg_add_menu() {
    local name endpoint
    header "Добавить вход WireGuard"
    printf 'Имя подключения (латиницей): '
    read -r name
    wg_peer_name_valid "$name" || { error "Некорректное имя подключения."; pause; return; }
    printf 'Публичный IPv4 или DNS-адрес этого сервера: '
    read -r endpoint
    wg_endpoint_valid "$endpoint" || { error "Некорректный адрес сервера."; pause; return; }
    wg_menu_action "Добавление входа WireGuard $name" \
        "Если WireGuard ещё не настроен, будет создан серверный интерфейс $WG_IFACE ($WG_SUBNET.1/24, UDP $WG_PORT), включён IPv4 forwarding, настроены NAT и правила UFW с комментариями. Затем будут созданы ключи и конфиг peer $name и добавлен его доступ. Приватный ключ peer будет показан на экране; Xray outbound и команды маршрутизации предназначены для другой VPS." \
        wg_create_peer "$name" "$endpoint"
}

wg_list_menu() {
    local name choice
    while true; do
        header "Подключения WireGuard"
        if ! wg_server_ready; then
            warn "Сервер WireGuard ещё не настроен."
            pause
            return
        fi
        if ! systemctl is-active --quiet "wg-quick@$WG_IFACE"; then
            warn "Сервис wg-quick@$WG_IFACE не запущен; статистика может быть недоступна."
        fi
        printf '%-32s %-15s %s\n' 'Имя' 'Адрес' 'Состояние'
        while IFS= read -r name; do
            wg_peer_status "$name"
        done < <(wg_peer_names)
        printf '\nВведите имя подключения для управления или 0 для возврата: '
        read -r choice
        [ "$choice" = 0 ] && return
        wg_peer_name_valid "$choice" && [ -f "$WG_DIR/peers/$choice.conf" ] || {
            error "Подключение не найдено."
            pause
            continue
        }
        wg_manage_peer_menu "$choice"
    done
}

wg_manage_peer_menu() {
    local name="$1" choice endpoint
    while [ -f "$WG_DIR/peers/$name.conf" ]; do
        clear
        show_brand "WireGuard: $name"
        menu_item 1 "Показать конфиг peer и Xray outbound"
        menu_item 2 "Изменить публичный адрес сервера в конфиге peer"
        if [ -f "$WG_DIR/peers/$name.disabled" ]; then
            menu_item 3 "Включить подключение"
        else
            menu_item 3 "Отключить подключение"
        fi
        menu_danger_item 4 "Удалить подключение и отозвать ключ"
        menu_back_item
        prompt_choice "0-4"
        read -r choice
        case "$choice" in
            1) wg_menu_action "Конфиг WireGuard $name" \
                "Будут показаны приватный ключ и клиентский конфиг peer, а также Xray outbound. Системные настройки не изменятся." \
                wg_show_peer "$name" ;;
            2)
                printf 'Новый публичный IPv4 или DNS-адрес: '
                read -r endpoint
                if wg_endpoint_valid "$endpoint"; then
                    wg_menu_action "Смена endpoint $name" \
                        "Изменится только сохранённый клиентский конфиг peer. Его потребуется повторно передать на исходящую VPS; серверный туннель не перезапустится." \
                        wg_change_peer_endpoint "$name" "$endpoint"
                else
                    error "Некорректный адрес."
                    pause
                fi ;;
            3)
                if [ -f "$WG_DIR/peers/$name.disabled" ]; then
                    wg_menu_action "Включение $name" \
                        "Публичный ключ peer будет снова добавлен в серверный WireGuard без перезапуска остальных подключений." \
                        wg_set_peer_enabled "$name" 1
                else
                    wg_menu_action "Отключение $name" \
                        "Публичный ключ peer будет удалён из активного WireGuard; трафик этого peer прервётся. Конфиг и ключи сохранятся для повторного включения." \
                        wg_set_peer_enabled "$name" 0
                fi ;;
            4)
                wg_menu_action "Удаление $name" \
                    "Peer будет удалён из активного WireGuard, его сохранённый клиентский конфиг и ключи удалятся. Подключение на другой VPS перестанет работать." \
                    wg_delete_peer "$name"
                [ -f "$WG_DIR/peers/$name.conf" ] || return ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

wireguard_menu() {
    local choice
    while true; do
        show_wireguard_menu
        read -r choice
        case "$choice" in
            1) wg_menu_action "Установка WireGuard" \
                "Будет проверено наличие wg и wg-quick. Если их нет, apt-get обновит индекс пакетов и установит wireguard и wireguard-tools. Сетевые интерфейсы и UFW на этом шаге не меняются." \
                wg_install ;;
            2) wg_add_menu ;;
            3) wg_list_menu ;;
            4) wg_menu_action "Перезапуск WireGuard" \
                "Сервис wg-quick@$WG_IFACE будет перезапущен; все текущие туннели на несколько секунд прервутся. Также восстановится правило NAT интерфейса." \
                wg_restart_server ;;
            5) wg_menu_action "Удаление сервера WireGuard" \
                "Сервис $WG_IFACE будет остановлен и отключён, все его peer и приватные ключи удалены, правила UFW для UDP $WG_PORT и транзита удалены, собственный sysctl-файл и конфиг интерфейса удалены. Пакеты WireGuard останутся установленными. Все туннели к этому серверу перестанут работать." \
                wg_remove_server ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
