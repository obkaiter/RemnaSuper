#!/usr/bin/env bash

validate_remnasuper_directory() {
    local directory="$1" resolved mounts

    if [[ ! -e "$directory" && ! -L "$directory" ]]; then
        return 0
    fi
    if ! resolved="$(realpath -e -- "$directory")" ||
        [[ "$resolved" != "$directory" || ! -d "$directory" ]]; then
        error "Небезопасный путь удаления каталога: $directory."
        return 1
    fi
    mounts="$(findmnt -rn -o TARGET)" || return 1
    mounts=$'\n'"$mounts"$'\n'
    if [[ "$mounts" == *$'\n'"$directory"$'\n'* || "$mounts" == *$'\n'"$directory/"* ]]; then
        error "В каталоге $directory есть смонтированные данные. Сначала отключите их."
        return 1
    fi
}

remove_remnasuper_directory() {
    local directory="$1"

    validate_remnasuper_directory "$directory" && rm -rf --one-file-system -- "$directory"
}

remove_remnasuper_ssh_policy() (
    local candidate='' backup_file lock_fd

    [[ -e "$SSHD_KEY_ONLY_CONFIG" || -L "$SSHD_KEY_ONLY_CONFIG" ]] || return 0
    if [[ ! -f "$SSHD_KEY_ONLY_CONFIG" || -L "$SSHD_KEY_ONLY_CONFIG" ]] ||
        ! grep -Fxq '# RemnaSuper' "$SSHD_KEY_ONLY_CONFIG" ||
        [[ ! -f "$SSHD_CONFIG" || -L "$SSHD_CONFIG" ]]; then
        error "Не удалось безопасно определить конфигурацию SSH, созданную RemnaSuper."
        return 1
    fi
    check_command sshd || return 1
    if ! { exec {lock_fd}>/run/remnasuper-ssh.lock; } || ! flock -n "$lock_fd"; then
        error "Настройки SSH заняты другим процессом."
        return 1
    fi
    if ! candidate="$(mktemp "$SSHD_CONFIG.remnasuper.XXXXXX")"; then
        return 1
    fi
    trap 'rm -f -- "$candidate"' EXIT
    backup_config_file "$SSHD_CONFIG" backup_file && cp -p -- "$backup_file" "$candidate" || return 1
    if ! awk -v include="Include $SSHD_KEY_ONLY_CONFIG" '$0 != include' "$backup_file" > "$candidate" ||
        ! cmp -s -- "$backup_file" "$SSHD_CONFIG" || ! sshd -t -f "$candidate"; then
        error "Не удалось проверить конфигурацию SSH без настроек RemnaSuper."
        return 1
    fi
    if ! cmp -s -- "$candidate" "$backup_file"; then
        mv -fT -- "$candidate" "$SSHD_CONFIG" || return 1
        if systemctl is-active --quiet ssh.service && ! systemctl reload ssh.service; then
            if ! cp -p -- "$backup_file" "$candidate" ||
                ! mv -fT -- "$candidate" "$SSHD_CONFIG" ||
                ! systemctl reload ssh.service; then
                error "Не удалось восстановить настройки SSH. Резервная копия: $backup_file"
            fi
            return 1
        fi
    fi
    rm -f -- "$SSHD_KEY_ONLY_CONFIG"
)

remove_remnasuper_host_settings() {
    local fail2ban_backup

    if [[ -e "$IPV6_SYSCTL_CONFIG" || -L "$IPV6_SYSCTL_CONFIG" ]]; then
        if [[ -L "$IPV6_SYSCTL_CONFIG" || ! -f "$IPV6_SYSCTL_CONFIG" ]] ||
            ! _ipv6_sysctl_config_is_managed "$IPV6_SYSCTL_CONFIG"; then
            error "Не удалось подтвердить принадлежность $IPV6_SYSCTL_CONFIG."
            return 1
        fi
        rm -f -- "$IPV6_SYSCTL_CONFIG" || return 1
        info "Файл отключения IPv6 удалён. Сетевые настройки будут заново применены при загрузке VPS."
    fi
    if [[ -f "$ROTATE_CONF" && ! -L "$ROTATE_CONF" ]] &&
        { cmp -s "$ROTATE_CONF" <(render_logrotate_profile daily 7 true) ||
          cmp -s "$ROTATE_CONF" <(render_logrotate_profile daily 3 true) ||
          cmp -s "$ROTATE_CONF" <(render_logrotate_profile 'size 100M' 5 false); }; then
        rm -f -- "$ROTATE_CONF" || return 1
    fi
    if [[ -f "$FAIL2BAN_SSH_CONFIG" && ! -L "$FAIL2BAN_SSH_CONFIG" ]] &&
        cmp -s "$FAIL2BAN_SSH_CONFIG" <(render_fail2ban_ssh_config); then
        backup_config_file "$FAIL2BAN_SSH_CONFIG" fail2ban_backup &&
            rm -f -- "$FAIL2BAN_SSH_CONFIG" || return 1
        if systemctl is-active --quiet fail2ban && ! systemctl reload fail2ban; then
            if ! cp -p -- "$fail2ban_backup" "$FAIL2BAN_SSH_CONFIG" ||
                ! systemctl reload fail2ban; then
                error "Не удалось восстановить настройки fail2ban. Резервная копия: $fail2ban_backup"
            fi
            return 1
        fi
    fi
    remove_remnasuper_ssh_policy
}

