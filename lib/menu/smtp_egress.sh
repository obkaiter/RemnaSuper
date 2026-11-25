#!/usr/bin/env bash

show_smtp_egress_menu() {
    local rules_state unit_file_state rules_status startup_status

    clear
    show_brand "Ограничить исходящий SMTP"

    rules_state="$(smtp_egress_rules_state 2>/dev/null)" || rules_state=unknown
    case "$rules_state" in
        current) rules_status="Ограничение включено" ;;
        absent) rules_status="Ограничение выключено" ;;
        outdated) rules_status="Действуют старые или неполные правила SMTP" ;;
        *) rules_status="Состояние правил неизвестно" ;;
    esac
    unit_file_state="$(systemctl show --property=UnitFileState --value "$SMTP_EGRESS_SERVICE" 2>/dev/null)" ||
        unit_file_state=unknown
    case "$unit_file_state" in
        enabled) startup_status="Автозапуск включён" ;;
        enabled-runtime) startup_status="Автозапуск включён временно" ;;
        ''|disabled) startup_status="Автозапуск выключен" ;;
        *) startup_status="Состояние автозапуска неизвестно" ;;
    esac
    menu_section "$rules_status. $startup_status."
    menu_item 1 "Включить ограничение"
    menu_danger_item 2 "Выключить ограничение"
    menu_item 3 "Показать правило Xray"
    menu_section "Навигация"
    menu_back_item
}

show_smtp_egress_xray_rule() {
    section "Правило Xray для TCP/25"
    info "Добавьте правило в routing.rules перед разрешающими правилами."
    info "Если в профиле есть старое правило, блокирующее TCP/25, 465 и 587, замените его этим."
    info "Укажите тег существующего outbound с протоколом blackhole, если он отличается."
    printf '\n'
    cat <<'EOF'
{
    "type": "field",
    "network": "tcp",
    "port": "25",
    "outboundTag": "blackhole"
}
EOF
}

apply_smtp_egress_action() {
    local action="$1"

    if ! configure_smtp_egress "$action"; then
        error "Не удалось применить настройку исходящего SMTP."
        pause
        return 1
    fi
    if [[ "$action" == enable ]]; then
        success "TCP/25 заблокирован. Для TCP/465 и 587 действует общий лимит в 5 попыток в час с запасом до 5 попыток подряд."
        show_smtp_egress_xray_rule
    else
        success "Правила RemnaSuper для исходящего SMTP сняты, автозапуск отключён."
    fi
    pause
}

smtp_egress_menu() {
    local choice

    while true; do
        select_menu choice 0 show_smtp_egress_menu || return
        case "$choice" in
            1) run_action "Включить ограничение исходящего SMTP" \
                "При отсутствии nftables APT обновит списки пакетов и установит его. Служба systemd remnasuper-smtp-egress будет включена в автозапуск. Её таблица nftables заблокирует TCP/25 и ограничит TCP/465 и 587 пятью попытками в час с запасом до пяти попыток подряд. Правила охватывают IPv4 и IPv6 на хосте и мостах Docker." \
                apply_smtp_egress_action enable ;;
            2) run_action "Выключить ограничение исходящего SMTP" \
                "Служба remnasuper-smtp-egress будет остановлена и исключена из автозапуска. Её таблица nftables будет удалена, включая блокировку TCP/25 и лимит для TCP/465 и 587. Правила Xray управляются в профиле ноды." \
                apply_smtp_egress_action disable ;;
            3) show_smtp_egress_xray_rule; pause ;;
            0) return ;;
        esac
    done
}
