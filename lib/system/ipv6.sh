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