strip_remnasuper_relay_config() {
    local mode="$1" source="$2"

    if [[ "$mode" == managed ]]; then
        relay_routing_section base < "$source"
    else
        cat -- "$source"
    fi | relay_stats_config strip - | relay_bandwidth_config strip -
}

remove_remnasuper_relay_haproxy() {
    local mode=external offline=1 load_state base_config
    local stop_haproxy=0
    local -a connections=()

    if [[ -f "$RELAY_HAPROXY_CONFIG" ]] &&
        grep -Eq '(^# RemnaSuper (HAProxy|TCP routing)$| # RemnaSuper (traffic|bandwidth)$)' "$RELAY_HAPROXY_CONFIG"; then
        read_relay_connections connections mode || return 1
        if [[ "$mode" == external ]] &&
            grep -Eq '^# RemnaSuper (HAProxy|TCP routing)$' "$RELAY_HAPROXY_CONFIG"; then
            error "Маршруты в $RELAY_HAPROXY_CONFIG были изменены вручную. Уберите ссылки на релей RemnaSuper и повторите удаление."
            return 1
        fi
        if [[ "$mode" == legacy ]]; then
            stop_haproxy=1
        elif [[ "$mode" == managed ]]; then
            base_config="$(relay_routing_section base < "$RELAY_HAPROXY_CONFIG")" || return 1
            if ! grep -Eq '^[[:space:]]*(frontend|listen|backend)[[:space:]]' <<< "$base_config"; then
                stop_haproxy=1
            fi
        fi
        if (( stop_haproxy )); then
            load_state="$(systemctl show --property=LoadState --value haproxy.service)" || return 1
            if [[ "$load_state" != not-found ]]; then
                systemctl disable --now haproxy.service || return 1
            fi
        fi
        if [[ "$mode" == legacy ]]; then
            rm -f -- "$RELAY_HAPROXY_CONFIG" || return 1
        else
            if systemctl is-active --quiet haproxy.service; then
                offline=0
            fi
            commit_relay_config "$offline" strip_remnasuper_relay_config "$mode" "$RELAY_HAPROXY_CONFIG" || return 1
        fi
    fi

    if relay_service_registered; then
        systemctl disable --now "$RELAY_SERVICE" &&
            rm -f -- "$RELAY_SERVICE_LINK" && systemctl daemon-reload || return 1
    elif [[ -f "$RELAY_SERVICE_LINK" ]] && grep -Fq "$RELAY_DIR/" "$RELAY_SERVICE_LINK"; then
        error "Служба $RELAY_SERVICE ссылается на RemnaSuper, но её unit изменён. Отключите службу и уберите ссылку на $RELAY_DIR."
        return 1
    fi
}

