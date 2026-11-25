#!/usr/bin/env bash

tui_unit_state() {
    local unit="$1" load_state active_state
    if ! load_state="$(systemctl show --property=LoadState --value "$unit")" ||
       ! active_state="$(systemctl show --property=ActiveState --value "$unit")"; then
        printf '%s\n' 'Неизвестно: systemd недоступен'
    elif [[ "$load_state" == not-found ]]; then
        printf '%s\n' '[--] Не установлен'
    elif [[ -n "$active_state" ]]; then
        printf '%s\n' "$active_state"
    else
        printf '%s\n' 'Неизвестно'
    fi
}

tui_status() {
    local dir unit
    printf '%s\n' "$(date -Is)"
    for dir in "$NODE_DIR" "$AGENT_DIR"; do
        printf '%s\n' "$dir"
        if [[ ! -f "$dir/docker-compose.yml" ]]; then
            printf '%s\n' '  [--] Compose-файл не найден'
        elif command -v docker >/dev/null; then
            (cd -- "$dir" && timeout 5 docker compose ps) || warn "Не удалось получить состояние Compose."
        else
            warn "Docker недоступен."
        fi
    done
    for unit in haproxy.service "$RELAY_SERVICE" ufw.service ssh.service; do
        printf '%s  %s\n' "$unit" "$(tui_unit_state "$unit")"
    done
}

tui_follow_access() {
    check_command tail && tail -f -- "$LOG_DIR/access.log"
}

tui_follow_xlogs() {
    check_docker && docker exec -it remnanode xlogs
}

tui_psiphon() {
    local instance="$1" operation="$2"
    shift 2
    set_psiphon_instance "$instance" || return 1
    "$operation" "$@"
}

