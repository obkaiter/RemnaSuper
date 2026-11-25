#!/usr/bin/env bash

smtp_egress_rules_state() {
    local tables rules

    if [[ ! -x /usr/sbin/nft ]]; then
        [[ ! -e "$SMTP_EGRESS_UNIT" ]] || return 1
        printf '%s\n' absent
        return 0
    fi
    tables="$(/usr/sbin/nft list tables inet)" || return 1
    if ! grep -Fxq 'table inet remnasuper_smtp' <<< "$tables"; then
        printf '%s\n' absent
        return 0
    fi
    rules="$(/usr/sbin/nft list table inet remnasuper_smtp)" || return 1
    if [[ "$rules" == *'chain smtp_egress {'*'limit rate '* &&
          "$rules" == *'jump smtp_egress'*'jump smtp_egress'* ]]; then
        printf '%s\n' current
    else
        printf '%s\n' outdated
    fi
}

configure_smtp_egress() (
    local action="$1"
    local unit_source="$REMNASUPER_APP_DIR/lib/system/$SMTP_EGRESS_SERVICE"
    local lock_fd fragment_path

    check_command systemctl && check_command flock || return 1
    if ! { exec {lock_fd}<>"$SMTP_EGRESS_LOCK"; } || ! flock "$lock_fd"; then
        error "Не удалось получить блокировку настройки SMTP."
        return 1
    fi
    fragment_path="$(systemctl show --property=FragmentPath --value "$SMTP_EGRESS_SERVICE")" || return 1
    if [[ -n "$fragment_path" && "$fragment_path" != "$SMTP_EGRESS_UNIT" ]]; then
        error "Служба $SMTP_EGRESS_SERVICE загружена из другого файла: $fragment_path."
        return 1
    fi
    if [[ -e "$SMTP_EGRESS_UNIT" || -L "$SMTP_EGRESS_UNIT" ]]; then
        if [[ -L "$SMTP_EGRESS_UNIT" || ! -f "$SMTP_EGRESS_UNIT" ]] ||
            ! cmp -s -- "$unit_source" "$SMTP_EGRESS_UNIT"; then
            error "Файл $SMTP_EGRESS_UNIT уже существует и отличается от поставляемого RemnaSuper."
            return 1
        fi
    fi

    case "$action" in
        enable) enable_smtp_egress_service "$unit_source" ;;
        disable) disable_smtp_egress_service ;;
        *) return 1 ;;
    esac
)

enable_smtp_egress_service() (
    local unit_source="$1"
    local staged_unit='' created_unit=false unit_file_state

    if [[ ! -f "$unit_source" || ! -f "$SMTP_EGRESS_RULES" ]]; then
        error "Файлы службы SMTP не найдены в установленной копии RemnaSuper."
        return 1
    fi
    unit_file_state="$(systemctl show --property=UnitFileState --value "$SMTP_EGRESS_SERVICE")" || return 1
    if [[ -f "$SMTP_EGRESS_UNIT" ]] && systemctl is-active --quiet "$SMTP_EGRESS_SERVICE" &&
        [[ "$(smtp_egress_rules_state)" == current ]]; then
        [[ "$unit_file_state" == enabled ]] || systemctl enable "$SMTP_EGRESS_SERVICE"
        return $?
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

    if systemctl daemon-reload &&
        { [[ "$unit_file_state" == enabled ]] || systemctl enable "$SMTP_EGRESS_SERVICE"; } &&
        systemctl reload-or-restart "$SMTP_EGRESS_SERVICE"; then
        return 0
    fi

    error "Не удалось включить $SMTP_EGRESS_SERVICE."
    if [[ "$unit_file_state" != enabled ]] && ! systemctl disable "$SMTP_EGRESS_SERVICE"; then
        warn "Не удалось восстановить прежний автозапуск службы $SMTP_EGRESS_SERVICE."
    fi
    if [[ "$created_unit" == true ]]; then
        if ! rm -f -- "$SMTP_EGRESS_UNIT" || ! systemctl daemon-reload; then
            warn "Не удалось полностью отменить установку службы $SMTP_EGRESS_SERVICE."
        fi
    fi
    return 1
)

disable_smtp_egress_service() {
    local unit_file_state active_state rules_state

    if [[ -f "$SMTP_EGRESS_UNIT" ]]; then
        unit_file_state="$(systemctl show --property=UnitFileState --value "$SMTP_EGRESS_SERVICE")" || return 1
        if [[ "$unit_file_state" == enabled ]]; then
            systemctl disable "$SMTP_EGRESS_SERVICE" || return 1
            unit_file_state="$(systemctl show --property=UnitFileState --value "$SMTP_EGRESS_SERVICE")" || return 1
        fi
        if [[ "$unit_file_state" == enabled-runtime ]]; then
            systemctl disable --runtime "$SMTP_EGRESS_SERVICE" || return 1
        fi
        active_state="$(systemctl show --property=ActiveState --value "$SMTP_EGRESS_SERVICE")" || return 1
        if [[ "$active_state" != inactive ]]; then
            systemctl stop "$SMTP_EGRESS_SERVICE" || return 1
        fi
    fi

    rules_state="$(smtp_egress_rules_state)" || return 1
    if [[ "$rules_state" != absent ]]; then
        /usr/sbin/nft 'add table inet remnasuper_smtp; delete table inet remnasuper_smtp' || return 1
    fi
}
