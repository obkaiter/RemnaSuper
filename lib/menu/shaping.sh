#!/usr/bin/env bash

_shaper_read_integer() {
    local target="$1" label="$2" minimum="$3" maximum="$4" default="$5"
    local value
    while true; do
        read -rp "$label [$default]: " value
        value="${value:-$default}"
        if [[ "$value" =~ ^[0-9]+$ ]] && \
           [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ]; then
            printf -v "$target" '%s' "$value"
            return 0
        fi
        warn "Введите целое число от $minimum до $maximum."
    done
}

_shaper_read_decimal() {
    local target="$1" label="$2" minimum="$3" maximum="$4" default="$5"
    local value
    while true; do
        read -rp "$label [$default]: " value
        value="${value:-$default}"
        value="${value/,/.}"
        if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && \
           awk -v value="$value" -v min="$minimum" -v max="$maximum" \
               'BEGIN { exit !(value >= min && value <= max) }'; then
            printf -v "$target" '%s' "$value"
            return 0
        fi
        warn "Введите число от $minimum до $maximum."
    done
}

_shaper_read_ports() {
    local target="$1" value port count
    local -a port_values
    while true; do
        read -rp "TCP/UDP-порты через запятую (0 = все порты): " value
        value="${value//[[:space:]]/}"
        if ! [[ "$value" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            warn "Пример корректного значения: 443,8443 или 0."
            continue
        fi
        count=0
        local valid=1
        IFS=',' read -ra port_values <<< "$value"
        for port in "${port_values[@]}"; do
            count=$((count + 1))
            if [ "$((10#$port))" -gt 65535 ]; then
                valid=0
            fi
        done
        if [ "$count" -gt 32 ]; then
            warn "В одном правиле поддерживается не более 32 портов."
            continue
        fi
        if [ "$valid" -ne 1 ] || { [[ ",$value," == *,0,* ]] && [ "$value" != "0" ]; }; then
            warn "Допустимы порты 1-65535; значение 0 указывается отдельно."
            continue
        fi
        printf -v "$target" '%s' "$value"
        return 0
    done
}

shaper_controller_path() {
    if [ -x "$SHAPER_CONTROLLER" ]; then
        printf '%s\n' "$SHAPER_CONTROLLER"
    else
        printf '%s\n' "$REMNASUPER_APP_DIR/lib/shaping/controller.py"
    fi
}

show_shaper_menu() {
    local service_status interface rule_count
    if shaper_service_active; then
        service_status="${GREEN}работает${NC}"
    else
        service_status="${YELLOW}остановлен${NC}"
    fi
    interface="$(shaper_current_interface 2>/dev/null || echo 'не выбран')"
    rule_count=0
    if [ -f "$SHAPER_RULES_FILE" ]; then
        rule_count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("rules", {})))' \
            "$SHAPER_RULES_FILE" 2>/dev/null || echo '?')"
    fi

    clear
    show_brand "Шейпер трафика (eBPF + EDT)"
    printf "Статус: %b | интерфейс: %s | правил: %s\n" \
        "$service_status" "$interface" "$rule_count"
    printf "${DIM}Лимит на IP относится к внешнему IP VPN-клиента; общий NAT делит один лимит.${NC}\n"

    section "Правила и наблюдение"
    menu_item 1 "Показать правила и состояние tc"
    menu_item 2 "Добавить или изменить правило"
    menu_item 3 "Удалить правило"
    menu_item 4 "Статистика по IP"
    menu_item 5 "Управление whitelist"

    section "Движок"
    menu_item 6 "Сменить сетевой интерфейс"
    menu_item 7 "Обновить файлы и перезапустить"
    menu_item 8 "Показать журнал сервиса"
    menu_danger_item 9 "Остановить (сохранить настройки)"
    menu_danger_item 10 "Полностью удалить шейпер"

    section "Навигация"
    menu_back_item
    prompt_choice "0-10"
}

shaper_show_status() {
    local controller interface
    header "Правила и состояние шейпера"
    controller="$(shaper_controller_path)"
    interface="$(shaper_current_interface 2>/dev/null || true)"

    if shaper_service_active; then
        success "Сервис $SHAPER_SERVICE_NAME работает на $interface."
    else
        warn "Сервис $SHAPER_SERVICE_NAME не запущен."
    fi
    if [ -n "$interface" ] && command -v tc >/dev/null 2>&1; then
        printf "\nКорневая очередь:\n"
        tc qdisc show dev "$interface" root 2>/dev/null || true
        printf "\nФильтры RemnaSuper:\n"
        tc filter show dev "$interface" egress pref 49152 2>/dev/null || true
        tc filter show dev "$interface" ingress pref 49152 2>/dev/null || true
    fi
    printf "\nСохранённые правила:\n"
    python3 "$controller" --rules-file "$SHAPER_RULES_FILE" list || true
    pause
}