remove_remnasuper_relay_nginx() (
    local config marker index staging='' committed=0 reload_attempted=0
    local socket_path=''
    local -a configs=("$RELAY_NGINX_CONFIG" "$RELAY_ACME_NGINX_CONFIG")
    local -a markers=('# RemnaSuper nginx' '# RemnaSuper ACME')

    cleanup_nginx_removal() {
        local saved

        [[ -n "$staging" ]] || return 0
        for config in "${configs[@]}"; do
            saved="$staging/${config##*/}"
            [[ -f "$saved" ]] || continue
            if (( committed )); then
                rm -f -- "$saved" || error "Не удалось удалить $saved."
            else
                mv -fT -- "$saved" "$config" || error "Не удалось восстановить $config из $saved."
            fi
        done
        if (( reload_attempted && ! committed )); then
            systemctl reload nginx || error "Не удалось перечитать прежние настройки nginx."
        fi
        rmdir -- "$staging" || error "Не удалось удалить временный каталог $staging."
    }

    trap cleanup_nginx_removal EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for index in "${!configs[@]}"; do
        config="${configs[index]}"
        marker="${markers[index]}"
        if [[ ! -e "$config" && ! -L "$config" ]]; then
            continue
        fi
        if [[ ! -f "$config" || -L "$config" ]] || ! grep -Fxq -- "$marker" "$config"; then
            error "Не удалось подтвердить принадлежность $config."
            return 1
        fi
        if [[ "$config" == "$RELAY_NGINX_CONFIG" ]]; then
            socket_path="$(configured_relay_site_socket)" || socket_path=''
        fi
        if [[ -z "$staging" ]]; then
            staging="$(mktemp -d "${RELAY_NGINX_CONFIG%/*}/.remnasuper-uninstall.XXXXXX")" || return 1
        fi
        mv -T -- "$config" "$staging/${config##*/}" || return 1
    done
    if [[ -n "$staging" ]] && systemctl is-active --quiet nginx; then
        check_command nginx && nginx -t || return 1
        reload_attempted=1
        systemctl reload nginx || return 1
    fi
    committed=1
    if [[ "$socket_path" == /*"$RELAY_SITE_SOCKET" || "$socket_path" == "$RELAY_SITE_SOCKET" ]] &&
        [[ -S "$socket_path" && "$(realpath -e -- "$socket_path")" == "$socket_path" ]]; then
        rm -f -- "$socket_path" || return 1
    fi
)

remove_remnasuper_relay() {
    if [[ -e "$RELAY_ACME_CRON" || -L "$RELAY_ACME_CRON" ]]; then
        if [[ -L "$RELAY_ACME_CRON" ]] || ! cmp -s "$RELAY_ACME_CRON" <(render_relay_acme_cron); then
            error "Не удалось подтвердить принадлежность задания $RELAY_ACME_CRON."
            return 1
        fi
        rm -f -- "$RELAY_ACME_CRON" || return 1
    fi

    remove_remnasuper_relay_haproxy && remove_remnasuper_relay_nginx &&
        remove_remnasuper_directory "$RELAY_SITE_TLS_DIR" &&
        remove_remnasuper_directory "$RELAY_SITE_ROOT" &&
        remove_remnasuper_directory "$RELAY_ACME_WEBROOT"
}

remove_remnasuper_tunnels() (
    local instance

    if [[ -e "$TOR_DIR" || -L "$TOR_DIR" || -e "$TOR_CONFIG_FILE" || -L "$TOR_CONFIG_FILE" ]]; then
        validate_remnasuper_directory "$TOR_DIR" || return 1
        _uninstall_tor || return 1
    fi
    for instance in $(list_psiphon_instances); do
        set_psiphon_instance "$instance" || return 1
        if [[ -f "$PSIPHON_OUTBOUND_FILE" ]]; then
            _uninstall_psiphon || return 1
        fi
    done
    if [[ -f "$ZAPRET_OUTBOUND_FILE" ]]; then
        _uninstall_ss_zapret || return 1
    fi
    if [[ -f "$WARP_NATIVE_MARKER" ]]; then
        _uninstall_warp_native || return 1
    fi
)

remove_remnasuper_geofiles() {
    validate_remnasuper_directory "$GEOFILES_DIR" && uninstall_all_geofiles || return 1
    if [[ -d "$GEOFILES_DIR" ]]; then
        rmdir --ignore-fail-on-non-empty -- "$GEOFILES_DIR" || return 1
    fi
}

uninstall_remnasuper() (
    local link_target=''

    if [[ "$EUID" != 0 || "$INSTALL_DIR" != /opt/RemnaSuper ||
          "$REMNASUPER_APP_DIR" != "$INSTALL_DIR" || "$COMMAND_LINK" != /usr/local/bin/rs ||
          ! -d "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
        error "Удаление доступно из установленной в /opt/RemnaSuper копии программы, запущенной от root."
        return 1
    fi
    check_command systemctl && check_command realpath && check_command findmnt &&
        validate_remnasuper_directory "$INSTALL_DIR" && lock_relay || return 1

    if [[ -L "$COMMAND_LINK" ]]; then
        link_target="$(realpath -m -- "$COMMAND_LINK")" || return 1
    fi
    step "Остановка служб и удаление ресурсов RemnaSuper..."
    if ! configure_smtp_egress disable || ! rm -f -- "$SMTP_EGRESS_UNIT" || ! systemctl daemon-reload ||
        ! remove_remnasuper_relay || ! remove_remnasuper_tunnels ||
        ! remove_remnasuper_geofiles || ! remove_remnasuper_host_settings; then
        error "Очистка ресурсов прервалась. RemnaSuper сохранён для повторной попытки."
        return 1
    fi

    cd / || return 1
    if ! remove_remnasuper_directory "$INSTALL_DIR"; then
        error "Не удалось полностью удалить $INSTALL_DIR."
        return 1
    fi
    if [[ "$link_target" == "$INSTALL_DIR/RemnaSuper" ]] && [[ -L "$COMMAND_LINK" ]] &&
        [[ "$(realpath -m -- "$COMMAND_LINK")" == "$link_target" ]] && ! rm -f -- "$COMMAND_LINK"; then
        error "Файлы RemnaSuper удалены. Не удалось удалить ссылку $COMMAND_LINK."
        return 1
    fi
    success "RemnaSuper удалён."
)
