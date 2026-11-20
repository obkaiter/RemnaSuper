#!/usr/bin/env bash

show_relay_installation_menu() {
    clear
    show_brand "Установка HAProxy"
    menu_item 1 "Установить HAProxy"
    menu_item 2 "Запустить HAProxy"
    menu_danger_item 3 "Остановить HAProxy"
    menu_item 4 "Перезапустить HAProxy"
    menu_danger_item 5 "Удалить HAProxy и сборщик"
    menu_back_item
}

show_relay_maintenance_menu() {
    clear
    show_brand "Обслуживание HAProxy"
    menu_item 1 "Состояние HAProxy"
    menu_item 2 "Просмотреть конфигурацию HAProxy"
    menu_item 3 "Просмотреть логи HAProxy"
    menu_item 4 "Проверить Stats Socket"
    menu_item 5 "Просмотр статистики"
    menu_item 6 "Управление подключениями"
    menu_item 7 "Создать резервную копию SQLite"
    menu_item 8 "Выгрузить статистику за месяц в CSV"
    menu_back_item
}

show_relay_traffic_menu() {
    clear
    show_brand "Просмотр статистики"
    menu_item 1 "Общая статистика за сегодня"
    menu_item 2 "Статистика за вчера"
    menu_item 3 "Статистика за выбранный месяц"
    menu_item 4 "Статистика по дням за месяц"
    menu_item 5 "Общая статистика за весь период"
    menu_item 6 "Статистика конкретного Backend"
    menu_item 7 "Список обнаруженных Backend"
    menu_item 8 "Последние измерения"
    menu_item 9 "Состояние сборщика"
    menu_back_item
}

show_relay_backend_menu() {
    local name

    clear
    show_brand "Выберите Backend"
    for name in "$@"; do
        menu_item "backend:$name" "$name"
    done
    menu_back_item
}

relay_read_month() {
    local output_variable="$1" input

    printf 'Укажите месяц в формате ГГГГ-ММ (Enter без ввода — назад): '
    IFS= read -r input && [[ -n "$input" ]] || return 1
    if [[ ! "$input" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ || "$input" == 0000-* ]]; then
        error "Месяц должен быть в формате ГГГГ-ММ."
        pause
        return 1
    fi
    printf -v "$output_variable" '%s' "$input"
}

relay_page() {
    if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then
        LESS='' LESSSECURE=1 less -SFX
    else
        cat
    fi
}

show_relay_traffic_report() {
    header "Статистика HAProxy"
    relay_traffic_command "$@" | relay_page
    pause
}

select_relay_backend_report() {
    local backend_list choice
    local -a backend_names

    backend_list="$(relay_traffic_command backends --names)" || { pause; return; }
    if [[ -z "$backend_list" ]]; then
        info "Сборщик ещё не обнаружил ни одного Backend."
        pause
        return
    fi
    mapfile -t backend_names <<< "$backend_list"
    select_menu choice '' show_relay_backend_menu "${backend_names[@]}" || return
    if [[ "$choice" != 0 ]]; then
        show_relay_traffic_report backend -- "${choice#backend:}"
    fi
}

relay_traffic_menu() {
    local choice month

    while true; do
        select_menu choice 1 show_relay_traffic_menu || return
        case "$choice" in
            1) show_relay_traffic_report today ;;
            2) show_relay_traffic_report yesterday ;;
            3) if relay_read_month month; then show_relay_traffic_report month "$month"; fi ;;
            4) if relay_read_month month; then show_relay_traffic_report daily "$month"; fi ;;
            5) show_relay_traffic_report total ;;
            6) select_relay_backend_report ;;
            7) show_relay_traffic_report backends ;;
            8) show_relay_traffic_report recent ;;
            9) show_relay_traffic_report status ;;
            0) return ;;
        esac
    done
}

show_relay_uninstall_menu() {
    clear
    show_brand "Удалить HAProxy и сборщик"
    menu_item 1 "Удалить с сохранением истории"
    menu_danger_item 2 "Удалить вместе с историей и резервными копиями"
    menu_back_item
}