shaper_add_rule() {
    local controller interface rule_id mode ports download upload
    local penalty="0" burst="0" window="0" duration="0"
    local ssh_ip="" add_ssh_to_whitelist=0
    local reconfigure_engine=0

    header "Добавление или изменение правила"
    check_command ip || { pause; return; }
    check_command python3 || { pause; return; }
    controller="$(shaper_controller_path)"

    printf "Правило ограничивает TCP и UDP на выбранных серверных портах.\n"
    printf "${YELLOW}Указывайте входящие порты Xray, а не внутренние порты Docker.${NC}\n\n"
    python3 "$controller" --rules-file "$SHAPER_RULES_FILE" list 2>/dev/null || true

    _shaper_read_integer rule_id "ID правила" 0 31 0
    printf "\n  1 — постоянный лимит на каждый IP\n"
    printf "  2 — быстрый режим, затем штраф после burst-квоты\n"
    printf "  3 — единый общий лимит для всего трафика правила\n"
    _shaper_read_integer mode "Режим" 1 3 1

    if command -v ss >/dev/null 2>&1; then
        printf "\nСлушающие TCP/UDP-порты (подсказка):\n"
        ss -H -lntup 2>/dev/null | head -n 20 || true
        printf "\n"
    fi
    _shaper_read_ports ports
    _shaper_read_decimal download "Download, Мбит/с" 0.1 100000 50
    _shaper_read_decimal upload "Upload, Мбит/с" 0.1 100000 50

    if [ "$mode" -eq 2 ]; then
        _shaper_read_decimal burst "Burst-квота на направление, МиБ" 0.1 1048576 100
        _shaper_read_decimal window "Окно burst, секунд" 0.1 86400 10
        _shaper_read_decimal penalty "Скорость во время штрафа, Мбит/с (0 = блок)" 0 100000 4
        _shaper_read_decimal duration "Длительность штрафа, секунд" 0.1 604800 60
    fi

    if [ "$ports" = "0" ]; then
        warn "Правило на все порты затронет SSH, панель, node-agent и системные обновления."
        ssh_ip="${SSH_CONNECTION%% *}"
        if [ -n "$ssh_ip" ] && confirm "Добавить текущий SSH-адрес $ssh_ip в whitelist?"; then
            add_ssh_to_whitelist=1
        fi
    fi

    interface="$(shaper_current_interface 2>/dev/null || true)"
    if ! shaper_validate_interface "$interface"; then
        interface="$(shaper_choose_interface)" || { pause; return; }
        reconfigure_engine=1
    fi

    printf "\nИнтерфейс: %s\nПравило: #%s, режим %s, порты %s\n" \
        "$interface" "$rule_id" "$mode" "$ports"
    printf "Скорость DL/UL: %s/%s Мбит/с\n" "$download" "$upload"
    if [ "$mode" -eq 2 ]; then
        printf "Burst: %s МиБ за %s с; штраф %s Мбит/с на %s с\n" \
            "$burst" "$window" "$penalty" "$duration"
    fi
    printf "${YELLOW}При первом запуске корневая очередь интерфейса будет заменена на fq.${NC}\n"
    if ! confirm "Применить правило?"; then
        info "Действие отменено."
        pause
        return
    fi

    if ! shaper_service_active || [ ! -x "$SHAPER_CONTROLLER" ] || \
       [ ! -e "$SHAPER_PIN_DIR/maps/rules" ] || [ "$reconfigure_engine" -eq 1 ]; then
        shaper_prepare_engine "$interface" || { pause; return; }
    fi

    if [ "$add_ssh_to_whitelist" -eq 1 ]; then
        install -d -m 0755 "$SHAPER_CONFIG_DIR"
        touch "$SHAPER_WHITELIST_FILE"
        chmod 0600 "$SHAPER_WHITELIST_FILE"
        grep -Fxq "$ssh_ip" "$SHAPER_WHITELIST_FILE" 2>/dev/null || \
            printf '%s\n' "$ssh_ip" >> "$SHAPER_WHITELIST_FILE"
        shaper_sync_whitelist || { pause; return; }
    fi

    if "$SHAPER_CONTROLLER" --pin-dir "$SHAPER_PIN_DIR/maps" \
        --rules-file "$SHAPER_RULES_FILE" set \
        --rule-id "$rule_id" --mode "$mode" --ports "$ports" \
        --download-mbps "$download" --upload-mbps "$upload" \
        --penalty-mbps "$penalty" --burst-mib "$burst" \
        --window-seconds "$window" --penalty-seconds "$duration"; then
        success "Правило применено без перезапуска подключений."
    else
        error "Не удалось применить правило. Проверьте конфликт портов и журнал сервиса."
    fi
    pause
}

shaper_delete_rule() {
    local controller rule_id
    header "Удаление правила шейпера"
    controller="$(shaper_controller_path)"
    python3 "$controller" --rules-file "$SHAPER_RULES_FILE" list || { pause; return; }
    printf "\n"
    _shaper_read_integer rule_id "ID правила для удаления" 0 31 0
    if confirm "Удалить правило #$rule_id?"; then
        python3 "$controller" --pin-dir "$SHAPER_PIN_DIR/maps" \
            --rules-file "$SHAPER_RULES_FILE" delete --rule-id "$rule_id"
    else
        info "Действие отменено."
    fi
    pause
}

