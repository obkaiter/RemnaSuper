#!/usr/bin/env bash

choose_logrotate_profile() {
    tui_choose "$1" "Выберите профиль ротации. Стандартные профили после ротации перезапускают работающий remnanode." 0 \
        0 "Пропустить настройку ротации" \
        1 "Малая нода · ежедневно · хранить 7 дней" \
        2 "Средняя нода · ежедневно · хранить 3 дня" \
        3 "Высокая нагрузка · по достижении 100 МБ · 5 архивов" \
        4 "Редактировать конфигурацию"
}

validate_logrotate_change() {
    local candidate="$1" backup
    check_command logrotate || return 1
    if [[ -L "$ROTATE_CONF" ]] || ! logrotate -d "$candidate"; then
        error "Конфигурация logrotate не прошла проверку."
        return 1
    fi
    if [[ -f "$ROTATE_CONF" ]]; then
        backup_config_file "$ROTATE_CONF" backup || return 1
    fi
}

edit_logrotate_config() (
    local expected=absent current='' updated candidate actual=absent
    [[ ! -L "$ROTATE_CONF" ]] || return 1
    if [[ -f "$ROTATE_CONF" ]]; then
        expected="$(sha256sum -- "$ROTATE_CONF")" && current="$(cat -- "$ROTATE_CONF")" || return 1
    fi
    tui_edit updated "Конфигурация $ROTATE_CONF" "$current" || return "$?"
    [[ "$updated" != "$current" ]] || return 0
    confirm "Проверить и заменить $ROTATE_CONF? Существующая конфигурация будет сохранена в резервной копии." ||
        return 130
    if [[ -f "$ROTATE_CONF" ]]; then actual="$(sha256sum -- "$ROTATE_CONF")" || return 1; fi
    [[ "$expected" == "$actual" ]] || { error "Конфигурация изменилась. Откройте редактор заново."; return 1; }
    candidate="$(mktemp "${ROTATE_CONF}.XXXXXXXX")" || return 1
    trap 'rm -f -- "$candidate"' EXIT
    printf '%s\n' "$updated" > "$candidate" &&
        validate_logrotate_change "$candidate" &&
        chmod 644 "$candidate" &&
        mv -fT -- "$candidate" "$ROTATE_CONF"
)
