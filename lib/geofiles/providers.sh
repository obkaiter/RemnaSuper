#!/usr/bin/env bash

LOYALSOLDIER_GEOFILES=(
    "loyalsoldier-geosite.dat" "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
    "loyalsoldier-geoip.dat" "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
)
XRAY_ROUTING_GEOFILES=(
    "xray-routing-geosite.dat" "https://raw.githubusercontent.com/Davoyan/xray-routing/main/release/geosite.dat"
    "xray-routing-geoip.dat" "https://raw.githubusercontent.com/Davoyan/xray-routing/main/release/geoip.dat"
)
SECURITY_GEOFILES=(
    "security.dat" "$SECURITY_GEOFILES_URL/security.dat"
    "security-ip.dat" "$SECURITY_GEOFILES_URL/security-ip.dat"
)

install_loyalsoldier_geofiles() {
    install_geofile "loyalsoldier" "${LOYALSOLDIER_GEOFILES[@]}"
}

uninstall_loyalsoldier_geofiles() {
    uninstall_geofile "loyalsoldier" "loyalsoldier-geosite.dat" "loyalsoldier-geoip.dat"
}

install_xray_routing_geofiles() {
    install_geofile "xray-routing" "${XRAY_ROUTING_GEOFILES[@]}"
}

uninstall_xray_routing_geofiles() {
    uninstall_geofile "xray-routing" "xray-routing-geosite.dat" "xray-routing-geoip.dat"
}

install_security_geofiles() {
    install_geofile "Chocolate4U/Iran-v2ray-rules" "${SECURITY_GEOFILES[@]}" &&
        show_security_geofile_routing
}

show_security_geofile_routing() {
    printf '\n'
    info "Добавьте оба правила в routing.rules профиля Xray ноды перед разрешающими правилами."
    info "Используйте тег существующего outbound с протоколом blackhole или добавьте его в outbounds."
    printf '\n'
    cat <<'EOF'
{
    "outbounds": [
        {"tag": "blackhole", "protocol": "blackhole", "settings": {}}
    ],
    "routing": {
        "rules": [
            {
                "type": "field",
                "domain": ["ext:security.dat:malware", "ext:security.dat:phishing"],
                "outboundTag": "blackhole"
            },
            {
                "type": "field",
                "ip": ["ext:security-ip.dat:malware", "ext:security-ip.dat:phishing"],
                "outboundTag": "blackhole"
            }
        ]
    }
}
EOF
}

uninstall_security_geofiles() {
    uninstall_geofile "Chocolate4U/Iran-v2ray-rules" "security.dat" "security-ip.dat"
}

install_all_geofiles() {
    install_geofile "все наборы" "${LOYALSOLDIER_GEOFILES[@]}" \
        "${XRAY_ROUTING_GEOFILES[@]}" "${SECURITY_GEOFILES[@]}" &&
        show_security_geofile_routing
}

uninstall_all_geofiles() {
    uninstall_geofile "все наборы" "loyalsoldier-geosite.dat" "loyalsoldier-geoip.dat" \
        "xray-routing-geosite.dat" "xray-routing-geoip.dat" "security.dat" "security-ip.dat"
}