shaper_show_stats() {
    header "Статистика шейпера"
    if ! shaper_service_active; then
        warn "Сервис шейпера не запущен."
    else
        "$SHAPER_CONTROLLER" --pin-dir "$SHAPER_PIN_DIR/maps" \
            --rules-file "$SHAPER_RULES_FILE" stats --full
        printf "\n${DIM}Счётчики живут в ядре и сбрасываются при перезапуске сервиса.${NC}\n"
    fi
    pause
}

shaper_whitelist_show() {
    if [ ! -s "$SHAPER_WHITELIST_FILE" ]; then
        info "Whitelist пуст."
        return
    fi
    nl -ba "$SHAPER_WHITELIST_FILE"
}

shaper_whitelist_add() {
    local address
    read -rp "IPv4 или IPv6 для добавления: " address
    if ! python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$address" 2>/dev/null; then
        error "Некорректный IP-адрес. CIDR-подсети не поддерживаются."
        return 1
    fi
    install -d -m 0755 "$SHAPER_CONFIG_DIR"
    touch "$SHAPER_WHITELIST_FILE"
    chmod 0600 "$SHAPER_WHITELIST_FILE"
    if grep -Fxq "$address" "$SHAPER_WHITELIST_FILE"; then
        info "Адрес уже находится в whitelist."
    else
        printf '%s\n' "$address" >> "$SHAPER_WHITELIST_FILE"
        success "Адрес добавлен."
    fi
    shaper_sync_whitelist
}

shaper_whitelist_delete() {
    local address temporary
    shaper_whitelist_show
    read -rp "Точный IP для удаления: " address
    if ! grep -Fxq "$address" "$SHAPER_WHITELIST_FILE" 2>/dev/null; then
        error "Такого адреса в whitelist нет."
        return 1
    fi
    temporary="$(mktemp)"
    awk -v target="$address" '$0 != target' "$SHAPER_WHITELIST_FILE" > "$temporary"
    chmod 0600 "$temporary"
    mv "$temporary" "$SHAPER_WHITELIST_FILE"
    shaper_sync_whitelist
    success "Адрес удалён."
}

shaper_whitelist_menu() {
    local choice
    while true; do
        clear
        show_brand "Whitelist шейпера"
        printf "IP из списка проходят без ограничения скорости. Поддерживаются точные IPv4/IPv6.\n\n"
        shaper_whitelist_show
        printf "\n"
        menu_item 1 "Добавить IP"
        menu_item 2 "Удалить IP"
        menu_danger_item 3 "Очистить whitelist"
        menu_back_item
        prompt_choice "0-3"
        read -r choice
        case "$choice" in
            1) shaper_whitelist_add; pause ;;
            2) shaper_whitelist_delete; pause ;;
            3)
                if confirm "Очистить whitelist?"; then
                    install -d -m 0755 "$SHAPER_CONFIG_DIR"
                    install -m 0600 /dev/null "$SHAPER_WHITELIST_FILE"
                    shaper_sync_whitelist
                    success "Whitelist очищен."
                fi
                pause
                ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

shaper_change_interface() {
    local interface
    header "Смена интерфейса шейпера"
    interface="$(shaper_choose_interface)" || { pause; return; }
    warn "Перезапуск кратковременно снимет и заново установит правила tc."
    if confirm "Перенести шейпер на $interface?"; then
        shaper_prepare_engine "$interface"
    else
        info "Действие отменено."
    fi
    pause
}

shaper_restart() {
    local interface
    header "Обновление движка шейпера"
    interface="$(shaper_current_interface 2>/dev/null || true)"
    if ! shaper_validate_interface "$interface"; then
        interface="$(shaper_choose_interface)" || { pause; return; }
    fi
    shaper_prepare_engine "$interface"
    pause
}

shaper_view_logs() {
    header "Журнал $SHAPER_SERVICE_NAME"
    journalctl -u "$SHAPER_SERVICE_NAME" --no-pager -n 100 || true
    pause
}

shaper_menu() {
    local choice
    while true; do
        show_shaper_menu
        read -r choice
        case "$choice" in
            1) shaper_show_status ;;
            2) shaper_add_rule ;;
            3) shaper_delete_rule ;;
            4) shaper_show_stats ;;
            5) shaper_whitelist_menu ;;
            6) shaper_change_interface ;;
            7) shaper_restart ;;
            8) shaper_view_logs ;;
            9)
                if confirm_action "Остановка шейпера" \
                    "Скоростные ограничения будут сняты, но правила и whitelist сохранятся."; then
                    shaper_disable
                    pause
                fi
                ;;
            10)
                if confirm_action "Полное удаление шейпера" \
                    "Сервис, eBPF-карты, все правила и whitelist будут безвозвратно удалены."; then
                    shaper_remove
                    pause
                fi
                ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
