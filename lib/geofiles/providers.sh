#!/usr/bin/env bash

install_loyalsoldier_geofiles() {
    install_geofile "loyalsoldier" \
        "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat" \
        "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
}

uninstall_loyalsoldier_geofiles() {
    uninstall_geofile "loyalsoldier" "true" "true"
}

install_xray_routing_geofiles() {
    install_geofile "xray-routing" \
        "https://raw.githubusercontent.com/Davoyan/xray-routing/main/release/geosite.dat" \
        "https://raw.githubusercontent.com/Davoyan/xray-routing/main/release/geoip.dat"
}

uninstall_xray_routing_geofiles() {
    uninstall_geofile "xray-routing" "true" "true"
}

install_all_geofiles() {
    header "Установка всех geofiles"
    install_loyalsoldier_geofiles
    divider
    install_xray_routing_geofiles
}

uninstall_all_geofiles() {
    header "Удаление всех geofiles"
    uninstall_loyalsoldier_geofiles
    divider
    uninstall_xray_routing_geofiles
}

