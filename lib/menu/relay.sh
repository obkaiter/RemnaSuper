#!/usr/bin/env bash

show_relay_menu() {
    clear
    show_brand "Настройка релея"
    menu_item 1 "Установка / обслуживание HAProxy"
    menu_item 2 "Просмотр статистики"
    menu_back_item
}

show_relay_connections_menu() {
    local route domain

    clear
    show_brand "Управление подключениями HAProxy"
    menu_section "Настроенные подключения"
    if (( $# == 0 )); then
        menu_rows+=("    Подключений пока нет")
    fi
    for route in "$@"; do
        domain="${route#* }"
        if [[ "$route" == 'site '* ]]; then
            menu_item "$domain" "$domain → сайт-заглушка nginx"
        else
            menu_item "$domain" "$domain → $domain:443"
        fi
    done
    menu_item 1 "Добавить подключение"
    menu_danger_item 2 "Удалить подключение"
    menu_back_item
}

show_relay_delete_menu() {
    local route domain

    clear
    show_brand "Удалить подключение HAProxy"
    for route in "$@"; do
        domain="${route#* }"
        if [[ "$route" == 'site '* ]]; then
            menu_item "$domain" "$domain — сайт-заглушка nginx"
        else
            menu_item "$domain" "$domain"
        fi
    done
    menu_back_item
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
    local choice domain route
    local -a connections=()

    while true; do
        read_relay_connections connections || { pause; return; }
        select_menu choice 1 show_relay_connections_menu "${connections[@]}" || return
        case "$choice" in
            1)
                read_relay_domain domain "Введите SNI выходной ноды" || continue
                run_action "Добавить подключение HAProxy" \
                    "SNI $domain будет направлен на $domain:443. DNS домена должен указывать на выходную ноду. Скрипт проверит конфигурацию, сохранит резервную копию и перечитает конфигурацию HAProxy через reload." \
                    change_relay_connection add "$domain"
                pause
                ;;
            2)
                if (( ${#connections[@]} == 0 )); then
                    warn "Нет подключений для удаления."
                    pause
                    continue
                fi
                select_menu domain 0 show_relay_delete_menu "${connections[@]}" || continue
                [[ "$domain" != 0 ]] || continue
                run_action "Удалить подключение HAProxy" \
                    "Маршрут SNI $domain будет удалён из конфигурации HAProxy. Скрипт проверит конфигурацию, сохранит резервную копию и перечитает конфигурацию через reload." \
                    change_relay_connection remove "$domain"
                pause
                ;;
            0) return ;;
            *)
                info "SNI: $choice"
                for route in "${connections[@]}"; do
                    case "$route" in
                        "site $choice") info "Назначение: nginx ($RELAY_SITE_SOCKET)" ;;
                        "node $choice") info "Назначение: $choice:443" ;;
                    esac
                done
                pause
                ;;
        esac
    done
}

relay_menu() {
    local choice

    while true; do
        select_menu choice 1 show_relay_menu || return
        case "$choice" in
            1) relay_maintenance_menu ;;
            2) relay_traffic_menu ;;
            0) return ;;
        esac
    done
}