relay_uninstall_menu() {
    local choice

    select_menu choice 0 show_relay_uninstall_menu || return
    case "$choice" in
        1) run_action "Удаление HAProxy с сохранением истории" \
            "Пакет HAProxy будет удалён через apt-get. Все маршруты станут недоступны через HAProxy, текущие соединения оборвутся. Сборщик будет остановлен и удалён, его настройки, SQLite, логи и резервные копии останутся в $RELAY_DIR. Из haproxy.cfg будут убраны только директивы, добавленные сборщиком." \
            remove_relay_haproxy history ;;
        2) run_action "Полное удаление HAProxy и статистики" \
            "Пакет HAProxy будет удалён через apt-get. Все маршруты станут недоступны через HAProxy, текущие соединения оборвутся. Сборщик будет остановлен и удалён. Весь $RELAY_DIR, включая SQLite, историю, настройки, логи, выгрузки и резервные копии, будет удалён безвозвратно. Из haproxy.cfg будут убраны только директивы, добавленные сборщиком." \
            remove_relay_haproxy full ;;
        0) return ;;
    esac
    pause
}

relay_view_haproxy_config() {
    local status

    check_command nano || { pause; return 1; }
    if [[ ! -f "$RELAY_HAPROXY_CONFIG" || ! -r "$RELAY_HAPROXY_CONFIG" ]]; then
        error "Не удалось прочитать конфигурацию HAProxy: $RELAY_HAPROXY_CONFIG."
        pause
        return 1
    fi
    nano --view -- "$RELAY_HAPROXY_CONFIG"
    status=$?
    pause
    return "$status"
}

relay_installation_menu() {
    local choice

    while true; do
        select_menu choice 1 show_relay_installation_menu || return
        case "$choice" in
            1)
                run_action "Установить HAProxy и сборщик" \
                    "При необходимости apt-get скачает и установит HAProxy, Python 3, tzdata и less. Если haproxy.cfg отсутствует, apt-get восстановит штатный файл из пакета HAProxy. Если файлов сборщика нет, скрипт загрузит их из репозитория RemnaSuper. При изменении haproxy.cfg будет создана резервная копия. Скрипт настроит локальный Unix-сокет, предложит option contstats, перечитает HAProxy через reload и включит HAProxy и $RELAY_SERVICE в автозапуск." \
                    install_relay_haproxy
                pause
                ;;
            2) run_action "Запуск HAProxy" "HAProxy запустится и займёт порты, указанные в его конфигурации." relay_haproxy_service start; pause ;;
            3) run_action "Остановка HAProxy" "Текущие соединения прервутся. Релей будет недоступен до следующего запуска HAProxy." relay_haproxy_service stop; pause ;;
            4) run_action "Перезапуск HAProxy" "HAProxy проверит конфигурацию и перезапустится. Текущие соединения прервутся, счётчики HAProxy сбросятся." relay_haproxy_service restart; pause ;;
            5) relay_uninstall_menu ;;
            0) return ;;
        esac
    done
}

relay_maintenance_menu() {
    local choice month

    while true; do
        select_menu choice 1 show_relay_maintenance_menu || return
        case "$choice" in
            1) systemctl --no-pager status haproxy; pause ;;
            2) relay_view_haproxy_config ;;
            3) journalctl -u haproxy.service -n 200 --no-pager | relay_page; pause ;;
            4) relay_traffic_command probe; pause ;;
            5) relay_traffic_menu ;;
            6) relay_connections_menu ;;
            7) run_action "Резервная копия SQLite" "Снимок базы будет сохранён в $RELAY_DIR/backups." relay_traffic_command backup; pause ;;
            8)
                if relay_read_month month; then
                    run_action "Выгрузка статистики" "CSV за $month будет сохранён в $RELAY_DIR/exports." relay_traffic_command export --month "$month"
                    pause
                fi
                ;;
            0) return ;;
        esac
    done
}
