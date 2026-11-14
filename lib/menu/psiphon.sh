#!/usr/bin/env bash

show_psiphon_menu() {
    clear
    show_brand "Управление Psiphon — подключение №$PSIPHON_INSTANCE"

    menu_section "Управление"
    menu_item 1 "Установить или переустановить это подключение"
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
    menu_item 12 "Выбрать другое подключение"
    menu_item 13 "Добавить подключение"

    menu_section "Навигация"
    menu_back_item
}

show_psiphon_connections() {
    local instance
    local PSIPHON_INSTANCE PSIPHON_DIR PSIPHON_ENV_FILE PSIPHON_CLI
    local PSIPHON_SERVICE PSIPHON_OUTBOUND_TAG PSIPHON_OUTBOUND_FILE

    clear
    show_brand "Выбор подключения Psiphon"

    menu_section "Найденные подключения"
    for instance in "$@"; do
        set_psiphon_instance "$instance" || continue
        if [ -x "$PSIPHON_CLI" ] && systemctl is-active --quiet "$PSIPHON_SERVICE"; then
            menu_item "$instance" "№$instance — запущено ($PSIPHON_SERVICE)"
        elif [ -x "$PSIPHON_CLI" ]; then
            menu_item "$instance" "№$instance — установлено, не запущено ($PSIPHON_SERVICE)"
        else
            menu_item "$instance" "№$instance — неполная установка"
        fi
    done
    menu_back_item
}

select_psiphon_connection() {
    local -a instances
    local choice

    mapfile -t instances < <(list_psiphon_instances)
    if (( ${#instances[@]} == 0 )); then
        clear
        show_brand "Выбор подключения Psiphon"
        warn "Установленные подключения Psiphon не найдены."
        pause
        return
    fi

    select_menu choice "$PSIPHON_INSTANCE" show_psiphon_connections "${instances[@]}" || return
    [[ "$choice" != 0 ]] || return 0
    if ! psiphon_instance_exists "$choice"; then
        error "Подключение с номером '$choice' не найдено."
        pause
        return 1
    fi
    set_psiphon_instance "$choice" || return
    success "Выбрано подключение Psiphon №$PSIPHON_INSTANCE."
    sleep 1
}

add_psiphon_connection() {
    local saved_instance="$PSIPHON_INSTANCE"
    local suggested_instance
    local instance

    suggested_instance="$(next_psiphon_instance)" || {
        error "Достигнут предел в 99 подключений Psiphon."
        pause
        return
    }
    printf "Номер нового подключения [${suggested_instance}]: "
    read -r instance
    instance="${instance:-$suggested_instance}"

    if ! [[ "$instance" =~ ^([1-9]|[1-9][0-9])$ ]]; then
        error "Номер подключения должен быть от 1 до 99."
        pause
        return
    fi
    if psiphon_instance_exists "$instance"; then
        error "Подключение №$instance уже существует. Выберите его для управления или укажите другой номер."
        pause
        return
    fi

    set_psiphon_instance "$instance" || { pause; return; }
    run_action "Добавление подключения Psiphon №$instance" \
        "Будет загружен и запущен актуальный установщик Chara-Freedom/vps-psiphon с параметрами --instance $instance --no-http. Он создаст отдельные контейнер, systemd-сервис, watchdog, настройки и SOCKS5-порт, затем сохранит отдельный Xray outbound с тегом $PSIPHON_OUTBOUND_TAG. HTTP-прокси публиковаться не будет. Для использования подключения добавьте выведенный outbound в конфигурацию Xray и настройте маршрутизацию." \
        install_psiphon

    if ! psiphon_instance_exists "$instance"; then
        set_psiphon_instance "$saved_instance"
    fi
}

psiphon_menu() {
    local choice

    while true; do
        select_menu choice 1 show_psiphon_menu || return
        case $choice in
            1) run_action "Установка Psiphon" \
                "Будет скачан и запущен актуальный установщик из репозитория Chara-Freedom/vps-psiphon для подключения №$PSIPHON_INSTANCE. Он установит или обновит его Docker-контейнер, systemd-сервис, watchdog, SOCKS5 и Xray outbound для TCP-трафика. HTTP-прокси публиковаться не будет." \
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
                "JSON-outbound с тегом $PSIPHON_OUTBOUND_TAG будет обновлён из SOCKS5-настроек подключения №$PSIPHON_INSTANCE и показан для добавления в массив outbounds конфигурации Xray. Работа сервисов и сетевые настройки изменены не будут." \
                show_psiphon_outbound ;;
            11) run_action "Удаление Psiphon" \
                "Штатная команда $PSIPHON_CLI uninstall остановит и удалит сервисы, watchdog, контейнер, конфигурацию, состояние, логи и Xray outbound только подключения №$PSIPHON_INSTANCE." \
                uninstall_psiphon ;;
            12) select_psiphon_connection ;;
            13) add_psiphon_connection ;;
            0) return ;;
        esac
    done
}
