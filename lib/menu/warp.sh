#!/usr/bin/env bash

show_warp_menu() {
    clear
    show_brand "Управление warp"

    menu_section "WARP Native"
    menu_item 1 "Установить warp"
    menu_item 2 "Управление warp"
    menu_danger_item 3 "Удалить warp"

    menu_section "Навигация"
    menu_back_item
}

show_warp_management_menu() {
    clear
    show_brand "Управление warp"

    menu_section "Состояние"
    menu_item 1 "Показать состояние"
    menu_item 2 "Сведения о WireGuard-интерфейсе"

    menu_section "Интерфейс"
    menu_item 3 "Запустить warp"
    menu_item 4 "Остановить warp"
    menu_item 5 "Перезапустить warp"
    menu_item 6 "Включить автозапуск"
    menu_item 7 "Отключить автозапуск"

    menu_section "Навигация"
    menu_back_item
}

warp_management_menu() {
    local choice

    while true; do
        select_menu choice 1 show_warp_management_menu || return
        case $choice in
            1) show_warp_status ;;
            2) show_warp_interface_info ;;
            3) run_action "Запуск warp" \
                "Будет запущен systemd-интерфейс $WARP_NATIVE_SERVICE. Если интерфейс не настроен или служба kill-switch недоступна, запуск завершится ошибкой." \
                warp_service_action start "Интерфейс warp запущен." ;;
            4) run_action "Остановка warp" \
                "Интерфейс $WARP_NATIVE_SERVICE будет остановлен. Текущие соединения через WARP прервутся. Если включён kill-switch, трафик с меткой 51888 будет блокироваться, пока не пойдёт через интерфейс $WARP_NATIVE_INTERFACE." \
                warp_service_action stop "Интерфейс warp остановлен." ;;
            5) run_action "Перезапуск warp" \
                "Интерфейс $WARP_NATIVE_SERVICE будет перезапущен, текущие соединения через WARP прервутся. Если включён kill-switch, трафик с меткой 51888 будет блокироваться до восстановления интерфейса." \
                warp_service_action restart "Интерфейс warp перезапущен." ;;
            6) run_action "Включение автозапуска warp" \
                "Служба $WARP_NATIVE_SERVICE будет добавлена в автозапуск systemd. Интерфейс запущен не будет." \
                warp_service_action enable "Автозапуск wg-quick@warp включён." ;;
            7) run_action "Отключение автозапуска warp" \
                "Служба $WARP_NATIVE_SERVICE будет удалена из автозапуска systemd. Уже запущенный интерфейс продолжит работать." \
                warp_service_action disable "Автозапуск wg-quick@warp отключён." ;;
            0) return ;;
        esac
    done
}

warp_menu() {
    local choice

    while true; do
        select_menu choice 1 show_warp_menu || return
        case $choice in
            1) run_action "Установка warp" \
                "Будет загружен актуальный install.sh из distillium/warp-native, проверен и запущен с правами root. Скрипт установит WireGuard и nftables, временно заменит /etc/resolv.conf на DNS 1.1.1.1 и 8.8.8.8, сохранив прежнее содержимое в /etc/resolv.conf.backup (существующий файл будет перезаписан), затем восстановит DNS. Он создаст или перезапишет /etc/wireguard/warp.conf, файлы в /opt/warp-native и /usr/local/bin/warp и /usr/local/bin/wgcf, добавит cron-задачу watchdog и systemd-настройки kill-switch, включит и запустит интерфейс $WARP_NATIVE_INTERFACE. Трафик Xray с меткой 51888 будет блокироваться, если не проходит через $WARP_NATIVE_INTERFACE." \
                install_warp_native ;;
            2) warp_management_menu ;;
            3) run_action "Удаление warp" \
                "Будет загружен актуальный uninstall.sh из distillium/warp-native, проверен и запущен с правами root. Скрипт остановит и отключит $WARP_NATIVE_SERVICE, удалит /opt/warp-native, /usr/local/bin/warp, /usr/local/bin/wgcf, /etc/wireguard/warp.conf, файлы legacy-аккаунта wgcf в домашнем каталоге root, watchdog, cron-задачу, systemd-настройки и таблицу nftables warp_native. Пакеты WireGuard будут удалены только если не обнаружены другие конфигурации или интерфейсы WireGuard. Работающий через WARP трафик прервётся." \
                uninstall_warp_native ;;
            0) return ;;
        esac
    done
}
