#!/usr/bin/env bash

check_root() {
    local command_name="${1:-rs}"

    if [ "$EUID" -ne 0 ]; then
        error "Запустите от root: sudo $command_name"
        exit 1
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker не установлен или недоступен в PATH."
        return 1
    fi
}

check_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Команда '$cmd' не найдена."
        return 1
    fi
}

backup_config_file() {
    local source_file="$1"
    local output_variable="$2"
    local backup_dir="${3:-$BACKUP_DIR}"
    local file_name timestamp backup_path

    if [ ! -f "$source_file" ]; then
        error "Файл конфигурации не найден: $source_file"
        return 1
    fi
    if [ -L "$backup_dir" ]; then
        error "Каталог резервных копий не должен быть символической ссылкой: $backup_dir"
        return 1
    fi
    if ! mkdir -p -- "$backup_dir" || ! chmod 700 -- "$backup_dir"; then
        error "Не удалось подготовить каталог резервных копий: $backup_dir"
        return 1
    fi

    file_name="${source_file##*/}"
    timestamp="$(date +%F_%H%M%S)" || {
        error "Не удалось получить время для имени резервной копии $source_file."
        return 1
    }
    backup_path="$(mktemp "$backup_dir/${file_name}.bak.${timestamp}.XXXXXX")" || {
        error "Не удалось создать резервную копию $source_file."
        return 1
    }
    if ! cp -p -- "$source_file" "$backup_path"; then
        rm -f -- "$backup_path"
        error "Не удалось создать резервную копию $source_file."
        return 1
    fi

    if [[ -n "$output_variable" ]]; then
        printf -v "$output_variable" '%s' "$backup_path"
    fi
    info "Резервная копия $source_file: $backup_path"
}

backup_compose() {
    if [ -f "$COMPOSE_FILE" ]; then
        backup_config_file "$COMPOSE_FILE" "${1:-}" || return 1
    fi
}

add_remnanode_volume() {
    local volume="$1"
    local tmp_file original

    if awk -v target="$volume" '
        /^services:[[:space:]]*$/ { in_services=1; next }
        in_services && /^[^[:space:]#][^:]*:/ { in_services=0; in_remnanode=0; in_volumes=0 }
        in_services && /^  remnanode:[[:space:]]*$/ {
            in_remnanode=1
            in_volumes=0
            next
        }
        in_remnanode && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            in_remnanode=0
            in_volumes=0
        }
        in_remnanode && /^    volumes:[[:space:]]*$/ {
            in_volumes=1
            next
        }
        in_volumes && /^    [A-Za-z0-9_.-]+:/ { in_volumes=0 }
        in_volumes && /^[[:space:]]*-[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == target) {
                found=1
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$COMPOSE_FILE"; then
        success "Volume уже присутствует: $volume"
        return 0
    fi

    if [[ -L "$COMPOSE_FILE" ]] || ! tmp_file="$(mktemp "${COMPOSE_FILE}.XXXXXXXX")"; then
        error "Не удалось подготовить временный Compose-файл."
        return 1
    fi
    if ! original="$(sha256sum -- "$COMPOSE_FILE")"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    awk -v volume_line="      - $volume" '
        /^services:[[:space:]]*$/ { in_services=1 }
        in_services && /^[^[:space:]#][^:]*:/ && !/^services:/ { in_services=0; in_remnanode=0 }
        in_services && /^  remnanode:[[:space:]]*$/ { in_remnanode=1 }
        in_remnanode && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ && !/^  remnanode:/ { in_remnanode=0 }
        in_remnanode && /^    volumes:[[:space:]]*$/ && !added {
            print
            print volume_line
            added=1
            next
        }
        { print }
        END {
            if (!added) {
                exit 42
            }
        }
    ' "$COMPOSE_FILE" > "$tmp_file" || {
        rm -f -- "$tmp_file"
        error "Не удалось найти секцию volumes у сервиса remnanode."
        return 1
    }

    if ! (cd -- "$NODE_DIR" && docker compose -f "$tmp_file" config --quiet >/dev/null 2>&1); then
        rm -f -- "$tmp_file"
        error "Compose-файл с новым volume не прошёл проверку."
        return 1
    fi
    if [[ "$original" != "$(sha256sum -- "$COMPOSE_FILE")" ]]; then
        rm -f -- "$tmp_file"
        error "Compose-файл изменился во время подготовки. Повторите действие."
        return 1
    fi
    if ! chown --reference="$COMPOSE_FILE" -- "$tmp_file" ||
        ! chmod --reference="$COMPOSE_FILE" -- "$tmp_file" ||
        ! mv -fT -- "$tmp_file" "$COMPOSE_FILE"; then
        rm -f -- "$tmp_file"
        error "Не удалось сохранить Compose-файл."
        return 1
    fi
    success "Volume добавлен: $volume"
    return 0
}

restart_remnanode_compose() {
    check_docker || return 1

    if [ ! -d "$NODE_DIR" ]; then
        error "Папка ноды не найдена: $NODE_DIR"
        return 1
    fi

    step "Перезапуск контейнеров remnanode..."
    if (cd "$NODE_DIR" && docker compose down >/dev/null 2>&1 && docker compose up -d >/dev/null 2>&1); then
        success "Контейнеры remnanode успешно перезапущены."
    else
        error "Ошибка при перезапуске контейнеров remnanode."
        return 1
    fi
}
