#!/usr/bin/env bash

tor_remnanode_uses_host_network() {
    local node_network=""

    if command -v docker >/dev/null 2>&1; then
        node_network="$(docker inspect -f '{{.HostConfig.NetworkMode}}' remnanode 2>/dev/null || true)"
        [ "$node_network" = "host" ] && return 0
    fi

    [ -f "$COMPOSE_FILE" ] || return 1
    awk '
        /^services:[[:space:]]*$/ { in_services=1; next }
        in_services && /^[^[:space:]#][^:]*:/ { in_services=0 }
        in_services && /^  remnanode:[[:space:]]*$/ { in_remnanode=1; next }
        in_remnanode && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { in_remnanode=0 }
        in_remnanode && /^[[:space:]]*network_mode:[[:space:]]*["'\'']?host["'\'']?[[:space:]]*$/ { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$COMPOSE_FILE" 2>/dev/null
}

tor_service_unit() {
    if systemctl cat tor@default.service >/dev/null 2>&1; then
        printf "tor@default.service\n"
    elif systemctl cat tor.service >/dev/null 2>&1; then
        printf "tor.service\n"
    else
        return 1
    fi
}

restart_tor_service() {
    local service_unit
    service_unit="$(tor_service_unit)" || {
        error "Сервис Tor не найден после установки пакета."
        return 1
    }

    systemctl daemon-reload || return 1
    if systemctl cat tor.service >/dev/null 2>&1; then
        systemctl enable tor.service >/dev/null 2>&1 || return 1
    else
        systemctl enable "$service_unit" >/dev/null 2>&1 || return 1
    fi
    systemctl restart "$service_unit" || return 1
    systemctl is-active --quiet "$service_unit"
}

verify_tor_config() {
    if [ -f /usr/share/tor/tor-service-defaults-torrc ]; then
        tor --defaults-torrc /usr/share/tor/tor-service-defaults-torrc \
            -f "$TOR_MAIN_CONFIG" --verify-config >/dev/null
    else
        tor --verify-config -f "$TOR_MAIN_CONFIG" >/dev/null
    fi
}

write_tor_outbound() {
    local tmp_file

    mkdir -p "$TOR_DIR" || return 1
    tmp_file="$(mktemp "$TOR_DIR/.xray-outbound.XXXXXX")" || return 1
    if ! cat > "$tmp_file" << EOF
{
  "tag": "tor",
  "protocol": "socks",
  "settings": {
    "address": "127.0.0.1",
    "port": $TOR_SOCKS_PORT
  }
}
EOF
    then
        rm -f "$tmp_file"
        return 1
    fi
    chmod 644 "$tmp_file"
    mv "$tmp_file" "$TOR_OUTBOUND_FILE"
}

tor_exit_ip() {
    curl -4 --proxy "socks5h://127.0.0.1:${TOR_SOCKS_PORT}" \
        --connect-timeout 10 --max-time 30 -fsS https://api.ipify.org 2>/dev/null
}

wait_for_tor() {
    local attempt
    local exit_ip

    for ((attempt = 1; attempt <= 12; attempt++)); do
        exit_ip="$(tor_exit_ip)" && [ -n "$exit_ip" ] && {
            printf "%s\n" "$exit_ip"
            return 0
        }
        sleep 5
    done
    return 1
}

install_tor() {
    header "Установка Tor"
    local package
    local previous_config=""
    local torrc_backup=""
    local torrc_changed=0
    local tmp_config
    local exit_ip
    local -a newly_installed_packages=()

    check_command apt-get || { pause; return; }
    check_command systemctl || { pause; return; }

    if ! tor_remnanode_uses_host_network; then
        error "RemnaNode не использует network_mode: host или его конфигурация не найдена."
        warn "Xray внутри контейнера не сможет подключиться к Tor на 127.0.0.1:${TOR_SOCKS_PORT}. Установка прервана."
        pause
        return
    fi

    for package in tor tor-geoipdb; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed'; then
            newly_installed_packages+=("$package")
        fi
    done

    step "Установка Tor и curl..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update ||
        ! DEBIAN_FRONTEND=noninteractive apt-get install -y tor curl; then
        error "Не удалось установить Tor."
        pause
        return
    fi

    mkdir -p "$TOR_DIR" "$TOR_CONFIG_DIR" || {
        error "Не удалось создать каталоги конфигурации Tor."
        pause
        return
    }
    chmod 755 "$TOR_DIR" "$TOR_CONFIG_DIR"

    if [ ! -f "$TOR_PACKAGE_MARKER" ] && [ "${#newly_installed_packages[@]}" -gt 0 ]; then
        printf "%s\n" "${newly_installed_packages[@]}" > "$TOR_PACKAGE_MARKER"
        chmod 600 "$TOR_PACKAGE_MARKER"
    fi

    if [ -f "$TOR_CONFIG_FILE" ]; then
        previous_config="$(mktemp)"
        cp "$TOR_CONFIG_FILE" "$previous_config" || {
            rm -f "$previous_config"
            error "Не удалось создать временную копию $TOR_CONFIG_FILE."
            pause
            return
        }
    fi

    tmp_config="$(mktemp "$TOR_CONFIG_DIR/.remnasuper.XXXXXX")" || {
        rm -f "$previous_config"
        error "Не удалось создать временный файл конфигурации Tor."
        pause
        return
    }
    cat > "$tmp_config" << EOF
# Managed by RemnaSuper. Changes may be overwritten.
SocksPort 127.0.0.1:$TOR_SOCKS_PORT
ControlPort 127.0.0.1:$TOR_CONTROL_PORT
CookieAuthentication 1
EOF
    chmod 644 "$tmp_config"
    mv "$tmp_config" "$TOR_CONFIG_FILE"

    if ! grep -Eq '^[[:space:]]*%include[[:space:]]+(/etc/tor/)?torrc\.d/\*\.conf([[:space:]]|$)' "$TOR_MAIN_CONFIG" 2>/dev/null &&
        ! grep -Fq "%include $TOR_CONFIG_FILE" "$TOR_MAIN_CONFIG" 2>/dev/null; then
        torrc_backup="${TOR_MAIN_CONFIG}.bak.$(date +%F_%H%M%S)"
        if ! cp "$TOR_MAIN_CONFIG" "$torrc_backup"; then
            [ -n "$previous_config" ] && mv "$previous_config" "$TOR_CONFIG_FILE"
            [ -z "$previous_config" ] && rm -f "$TOR_CONFIG_FILE"
            error "Не удалось создать бэкап $TOR_MAIN_CONFIG."
            pause
            return
        fi
        {
            printf "\n# BEGIN REMNASUPER TOR\n"
            printf "%%include %s\n" "$TOR_CONFIG_FILE"
            printf "# END REMNASUPER TOR\n"
        } >> "$TOR_MAIN_CONFIG"
        torrc_changed=1
        info "Бэкап основной конфигурации Tor: $torrc_backup"
    fi

    step "Проверка конфигурации Tor..."
    if ! verify_tor_config; then
        error "Конфигурация Tor не прошла проверку. Выполняется откат."
        if [ "$torrc_changed" -eq 1 ]; then
            mv "$torrc_backup" "$TOR_MAIN_CONFIG"
        fi
        if [ -n "$previous_config" ]; then
            mv "$previous_config" "$TOR_CONFIG_FILE"
        else
            rm -f "$TOR_CONFIG_FILE"
        fi
        pause
        return
    fi
    step "Включение и запуск Tor..."
    if ! restart_tor_service; then
        error "Не удалось запустить Tor. Проверьте: journalctl -u tor@default.service"
        warn "Выполняется восстановление предыдущей конфигурации Tor."
        if [ "$torrc_changed" -eq 1 ]; then
            mv "$torrc_backup" "$TOR_MAIN_CONFIG"
        fi
        if [ -n "$previous_config" ]; then
            mv "$previous_config" "$TOR_CONFIG_FILE"
        else
            rm -f "$TOR_CONFIG_FILE"
        fi
        restart_tor_service >/dev/null 2>&1 || true
        pause
        return
    fi
    rm -f "$previous_config"

    step "Ожидание подключения к сети Tor..."
    exit_ip="$(wait_for_tor)" || {
        error "Tor запущен, но выход в интернет через SOCKS5 не подтвердился за 60 секунд."
        pause
        return
    }

    if ! write_tor_outbound; then
        error "Tor работает, но не удалось создать Xray outbound."
        pause
        return
    fi

    success "Tor установлен и выводит трафик через IP $exit_ip."
    info "SOCKS5: 127.0.0.1:${TOR_SOCKS_PORT}"
    info "Xray outbound: $TOR_OUTBOUND_FILE"
    section "Готовый outbound для Xray"
    cat "$TOR_OUTBOUND_FILE"
    printf "\n"
    pause
}

send_tor_newnym() {
    local cookie_hex
    local auth_response
    local signal_response
    local control_fd

    [ -r "$TOR_COOKIE_FILE" ] || {
        error "Cookie управления Tor не найден: $TOR_COOKIE_FILE"
        return 1
    }
    cookie_hex="$(od -An -v -tx1 "$TOR_COOKIE_FILE" | tr -d '[:space:]')"
    [ -n "$cookie_hex" ] || {
        error "Не удалось прочитать cookie управления Tor."
        return 1
    }

    if ! exec {control_fd}<>"/dev/tcp/127.0.0.1/$TOR_CONTROL_PORT"; then
        error "ControlPort Tor недоступен на 127.0.0.1:${TOR_CONTROL_PORT}."
        return 1
    fi
    printf "AUTHENTICATE %s\r\n" "$cookie_hex" >&"$control_fd"
    if ! IFS= read -r -t 5 auth_response <&"$control_fd"; then
        exec {control_fd}>&-
        error "Tor не ответил на команду аутентификации."
        return 1
    fi
    auth_response="${auth_response%$'\r'}"
    if [[ "$auth_response" != 250* ]]; then
        exec {control_fd}>&-
        error "Tor отклонил аутентификацию ControlPort: $auth_response"
        return 1
    fi

    printf "SIGNAL NEWNYM\r\n" >&"$control_fd"
    if ! IFS= read -r -t 5 signal_response <&"$control_fd"; then
        exec {control_fd}>&-
        error "Tor не ответил на команду смены цепочки."
        return 1
    fi
    signal_response="${signal_response%$'\r'}"
    printf "QUIT\r\n" >&"$control_fd"
    exec {control_fd}>&-

    if [[ "$signal_response" != 250* ]]; then
        error "Tor отклонил команду NEWNYM: $signal_response"
        return 1
    fi
}

change_tor_ip() {
    header "Быстрая смена IP Tor"
    local old_ip
    local new_ip
    local attempt

    old_ip="$(tor_exit_ip)" || {
        error "Не удалось получить текущий IP через Tor. Убедитесь, что Tor установлен и запущен."
        pause
        return
    }
    info "Текущий IP Tor: $old_ip"

    step "Запрос новой цепочки Tor..."
    if ! send_tor_newnym; then
        pause
        return
    fi

    for ((attempt = 1; attempt <= 6; attempt++)); do
        sleep 3
        new_ip="$(tor_exit_ip)" || continue
        if [ -n "$new_ip" ] && [ "$new_ip" != "$old_ip" ]; then
            success "IP Tor изменён: $old_ip -> $new_ip"
            pause
            return
        fi
    done

    warn "Команда NEWNYM принята, но выходной IP остался прежним: ${new_ip:-$old_ip}."
    info "Tor мог повторно выбрать тот же exit-узел; попробуйте ещё раз через несколько секунд."
    pause
}

show_tor_outbound() {
    header "Xray outbound для Tor"

    if [ ! -f "$TOR_OUTBOUND_FILE" ]; then
        error "Outbound не найден. Сначала установите Tor через меню RemnaSuper."
        pause
        return
    fi

    info "Добавьте этот объект в массив outbounds конфигурации Xray:"
    printf "\n"
    cat "$TOR_OUTBOUND_FILE"
    printf "\n"
    pause
}

remove_tor_include_block() {
    local tmp_file

    [ -f "$TOR_MAIN_CONFIG" ] || return 0
    grep -Fq '# BEGIN REMNASUPER TOR' "$TOR_MAIN_CONFIG" || return 0

    tmp_file="$(mktemp)" || return 1
    if awk '
        /^# BEGIN REMNASUPER TOR$/ { skipping=1; next }
        /^# END REMNASUPER TOR$/ { skipping=0; next }
        !skipping { print }
    ' "$TOR_MAIN_CONFIG" > "$tmp_file"; then
        chmod --reference="$TOR_MAIN_CONFIG" "$tmp_file" 2>/dev/null || chmod 644 "$tmp_file"
        chown --reference="$TOR_MAIN_CONFIG" "$tmp_file" 2>/dev/null || true
        mv "$tmp_file" "$TOR_MAIN_CONFIG"
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

uninstall_tor() {
    header "Удаление Tor"
    local package
    local remove_tor_package=0
    local service_unit=""
    local -a packages_to_remove=()

    if [ "$TOR_DIR" != "/opt/remnasuper-tor" ] || [ "$TOR_CONFIG_FILE" != "/etc/tor/torrc.d/remnasuper.conf" ]; then
        error "Обнаружены небезопасные пути удаления Tor."
        pause
        return
    fi

    if [ ! -e "$TOR_DIR" ] && [ ! -f "$TOR_CONFIG_FILE" ]; then
        warn "Интеграция Tor от RemnaSuper не установлена."
        pause
        return
    fi

    if ! remove_tor_include_block; then
        error "Не удалось удалить include-блок RemnaSuper из $TOR_MAIN_CONFIG."
        pause
        return
    fi
    rm -f -- "$TOR_CONFIG_FILE" "$TOR_OUTBOUND_FILE"

    if [ -f "$TOR_PACKAGE_MARKER" ]; then
        while IFS= read -r package; do
            case "$package" in
                tor)
                    packages_to_remove+=("$package")
                    remove_tor_package=1
                    ;;
                tor-geoipdb) packages_to_remove+=("$package") ;;
                '') ;;
                *) warn "Пропущено неизвестное имя пакета из маркера: $package" ;;
            esac
        done < "$TOR_PACKAGE_MARKER"
    fi

    if [ "${#packages_to_remove[@]}" -gt 0 ]; then
        step "Остановка Tor и удаление пакетов, установленных RemnaSuper..."
        service_unit="$(tor_service_unit 2>/dev/null || true)"
        [ -n "$service_unit" ] && systemctl stop "$service_unit" >/dev/null 2>&1 || true
        if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}"; then
            error "Не удалось удалить пакеты Tor. Маркер установки сохранён для повторной попытки."
            pause
            return
        fi
        if [ "$remove_tor_package" -eq 0 ] && command -v tor >/dev/null 2>&1; then
            step "Перезапуск сохранённой установки Tor без настроек RemnaSuper..."
            if ! restart_tor_service; then
                warn "Не удалось перезапустить сохранённую установку Tor. Проверьте её конфигурацию вручную."
            fi
        fi
    elif command -v tor >/dev/null 2>&1; then
        step "Перезапуск существовавшей ранее установки Tor без настроек RemnaSuper..."
        if ! restart_tor_service; then
            warn "Не удалось перезапустить стороннюю установку Tor. Проверьте её конфигурацию вручную."
        fi
    fi

    rm -f -- "$TOR_PACKAGE_MARKER"
    if ! rmdir "$TOR_DIR" 2>/dev/null; then
        warn "Каталог $TOR_DIR содержит сторонние файлы и поэтому сохранён."
    fi

    success "Интеграция Tor и Xray outbound удалены."
    pause
}
