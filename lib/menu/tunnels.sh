#!/usr/bin/env bash

show_tunnels_menu() {
    clear
    show_brand "Управление туннелями"

    menu_item 1 "Управление Psiphon"
    menu_item 2 "Управление Tor"
    menu_item 3 "Управление warp"
    menu_item 4 "Управление ss-zapret2"

    menu_section "Навигация"
    menu_back_item
}

tunnels_menu() {
    local choice

    while true; do
        select_menu choice 1 show_tunnels_menu || return
        case $choice in
            1) psiphon_menu ;;
            2) tor_menu ;;
            3) warp_menu ;;
            4) zapret_menu ;;
            0) return ;;
        esac
    done
}
