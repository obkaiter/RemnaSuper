#!/usr/bin/env bash

enable_smtp_egress_service() (
    local unit_source="$REMNASUPER_APP_DIR/lib/system/$SMTP_EGRESS_SERVICE"
    local staged_unit='' created_unit=false

    check_command systemctl || return 1
    if [[ ! -f "$unit_source" || ! -f "$SMTP_EGRESS_RULES" ]]; then
        error "Файлы службы SMTP не найдены в установленной копии RemnaSuper."
        return 1
    fi
    if [[ -e "$SMTP_EGRESS_UNIT" || -L "$SMTP_EGRESS_UNIT" ]]; then
        if [[ -L "$SMTP_EGRESS_UNIT" || ! -f "$SMTP_EGRESS_UNIT" ]] ||
            ! cmp -s -- "$unit_source" "$SMTP_EGRESS_UNIT"; then
            error "Файл $SMTP_EGRESS_UNIT уже существует и отличается от поставляемого RemnaSuper."
            return 1
        fi
    fi
    if [[ ! -x /usr/sbin/nft ]]; then
        check_command apt-get || return 1
        step "Установка nftables..."
        if ! apt-get update || ! apt-get install -y --no-install-recommends nftables; then
            error "Не удалось установить nftables."
            return 1
        fi
    fi
    check_command /usr/sbin/nft || return 1
    if ! /usr/sbin/nft --check --file "$SMTP_EGRESS_RULES"; then
        error "Проверка правил nftables завершилась ошибкой."
        return 1
    fi

    trap '[[ -z "$staged_unit" ]] || rm -f -- "$staged_unit"' EXIT
    if [[ ! -f "$SMTP_EGRESS_UNIT" ]]; then
        if ! staged_unit="$(mktemp "${SMTP_EGRESS_UNIT}.XXXXXX")" ||
            ! install -m 0644 -- "$unit_source" "$staged_unit" ||
            ! ln -T -- "$staged_unit" "$SMTP_EGRESS_UNIT"; then
            error "Не удалось установить $SMTP_EGRESS_UNIT."
            return 1
        fi
        created_unit=true
    fi

    if systemctl daemon-reload && systemctl enable "$SMTP_EGRESS_SERVICE" &&
        systemctl reload-or-restart "$SMTP_EGRESS_SERVICE"; then
        return 0
    fi

    error "Не удалось включить $SMTP_EGRESS_SERVICE."
    if [[ "$created_unit" == true ]]; then
        if ! systemctl disable "$SMTP_EGRESS_SERVICE" ||
            ! rm -f -- "$SMTP_EGRESS_UNIT" || ! systemctl daemon-reload; then
            warn "Не удалось полностью отменить установку службы $SMTP_EGRESS_SERVICE."
        fi
    fi
    return 1
)

close_outbound_smtp() {
    header "Закрыть исходящий SMTP"
    if ! enable_smtp_egress_service; then
        pause
        return 1
    fi

    success "Исходящий TCP на порты 25, 465 и 587 заблокирован по IPv4 и IPv6. Служба включена в автозапуск."
    info "Для дополнительной блокировки в Xray добавьте это правило в routing.rules перед разрешающими правилами."
    info "Укажите тег существующего outbound с протоколом blackhole, если он отличается."
    printf '\n%s\n\n' '{"type":"field","network":"tcp","port":"25,465,587","outboundTag":"blackhole"}'
    pause
}
