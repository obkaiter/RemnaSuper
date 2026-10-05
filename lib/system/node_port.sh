#!/usr/bin/env bash

_node_port_read_compose_value() {
    awk '
        /^services:[[:space:]]*(#.*)?$/ { in_services=1; next }
        in_services && /^[^[:space:]#][^:]*:/ {
            in_services=0
            in_remnanode=0
            in_environment=0
        }
        in_services && /^  remnanode:[[:space:]]*$/ { in_remnanode=1; next }
        in_remnanode && /^  [A-Za-z0-9_.-]+:/ {
            in_remnanode=0
            in_environment=0
        }
        in_remnanode && /^    environment:[[:space:]]*$/ { in_environment=1; next }
        in_environment && /^    [A-Za-z0-9_.-]+:/ { in_environment=0 }
        in_environment && /^[[:space:]]*-[[:space:]]*NODE_PORT=[0-9]+([[:space:]]+#.*)?$/ {
            value=$0
            sub(/^[[:space:]]*-[[:space:]]*NODE_PORT=/, "", value)
            sub(/[[:space:]]*#.*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            print value
            count++
        }
        END { if (count != 1) exit 1 }
    ' "$COMPOSE_FILE"
}

_node_port_write_compose_value() {
    local new_port="$1"
    local destination="$2"

    awk -v new_port="$new_port" '
        /^services:[[:space:]]*(#.*)?$/ { in_services=1; next }
        in_services && /^[^[:space:]#][^:]*:/ {
            in_services=0
            in_remnanode=0
            in_environment=0
        }
        in_services && /^  remnanode:[[:space:]]*$/ { in_remnanode=1; next }
        in_remnanode && /^  [A-Za-z0-9_.-]+:/ {
            in_remnanode=0
            in_environment=0
        }
        in_remnanode && /^    environment:[[:space:]]*$/ { in_environment=1; next }
        in_environment && /^    [A-Za-z0-9_.-]+:/ { in_environment=0 }
        in_environment && /^[[:space:]]*-[[:space:]]*NODE_PORT=[0-9]+([[:space:]]+#.*)?$/ {
            sub(/NODE_PORT=[0-9]+/, "NODE_PORT=" new_port)
            count++
        }
        { print }
        END { if (count != 1) exit 1 }
    ' "$COMPOSE_FILE" > "$destination"
}

_node_port_ufw_rules() {
    local status="$1"
    local wanted_port="$2"

    awk -v wanted_port="$wanted_port" '
        /^[[:space:]]*\[[[:space:]]*[0-9]+\]/ {
            if (!match($0, /^\[[[:space:]]*[0-9]+\]/)) next
            rule_number=substr($0, RSTART, RLENGTH)
            gsub(/[^0-9]/, "", rule_number)
            rest=substr($0, RSTART + RLENGTH)
            sub(/^[[:space:]]+/, "", rest)
            field_count=split(rest, fields, /[[:space:]]+/)

            rule_port=fields[1]
            protocol=""
            if (rule_port ~ /\/(tcp|udp)$/) {
                protocol=rule_port
                sub(/^.*\//, "", protocol)
                sub(/\/(tcp|udp)$/, "", rule_port)
            }
            if (rule_port == "Anywhere") rule_port="0:65535"

            offset=(fields[2] == "(v6)") ? 1 : 0
            port_matches=(rule_port == wanted_port)
            if (rule_port ~ /^[0-9]+:[0-9]+$/) {
                split(rule_port, range, ":")
                if (wanted_port >= range[1] && wanted_port <= range[2]) port_matches=1
            }
            if (port_matches && fields[2 + offset] == "ALLOW" &&
                fields[3 + offset] == "IN") {
                source=fields[4 + offset]
                protocol_value=(protocol == "") ? "-" : protocol
                printf "%s\t%s\t%s\t%s\n", rule_number, source, protocol_value, rule_port
            }
        }
    ' <<< "$status"
}

_node_port_ufw_rule_ports() {
    local status="$1"

    awk '
        /^[[:space:]]*\[[[:space:]]*[0-9]+\]/ {
            if (!match($0, /^\[[[:space:]]*[0-9]+\]/)) next
            rest=substr($0, RSTART + RLENGTH)
            sub(/^[[:space:]]+/, "", rest)
            split(rest, fields, /[[:space:]]+/)
            rule_port=fields[1]
            sub(/\/(tcp|udp)$/, "", rule_port)
            if (rule_port == "Anywhere") rule_port="0:65535"
            offset=(fields[2] == "(v6)") ? 1 : 0
            action=fields[2 + offset]
            if ((action == "ALLOW" || action == "DENY" || action == "REJECT" || action == "LIMIT") &&
                fields[3 + offset] == "IN" &&
                rule_port ~ /^[0-9]+(:[0-9]+)?$/) print rule_port
        }
    ' <<< "$status"
}

_node_port_ss_listening_ports() {
    local ss_output="$1"

    awk '
        NF >= 5 {
            local_address=$5
            sub(/^.*:/, "", local_address)
            if (local_address ~ /^[0-9]+$/) print local_address
        }
    ' <<< "$ss_output"
}

_node_port_is_listening() {
    local port="$1"
    local ss_output="$2"

    _node_port_ss_listening_ports "$ss_output" | awk -v wanted="$port" '$0 == wanted { found=1 } END { exit !found }'
}

_node_port_ufw_port_is_configured() {
    local wanted_port="$1"
    local ufw_status="$2"
    local rule_port range_start range_end

    while IFS= read -r rule_port; do
        if [[ "$rule_port" =~ ^([0-9]+):([0-9]+)$ ]]; then
            range_start="${BASH_REMATCH[1]}"
            range_end="${BASH_REMATCH[2]}"
            if [ "$wanted_port" -ge "$range_start" ] && [ "$wanted_port" -le "$range_end" ]; then
                return 0
            fi
        elif [ "$rule_port" = "$wanted_port" ]; then
            return 0
        fi
    done < <(_node_port_ufw_rule_ports "$ufw_status")

    return 1
}

_node_port_choose_random() {
    local old_port="$1"
    local ss_output="$2"
    local ufw_status="$3"
    local services_output candidate port range_start range_end rule_port
    local -A listening_ports=() ufw_ports=() service_ports=()
    local -a available_ports=()

    while IFS= read -r port; do
        [ -n "$port" ] && listening_ports["$port"]=1
    done < <(_node_port_ss_listening_ports "$ss_output")

    while IFS= read -r port; do
        [ -n "$port" ] || continue
        if [[ "$port" =~ ^([0-9]+):([0-9]+)$ ]]; then
            range_start="${BASH_REMATCH[1]}"
            range_end="${BASH_REMATCH[2]}"
            for ((rule_port = range_start; rule_port <= range_end; rule_port++)); do
                ufw_ports["$rule_port"]=1
            done
        else
            ufw_ports["$port"]=1
        fi
    done < <(_node_port_ufw_rule_ports "$ufw_status")

    services_output="$(awk '!/^[[:space:]]*#/ && NF >= 2 { split($2, binding, "/"); if (binding[1] ~ /^[0-9]+$/) print binding[1] }' /etc/services)" || return 1
    while IFS= read -r port; do
        [ -n "$port" ] && service_ports["$port"]=1
    done <<< "$services_output"
    service_ports[51820]=1

    for ((candidate = 49152; candidate <= 65535; candidate++)); do
        [ "$candidate" = "$old_port" ] && continue
        [ -n "${listening_ports[$candidate]+x}" ] && continue
        [ -n "${ufw_ports[$candidate]+x}" ] && continue
        [ -n "${service_ports[$candidate]+x}" ] && continue
        available_ports+=("$candidate")
    done

    [ "${#available_ports[@]}" -gt 0 ] || return 1
    shuf -e "${available_ports[@]}" -n 1
}

_node_port_restore_ufw_rule() {
    local source_ip="$1"
    local port="$2"
    local protocol="$3"
    local -a command=(ufw allow from "$source_ip" to any port "$port")

    [ -n "$protocol" ] && command+=(proto "$protocol")
    "${command[@]}"
}

_node_port_delete_ufw_rule() {
    local source_ip="$1"
    local port="$2"
    local protocol="$3"
    local -a command=(ufw --force delete allow from "$source_ip" to any port "$port")

    [ -n "$protocol" ] && command+=(proto "$protocol")
    "${command[@]}"
}

_node_port_restore_compose() {
    local backup_file="$1"

    cp -p "$backup_file" "$COMPOSE_FILE"
}

change_node_port() {
    local raw_port requested_port old_port new_port
    local compose_services ufw_status old_rules old_rule_number source_ip old_protocol old_rule_port
    local -a rule_records=()
    local ss_output backup_file temp_file
    local rollback_status

    header "Смена порта взаимодействия с панелью"

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "RemnaNode не найдена: файл $COMPOSE_FILE отсутствует."
        pause
        return 1
    fi
    check_command docker || { pause; return 1; }
    check_command ufw || { pause; return 1; }
    check_command ss || { pause; return 1; }
    check_command shuf || { pause; return 1; }
    if [ ! -r /etc/services ]; then
        error "Не найден список системных портов /etc/services."
        pause
        return 1
    fi

    step "Проверка docker-compose.yml до запроса нового порта..."
    if ! (cd "$NODE_DIR" && docker compose config >/dev/null); then
        error "Исходная конфигурация Docker Compose не прошла проверку. Порт не запрашивался, изменений нет."
        pause
        return 1
    fi
    if ! compose_services="$(cd "$NODE_DIR" && docker compose config --services 2>/dev/null)"; then
        error "Не удалось проверить конфигурацию RemnaNode через Docker Compose."
        pause
        return 1
    fi
    if ! grep -Fxq remnanode <<< "$compose_services"; then
        error "В Docker Compose не найден сервис remnanode."
        pause
        return 1
    fi

    if ! raw_port="$(_node_port_read_compose_value)"; then
        error "В секции environment сервиса remnanode должна быть ровно одна запись NODE_PORT=<порт>."
        pause
        return 1
    fi
    if [[ ! "$raw_port" =~ ^[0-9]{1,5}$ ]]; then
        error "В docker-compose.yml указан некорректный NODE_PORT: $raw_port"
        pause
        return 1
    fi
    while [[ ${#raw_port} -gt 1 && ${raw_port:0:1} == 0 ]]; do
        raw_port="${raw_port:1}"
    done
    old_port=$((10#$raw_port))
    if [ "$old_port" -lt 1 ] || [ "$old_port" -gt 65535 ]; then
        error "В docker-compose.yml указан порт вне диапазона 1–65535: $old_port"
        pause
        return 1
    fi

    if ! ufw_status="$(LC_ALL=C ufw status numbered 2>&1)"; then
        error "Не удалось прочитать правила UFW: $ufw_status"
        pause
        return 1
    fi
    old_rules="$(_node_port_ufw_rules "$ufw_status" "$old_port")"
    if [ -z "$old_rules" ]; then
        error "В UFW не найдено разрешающее входящее правило для порта $old_port. Изменения не внесены."
        pause
        return 1
    fi
    mapfile -t rule_records <<< "$old_rules"
    if [ "${#rule_records[@]}" -ne 1 ]; then
        error "Для порта $old_port найдено несколько правил UFW. Изменения не внесены, чтобы не потерять ограничения доступа."
        pause
        return 1
    fi
    IFS=$'\t' read -r old_rule_number source_ip old_protocol old_rule_port <<< "${rule_records[0]}"
    [ "$old_protocol" = "-" ] && old_protocol=""
    if [ "$old_rule_port" != "$old_port" ]; then
        error "Правило UFW для порта $old_port входит в диапазон $old_rule_port. Измените его вручную, чтобы не затронуть другие порты."
        pause
        return 1
    fi
    if [[ ! "$source_ip" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; then
        error "Не удалось однозначно определить IP-адрес источника в правиле UFW для порта $old_port: $source_ip"
        pause
        return 1
    fi

    warn "Будет изменён порт взаимодействия с панелью. Стандартный порт — 2222; в текущей конфигурации RemnaNode указан порт $old_port."
    info "Разрешённый адрес панели в UFW: $source_ip"
    printf "Введите новый порт вручную или оставьте поле пустым для случайного свободного порта: "
    if ! IFS= read -r requested_port; then
        printf "\n"
        info "Ввод отменён."
        pause
        return 1
    fi

    if [ -z "$requested_port" ]; then
        if ! ss_output="$(ss -H -lntu 2>/dev/null)"; then
            error "Не удалось проверить занятые порты через ss."
            pause
            return 1
        fi
        if ! ufw_status="$(LC_ALL=C ufw status numbered 2>&1)"; then
            error "Не удалось повторно прочитать правила UFW: $ufw_status"
            pause
            return 1
        fi
        if ! new_port="$(_node_port_choose_random "$old_port" "$ss_output" "$ufw_status")"; then
            error "Не удалось подобрать свободный случайный порт из диапазона 49152–65535."
            pause
            return 1
        fi
        success "Выбран свободный порт: $new_port"
    else
        if [[ ! "$requested_port" =~ ^[0-9]{1,5}$ ]]; then
            error "Порт должен быть целым числом от 1 до 65535."
            pause
            return 1
        fi
        while [[ ${#requested_port} -gt 1 && ${requested_port:0:1} == 0 ]]; do
            requested_port="${requested_port:1}"
        done
        new_port=$((10#$requested_port))
        if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
            error "Порт должен быть в диапазоне 1–65535."
            pause
            return 1
        fi
        if ! ss_output="$(ss -H -lntu 2>/dev/null)"; then
            error "Не удалось проверить занятые порты через ss."
            pause
            return 1
        fi
        if ! ufw_status="$(LC_ALL=C ufw status numbered 2>&1)"; then
            error "Не удалось повторно прочитать правила UFW: $ufw_status"
            pause
            return 1
        fi
    fi

    if [ "$new_port" -eq "$old_port" ]; then
        error "Новый порт совпадает с текущим портом $old_port."
        pause
        return 1
    fi
    if _node_port_is_listening "$new_port" "$ss_output"; then
        error "Порт $new_port уже занят прослушивающим сервисом. Изменения не внесены."
        pause
        return 1
    fi

    old_rules="$(_node_port_ufw_rules "$ufw_status" "$old_port")"
    if [ -z "$old_rules" ]; then
        error "Правило UFW для текущего порта $old_port изменилось. Изменения не внесены."
        pause
        return 1
    fi
    mapfile -t rule_records <<< "$old_rules"
    if [ "${#rule_records[@]}" -ne 1 ]; then
        error "Для порта $old_port найдено несколько правил UFW. Изменения не внесены."
        pause
        return 1
    fi
    IFS=$'\t' read -r old_rule_number source_ip old_protocol old_rule_port <<< "${rule_records[0]}"
    [ "$old_protocol" = "-" ] && old_protocol=""
    if [ "$old_rule_port" != "$old_port" ]; then
        error "Правило UFW для порта $old_port теперь входит в диапазон $old_rule_port. Изменения не внесены."
        pause
        return 1
    fi
    if [[ ! "$source_ip" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; then
        error "В текущем правиле UFW не найден IP-адрес источника. Изменения не внесены."
        pause
        return 1
    fi
    if _node_port_ufw_port_is_configured "$new_port" "$ufw_status"; then
        error "Для порта $new_port уже настроено правило UFW. Выберите другой порт."
        pause
        return 1
    fi

    if ! backup_compose; then
        error "Не удалось создать резервную копию docker-compose.yml."
        pause
        return 1
    fi
    backup_file="$(mktemp "${COMPOSE_FILE}.rollback.XXXXXX")" || {
        error "Не удалось подготовить файл для отката docker-compose.yml."
        pause
        return 1
    }
    if ! cp -p "$COMPOSE_FILE" "$backup_file"; then
        rm -f "$backup_file"
        error "Не удалось сохранить исходную конфигурацию RemnaNode для отката."
        pause
        return 1
    fi
    temp_file="$(mktemp "${COMPOSE_FILE}.tmp.XXXXXX")" || {
        rm -f "$backup_file"
        error "Не удалось подготовить временный файл docker-compose.yml."
        pause
        return 1
    }
    if ! _node_port_write_compose_value "$new_port" "$temp_file" ||
        ! chmod --reference="$COMPOSE_FILE" "$temp_file" ||
        ! chown --reference="$COMPOSE_FILE" "$temp_file" ||
        ! mv -f "$temp_file" "$COMPOSE_FILE"; then
        rm -f "$temp_file" "$backup_file"
        error "Не удалось обновить NODE_PORT в docker-compose.yml."
        pause
        return 1
    fi

    if ! (cd "$NODE_DIR" && docker compose config >/dev/null); then
        if ! _node_port_restore_compose "$backup_file"; then
            error "Новая конфигурация Docker Compose не прошла проверку, и исходный файл не удалось восстановить."
            rm -f "$backup_file"
            pause
            return 1
        fi
        rm -f "$backup_file"
        error "Новая конфигурация Docker Compose не прошла проверку; исходный файл восстановлен."
        pause
        return 1
    fi

    step "Удаление старого правила UFW для порта $old_port..."
    if ! ufw --force delete "$old_rule_number"; then
        if ! _node_port_restore_compose "$backup_file"; then
            error "Не удалось удалить старое правило UFW или восстановить исходный docker-compose.yml."
            rm -f "$backup_file"
            pause
            return 1
        fi
        rm -f "$backup_file"
        error "Не удалось удалить старое правило UFW; конфигурация RemnaNode восстановлена."
        pause
        return 1
    fi

    step "Разрешение порта $new_port только для $source_ip..."
    local -a allow_command=(ufw allow from "$source_ip" to any port "$new_port")
    [ -n "$old_protocol" ] && allow_command+=(proto "$old_protocol")
    if ! "${allow_command[@]}"; then
        rollback_status=0
        if ! _node_port_restore_compose "$backup_file"; then
            rollback_status=1
            error "Не удалось восстановить исходный docker-compose.yml."
        fi
        if ! _node_port_restore_ufw_rule "$source_ip" "$old_port" "$old_protocol"; then
            rollback_status=1
            error "Не удалось восстановить старое правило UFW для порта $old_port."
        fi
        if [ "$rollback_status" -ne 0 ]; then
            error "Не удалось добавить новое правило UFW и полностью восстановить исходные настройки. Проверьте сервер вручную."
        else
            error "Не удалось добавить новое правило UFW; старое правило и конфигурация восстановлены."
        fi
        rm -f "$backup_file"
        pause
        return 1
    fi

    step "Перезапуск RemnaNode..."
    if ! restart_remnanode_compose; then
        rollback_status=0
        if _node_port_restore_compose "$backup_file"; then
            if ! _node_port_delete_ufw_rule "$source_ip" "$new_port" "$old_protocol"; then
                rollback_status=1
                error "Не удалось удалить новое правило UFW для порта $new_port."
            fi
            if ! _node_port_restore_ufw_rule "$source_ip" "$old_port" "$old_protocol"; then
                rollback_status=1
                error "Не удалось восстановить исходное правило UFW для порта $old_port."
            fi
            if ! restart_remnanode_compose; then
                rollback_status=1
                error "Не удалось повторно запустить RemnaNode с исходной конфигурацией."
            fi
        else
            rollback_status=1
            error "Не удалось восстановить исходный docker-compose.yml."
            if ! _node_port_restore_ufw_rule "$source_ip" "$old_port" "$old_protocol"; then
                error "Не удалось восстановить исходное правило UFW для порта $old_port."
            fi
            if ! _node_port_restore_ufw_rule "$source_ip" "$new_port" "$old_protocol"; then
                error "Не удалось подтвердить доступ через новое правило UFW для порта $new_port."
            fi
            if ! restart_remnanode_compose; then
                error "Не удалось повторно запустить RemnaNode с текущей конфигурацией."
            fi
        fi
        rm -f "$backup_file"
        if [ "$rollback_status" -eq 0 ]; then
            error "Перезапуск с новым портом завершился ошибкой; исходные настройки восстановлены."
        else
            error "Перезапуск завершился ошибкой, а полный откат не удался. Проверьте Compose, UFW и состояние RemnaNode."
        fi
        pause
        return 1
    fi

    rm -f "$backup_file"
    success "Порт взаимодействия с панелью изменён на $new_port."
    pause
}
