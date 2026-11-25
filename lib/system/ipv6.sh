#!/usr/bin/env bash

_ipv6_sysctl_config_is_managed() {
    local config_file="$1"

    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        BEGIN {
            required["net.ipv6.conf.all.disable_ipv6"] = 1
            required["net.ipv6.conf.default.disable_ipv6"] = 1
            required["net.ipv6.conf.lo.disable_ipv6"] = 1
        }
        {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            line = trim(line)
            if (line == "") {
                next
            }

            separator = index(line, "=")
            if (separator == 0) {
                invalid = 1
                next
            }
            key = trim(substr(line, 1, separator - 1))
            value = trim(substr(line, separator + 1))
            if (!(key in required) || value != "1") {
                invalid = 1
                next
            }
            required[key] = 2
        }
        END {
            for (key in required) {
                if (required[key] != 2) {
                    invalid = 1
                }
            }
            exit invalid
        }
    ' "$config_file"
}

_ipv6_restore_sysctl_settings() {
    local setting result=0

    for setting in "$@"; do
        if ! sysctl -w "$setting" >/dev/null; then
            warn "Не удалось восстановить параметр IPv6: $setting"
            result=1
        fi
    done

    return "$result"
}

disable_ipv6() {
    local config_file="$IPV6_SYSCTL_CONFIG"
    local temp_file="" sysctl_file interface setting_key setting_value
    local config_created=0
    local -a previous_settings=()

    header "Отключение IPv6"
    check_command sysctl || { pause; return 1; }
    check_command mktemp || { pause; return 1; }
    check_command awk || { pause; return 1; }

    if [ -L "$config_file" ]; then
        error "Файл настройки IPv6 является символической ссылкой: $config_file"
        pause
        return 1
    fi
    if [ -e "$config_file" ]; then
        if [ ! -f "$config_file" ] || ! _ipv6_sysctl_config_is_managed "$config_file"; then
            error "Файл $config_file уже существует и содержит другие настройки. Он не изменён. Проверьте его вручную."
            pause
            return 1
        fi
    elif [ ! -d "${config_file%/*}" ]; then
        error "Каталог sysctl не найден: ${config_file%/*}"
        pause
        return 1
    fi

    for sysctl_file in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [ -r "$sysctl_file" ] || continue
        interface="${sysctl_file%/disable_ipv6}"
        interface="${interface##*/}"
        setting_key="net.ipv6.conf.$interface.disable_ipv6"
        if ! setting_value="$(sysctl -n "$setting_key")"; then
            error "Не удалось прочитать текущую настройку IPv6: $setting_key"
            pause
            return 1
        fi
        previous_settings+=("$setting_key=$setting_value")
    done
    if [ "${#previous_settings[@]}" -eq 0 ]; then
        error "Настройки IPv6 через sysctl недоступны в этой системе."
        pause
        return 1
    fi

    if [ ! -e "$config_file" ]; then
        if ! temp_file="$(mktemp "${config_file}.XXXXXX")"; then
            error "Не удалось создать временный файл настройки IPv6."
            pause
            return 1
        fi
        if ! cat > "$temp_file" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        then
            rm -f -- "$temp_file" || warn "Не удалось удалить временный файл $temp_file."
            error "Не удалось подготовить настройки IPv6."
            pause
            return 1
        fi
        if ! chmod 0644 -- "$temp_file" || ! ln -- "$temp_file" "$config_file"; then
            rm -f -- "$temp_file" || warn "Не удалось удалить временный файл $temp_file."
            error "Не удалось безопасно создать $config_file. Возможно, файл уже появился."
            pause
            return 1
        fi
        config_created=1
    fi

    step "Применение настроек IPv6..."
    if ! sysctl -p "$config_file"; then
        error "Не удалось применить настройки IPv6. Восстановление прежних значений..."
        if [ "$config_created" -eq 1 ] && [ -e "$temp_file" ] && [ "$config_file" -ef "$temp_file" ]; then
            rm -f -- "$config_file" || warn "Не удалось удалить созданный файл $config_file."
        fi
        _ipv6_restore_sysctl_settings "${previous_settings[@]}" || warn "Восстановление некоторых параметров IPv6 завершилось с ошибкой."
        if [ -n "$temp_file" ]; then
            rm -f -- "$temp_file" || warn "Не удалось удалить временный файл $temp_file."
        fi
        pause
        return 1
    fi

    if [ -n "$temp_file" ]; then
        rm -f -- "$temp_file" || warn "Не удалось удалить временную ссылку $temp_file."
    fi
    success "IPv6 отключён на существующих и новых сетевых интерфейсах. Настройка сохранена для последующих загрузок."
    pause
}

