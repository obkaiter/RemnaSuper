#!/usr/bin/env bash

show_relay_menu() {
    clear
    show_brand "Настройка релея"
    menu_item 1 "Установка HAProxy"
    menu_item 2 "Обслуживание HAProxy"
    menu_item 3 "Просмотр статистики"
    menu_back_item
}

show_relay_connections_menu() {
    local mode="$1" route kind domain frontend backend
    shift

    clear
    show_brand "Управление подключениями HAProxy"
    if [[ "$mode" == external ]]; then
        menu_section "Правила SNI из ручной конфигурации"
    else
        menu_section "Настроенные подключения"
    fi
    if (( $# == 0 )); then
        menu_rows+=("    Прямых правил SNI не найдено")
    fi
    for route in "$@"; do
        read -r kind domain frontend backend <<< "$route"
        case "$kind" in
            external) menu_item "route:$route" "$domain → $backend ($frontend)" ;;
            site) menu_item "$domain" "$domain → сайт-заглушка nginx" ;;
            node) menu_item "$domain" "$domain → $domain:443" ;;
        esac
    done
    menu_rows+=("")
    menu_item 1 "Добавить подключение"
    menu_back_item
}

show_relay_connection_menu() {
    clear
    show_brand "$1 → $2"
    menu_danger_item 1 "Удалить подключение"
    menu_back_item
}

relay_connection_menu() {
    local domain="$1" target="$2" frontend="${3:-}" backend="${4:-}" choice description

    select_menu choice 0 show_relay_connection_menu "$domain" "$target" || return
    [[ "$choice" == 1 ]] || return 0

    description="Маршрут SNI $domain будет удалён из конфигурации HAProxy. Скрипт сохранит резервную копию, проверит конфигурацию и применит её через reload или запустит остановленную службу."
    if [[ -n "$frontend" ]]; then
        description="Маршрут SNI $domain к $backend будет удалён из секции $frontend. Остальные условия и секции сохранятся. Скрипт сохранит резервную копию, проверит конфигурацию и применит её через reload или запустит остановленную службу."
    fi
    run_action "Удалить подключение HAProxy" "$description" \
        change_relay_connection remove "$domain" "$frontend" "$backend"
    pause
}

read_relay_domain() {
    local output_variable="$1" prompt="$2" input
    local LC_ALL=C

    printf '%s (Enter без ввода — назад): ' "$prompt"
    IFS= read -r input && [[ -n "$input" ]] || return 1
    input="${input,,}"
    if ! valid_relay_domain "$input"; then
        error "Введите полное доменное имя, например node.example.org."
        pause
        return 1
    fi
    printf -v "$output_variable" '%s' "$input"
}

relay_connections_menu() {
    local choice domain route mode frontend backend description default_choice
    local -a connections=()

    while true; do
        read_relay_connections connections mode || { pause; return; }
        default_choice=1
        [[ "$mode" != external ]] || default_choice=''
        select_menu choice "$default_choice" show_relay_connections_menu "$mode" "${connections[@]}" || return
        case "$choice" in
            1)
                read_relay_domain domain "Введите SNI выходной ноды" || continue
                if [[ "$mode" == external ]]; then
                    description="SNI $domain будет направлен на $domain:443 через существующий frontend bitwire_entry. DNS домена должен указывать на выходную ноду. Если используется стандартный список разрешённых SNI, домен будет добавлен и в него."
                else
                    description="SNI $domain будет направлен на $domain:443. DNS домена должен указывать на выходную ноду. При создании первого маршрута в штатном конфиге HAProxy будет добавлен IPv4-слушатель TCP/443."
                fi
                description+=" Скрипт сохранит резервную копию, проверит конфигурацию и применит её через reload или запустит остановленную службу."
                run_action "Добавить подключение HAProxy" "$description" \
                    change_relay_connection add "$domain"
                pause
                ;;
            0) return ;;
            'route:external '*)
                read -r domain frontend backend <<< "${choice#route:external }"
                relay_connection_menu "$domain" "$backend ($frontend)" "$frontend" "$backend"
                ;;
            *)
                for route in "${connections[@]}"; do
                    case "$route" in
                        "site $choice") relay_connection_menu "$choice" "nginx ($RELAY_SITE_SOCKET)"; break ;;
                        "node $choice") relay_connection_menu "$choice" "$choice:443"; break ;;
                    esac
                done
                ;;
        esac
    done
}

relay_menu() {
    local choice

    while true; do
        select_menu choice 1 show_relay_menu || return
        case "$choice" in
            1) relay_installation_menu ;;
            2) relay_maintenance_menu ;;
            3) relay_traffic_menu ;;
            0) return ;;
        esac
    done
}