tui_psiphon_instances() (
    local instance
    local -a instances
    mapfile -t instances < <(list_psiphon_instances)
    (( ${#instances[@]} )) || { info "Подключений Psiphon пока нет."; return 0; }
    for instance in "${instances[@]}"; do
        set_psiphon_instance "$instance" || continue
        if [[ -x "$PSIPHON_CLI" ]]; then
            printf '№%s  %s  %s\n' "$instance" "$PSIPHON_SERVICE" "$(tui_unit_state "$PSIPHON_SERVICE")"
        else
            printf '№%s  %s  Неполная установка\n' "$instance" "$PSIPHON_SERVICE"
        fi
    done
)

tui_psiphon_add() {
    local instance suggested
    suggested="$(next_psiphon_instance)" || { error "Все номера от 1 до 99 заняты."; return 1; }
    request_input instance "Номер нового экземпляра Psiphon" "$suggested" || return "$?"
    set_psiphon_instance "$instance" || return 1
    if psiphon_instance_exists "$PSIPHON_INSTANCE"; then
        error "Подключение №$PSIPHON_INSTANCE уже существует."
        return 1
    fi
    confirm "Установить Psiphon №$PSIPHON_INSTANCE из Chara-Freedom/vps-psiphon с параметром --no-http?" ||
        return 130
    install_psiphon
}

tui_warp_status() {
    printf '%s  %s\n' "$WARP_NATIVE_SERVICE" "$(tui_unit_state "$WARP_NATIVE_SERVICE")"
    if ! systemctl show --property=UnitFileState --value "$WARP_NATIVE_SERVICE"; then
        warn "Состояние автозапуска неизвестно."
    fi
    if command -v wg >/dev/null; then
        wg show "$WARP_NATIVE_INTERFACE" || warn "Сведения WireGuard недоступны."
    fi
}

tui_smtp_status() {
    local rules_state unit_file_state
    rules_state="$(smtp_egress_rules_state)" || rules_state=unknown
    unit_file_state="$(systemctl show --property=UnitFileState --value "$SMTP_EGRESS_SERVICE")" ||
        unit_file_state=unknown
    printf 'Правила: %s\nСостояние автозапуска: %s\n' "$rules_state" "${unit_file_state:-не установлен}"
    if [[ "$rules_state" == current ]]; then
        /usr/sbin/nft list chain inet remnasuper_smtp smtp_egress
    fi
}

tui_smtp_xray() {
    printf '%s\n' 'Добавьте правило перед разрешающими в routing.rules. Используйте тег существующего outbound blackhole.' \
        '{' '    "type": "field",' '    "network": "tcp",' '    "port": "25",' '    "outboundTag": "block"' '}'
}

tui_smtp() (
    local action="$1" parent candidate
    if [[ "$action" == enable && ! -f "$SMTP_EGRESS_RULES" ]]; then
        for parent in "$INSTALL_DIR" "$INSTALL_DIR/lib" "$INSTALL_DIR/lib/system"; do
            if [[ -L "$parent" ]] || ! mkdir -p -- "$parent" ||
               [[ "$(stat -c %u -- "$parent")" != 0 || "$(find "$parent" -maxdepth 0 -perm /022 -printf x)" == x ]]; then
                error "Небезопасный каталог $parent."
                return 1
            fi
        done
        candidate="$(mktemp "${SMTP_EGRESS_RULES}.XXXXXXXX")" || return 1
        trap 'rm -f -- "$candidate"' EXIT
        install -m 0644 "$APP_DIR/lib/system/smtp-egress.nft" "$candidate" || return 1
        ln -T -- "$candidate" "$SMTP_EGRESS_RULES" || return 1
    fi
    configure_smtp_egress "$action" || return 1
    if [[ "$action" == enable ]]; then tui_smtp_xray; fi
)

tui_routes() {
    local -a connections=()
    local route_mode line
    read_relay_connections connections route_mode || return 1
    (( ${#connections[@]} )) || { info "Распознаваемых маршрутов SNI нет."; return 0; }
    printf 'Режим: %s\n' "$route_mode"
    for line in "${connections[@]}"; do printf '%s\n' "$line"; done
}

tui_route_add() {
    local domain="${1,,}" port="$2"
    if ! valid_relay_domain "$domain" || ! valid_relay_port "$port"; then
        error "Укажите полное доменное имя и порт от 1 до 65535."
        return 1
    fi
    change_relay_connection add "$domain" "$((10#$port))"
}

tui_route_remove() {
    local -a connections=() choices=()
    local route_mode index choice kind domain frontend backend unused expected actual
    expected="$(sha256sum -- "$RELAY_HAPROXY_CONFIG")" || return 1
    read_relay_connections connections route_mode || return 1
    (( ${#connections[@]} )) || { info "Распознаваемых маршрутов SNI нет."; return 0; }
    for index in "${!connections[@]}"; do choices+=("$index" "${connections[index]}"); done
    tui_choose choice "Выберите удаляемый маршрут" '' "${choices[@]}" || return "$?"
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice < ${#connections[@]} )) || return 1
    IFS=' ' read -r kind domain frontend backend unused <<< "${connections[choice]}"
    if [[ "$kind" != external ]]; then frontend='' backend=''; fi
    confirm "Удалить SNI $domain${frontend:+ из $frontend → $backend}? HAProxy перечитает конфиг или запустится." ||
        return 130
    actual="$(sha256sum -- "$RELAY_HAPROXY_CONFIG")" || return 1
    [[ "$expected" == "$actual" ]] || { error "Конфигурация изменилась. Выберите маршрут заново."; return 1; }
    change_relay_connection remove "$domain" '' "$frontend" "$backend"
}

tui_relay_site() {
    local domain="${1,,}"
    valid_relay_domain "$domain" || { error "Укажите полное доменное имя."; return 1; }
    install_relay_site "$domain"
}

tui_relay_status() {
    check_command systemctl && systemctl --no-pager status haproxy.service
}

tui_relay_logs() {
    check_command journalctl && journalctl -u haproxy.service -n 200 --no-pager
}

tui_relay_config() {
    [[ ! -L "$RELAY_HAPROXY_CONFIG" && -f "$RELAY_HAPROXY_CONFIG" ]] || return 1
    awk '
        tolower($0) ~ /password|secret|token|credential|stats[[:space:]]+auth|user[[:space:]]+.*password/ {
            print "[скрыто]"
            next
        }
        { print }
    ' "$RELAY_HAPROXY_CONFIG"
}

tui_bandwidth() {
    local mbps
    mbps="$(read_relay_bandwidth)" || return 1
    if [[ -z "$mbps" ]]; then info "Лимит не настроен."
    else printf '%s Мбит/с на IP в каждом направлении.\n' "$mbps"; fi
}

tui_relay_backend() {
    local list item selected
    local -a choices=()
    list="$(relay_traffic_command backends --names)" || return 1
    [[ -n "$list" ]] || { info "Сборщик ещё не обнаружил ни одного backend."; return 0; }
    while IFS= read -r item; do choices+=("$item" "$item"); done <<< "$list"
    tui_choose selected "Выберите backend" '' "${choices[@]}" || return "$?"
    relay_traffic_command backend -- "$selected"
}