_remove_ufw_ipv6_rules() (
    local rules_file="$UFW_IPV6_RULES_FILE"
    local command_name work_dir prepared_file backup_file ufw_status result=0 apply_live=0

    for command_name in ufw awk cmp cp mktemp mv rm rmdir; do
        check_command "$command_name" || return 1
    done

    if [[ ! -f "$rules_file" || -L "$rules_file" ]]; then
        error "Обычный файл правил UFW не найден: $rules_file"
        return 1
    fi

    work_dir="$(mktemp -d -- "${rules_file%/*}/.remnasuper-ufw-ipv6.XXXXXX")" || {
        error "Не удалось создать временный каталог для правил UFW."
        return 1
    }
    trap 'rm -f -- "$work_dir/original" "$work_dir/prepared"; rmdir -- "$work_dir"' EXIT
    prepared_file="$work_dir/prepared"

    if ! cp -p -- "$rules_file" "$work_dir/original" ||
        ! cp -p -- "$work_dir/original" "$prepared_file"; then
        error "Не удалось подготовить временную копию правил UFW."
        return 1
    fi

    LC_ALL=C awk '
        /^### RULES ###$/ { sections++; in_rules=1; print; next }
        in_rules && /^(### END RULES ###|COMMIT)$/ { in_rules=0; closed++; print; next }
        in_rules && /^### tuple ### / { removed++; next }
        in_rules && /^-A ufw6-user-(logging-)?(input|output|forward) / { removed++; next }
        in_rules && !/^[[:space:]]*(#|$)/ { invalid=1 }
        { print }
        END {
            if (invalid || sections != 1 || closed != 1) exit 1
            if (!removed) exit 3
        }
    ' "$work_dir/original" > "$prepared_file" || result=$?

    case "$result" in
        0) ;;
        3) info "В UFW нет добавленных правил IPv6."; return 0 ;;
        *) error "Не удалось безопасно обработать файл правил UFW: $rules_file"; return 1 ;;
    esac

    if ! ufw_status="$(LC_ALL=C ufw --dry-run status)"; then
        error "Не удалось проверить поддержку IPv6 в UFW."
        return 1
    fi
    if [[ "$ufw_status" == *"> Checking ip6tables"* ]]; then
        if ! ufw_status="$(LC_ALL=C ufw status)"; then
            error "Не удалось проверить состояние UFW."
            return 1
        fi
        if [[ "$ufw_status" == "Status: active"* ]]; then
            apply_live=1
            check_command ip6tables-restore || return 1
            if ! ip6tables-restore --wait 5 --noflush --test --table filter < "$prepared_file"; then
                error "Подготовленные правила IPv6 не прошли проверку."
                return 1
            fi
        fi
    fi

    backup_config_file "$rules_file" backup_file || return 1
    if ! cmp -s -- "$work_dir/original" "$rules_file" || [[ -L "$rules_file" ]]; then
        error "Файл правил UFW изменился во время подготовки. Запустите действие повторно."
        return 1
    fi
    if ! mv -fT -- "$prepared_file" "$rules_file"; then
        error "Не удалось сохранить правила UFW."
        return 1
    fi

    if (( apply_live )) && ! ip6tables-restore --wait 5 --noflush --table filter < "$rules_file"; then
        error "Не удалось применить правила IPv6."
        if ! mv -fT -- "$work_dir/original" "$rules_file"; then
            error "Не удалось восстановить файл правил UFW. Резервная копия: $backup_file"
        fi
        return 1
    fi

    success "Все добавленные правила IPv6 удалены из UFW."
)

remove_ufw_ipv6_rules() {
    local result=0

    header "Удаление правил IPv6 из UFW"
    _remove_ufw_ipv6_rules || result=$?
    pause
    return "$result"
}
