#!/usr/bin/env bash

show_menu() {
    clear
    show_brand "Главное меню"

    menu_item 1 "Настройка VPS"
    menu_item 2 "Настройка Remnanode"
    menu_item 3 "Настройка релея"
    menu_item 4 "Управление туннелями"
    menu_item 5 "Диагностика VPS, Remnanode"

    menu_section "Управление RemnaSuper"
    menu_item 6 "Обновить скрипт"
    menu_danger_item 7 "Удалить скрипт"

    menu_section "Навигация"
    menu_danger_item 0 "Выход"
}

update_script() {
    local result=0

    check_for_updates manual || result=$?
    pause
    return "$result"
}

remove_script() {
    local result=0

    confirm_action "Окончательное подтверждение удаления" \
        "Команда rs, каталог /opt/RemnaSuper, резервные копии и история HAProxy будут удалены. Удаление может прервать трафик релея и туннелей, а также подключения при пересоздании контейнеров RemnaNode. Если нужны резервные копии, сохраните их перед продолжением." \
        "DELETE" || return
    if uninstall_remnasuper; then
        exit 0
    else
        result=$?
    fi
    pause
    return "$result"
}

main_menu() {
    local choice

    while true; do
        select_menu choice 1 show_menu || return
        case $choice in
            1) vps_setup_menu ;;
            2) node_setup_menu ;;
            3) relay_menu ;;
            4) tunnels_menu ;;
            5) diagnostics_menu ;;
            6) run_action "Обновить скрипт" \
                "RemnaSuper проверит версию на GitHub. Если есть обновление, приложение скачает и установит его, затем перезапустится. Активный сборщик HAProxy может быть перезапущен." \
                update_script ;;
            7) run_action "Удалить скрипт" \
                "RemnaSuper отключит и удалит свои службы, фильтр SMTP, конфигурации SSH, IPv6, fail2ban и ротации логов, geofiles и задания cron, настройки релея, сайт-заглушку и свои туннели. Для WARP с отметкой об установке будет скачан и запущен от root скрипт удаления distillium/warp-native, который может удалить пакеты WireGuard. Удаление политики SSH может снова разрешить вход по паролю. Уберите ссылки на удаляемые geofiles и туннели из профиля Xray. Потребуется второе подтверждение." \
                remove_script ;;
            0) run_action "Выход" \
                "Работа RemnaSuper будет завершена." \
                exit_menu ;;
        esac
    done
}
