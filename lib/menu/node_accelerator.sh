#!/usr/bin/env bash

show_node_accelerator_menu() {
    clear
    show_brand "Управление Node Accelerator"

    section "Установка и запуск"
    menu_item 1 "Установить оптимизатор"
    menu_item 2 "Установить защиту"
    menu_item 3 "Запустить диагностику"
    menu_item 4 "Установить все модули"
    menu_item 5 "Установить/обновить CLI диагностики"

    section "Удаление"
    menu_danger_item 6 "Удалить оптимизатор"
    menu_danger_item 7 "Удалить защиту"
    menu_danger_item 8 "Удалить оптимизатор и защиту"

    section "Навигация"
    menu_back_item
    prompt_choice "0-8"
}

node_accelerator_menu() {
    local choice

    while true; do
        show_node_accelerator_menu
        read -r choice
        case $choice in
            1) run_action "Установка оптимизатора Node Accelerator" \
                "Будет запущен модуль optimize: XanMod с BBRv3, системный и сетевой тюнинг, RPS/RFS/XPS, лимиты, swap и настройка NIC. Для активации нового ядра после установки может потребоваться перезагрузка." \
                run_node_accelerator optimize ;;
            2) run_action "Установка защиты Node Accelerator" \
                "Будет запущен интерактивный модуль protect: nftables, защита от сканирования и флуда, CrowdSec и автоопределение порта node-agent. Внимательно проверьте разрешённые порты и whitelist, чтобы не потерять доступ к серверу." \
                run_node_accelerator protect ;;
            3) run_action "Диагностика Node Accelerator" \
                "Будет запущен read-only модуль diagnose. Он проверит ядро, BBR, sysctl, лимиты, conntrack, NIC, firewall, CrowdSec, порты и состояние RemnaNode без изменения настроек." \
                run_node_accelerator diagnose ;;
            4) run_action "Установка всех модулей Node Accelerator" \
                "Будут последовательно запущены optimize, protect и diagnose. Установка изменит параметры системы и firewall; после установки XanMod может потребоваться перезагрузка." \
                run_node_accelerator all ;;
            5) run_action "Установка CLI Node Accelerator" \
                "Будут установлены или обновлены постоянные read-only команды na-diagnose и na-report в /usr/local/sbin." \
                run_node_accelerator persist ;;
            6) run_action "Удаление оптимизатора Node Accelerator" \
                "Будет выполнен штатный rollback optimize: удалены настройки sysctl, лимиты и сервисы тюнинга. XanMod останется установленным; для его удаления upstream требует загрузиться со штатного ядра и использовать NA_REMOVE_XANMOD=1." \
                run_node_accelerator rollback optimize ;;
            7) run_action "Удаление защиты Node Accelerator" \
                "Будет выполнен штатный rollback protect: удалены правила na_filter/na_ctguard, а также связанные сервисы и таймеры. CrowdSec останется установленным и продолжит работать." \
                run_node_accelerator rollback protect ;;
            8) run_action "Удаление оптимизатора и защиты Node Accelerator" \
                "Будет выполнен штатный rollback all для защиты и оптимизатора. XanMod и CrowdSec по правилам upstream останутся установленными; CLI диагностики будет удалён, если активных модулей больше нет." \
                run_node_accelerator rollback all ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
