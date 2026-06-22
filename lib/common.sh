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

backup_compose() {
    if [ -f "$COMPOSE_FILE" ]; then
        local backup="${COMPOSE_FILE}.bak.$(date +%F_%H%M%S)"
        cp "$COMPOSE_FILE" "$backup"
        info "Бэкап docker-compose.yml: $backup"
    fi
}

add_remnanode_volume() {
    local volume="$1"
    local tmp_file

    if awk -v target="$volume" '
        /^services:[[:space:]]*$/ { in_services=1; next }
        in_services && /^[^[:space:]#][^:]*:/ { in_services=0 }
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

    tmp_file="$(mktemp)"
    awk -v volume_line="      - $volume" '
        /^services:[[:space:]]*$/ { in_services=1 }
        in_services && /^[^[:space:]#][^:]*:/ && !/^services:/ { in_services=0 }
        in_services && /^  remnanode:[[:space:]]*$/ { in_remnanode=1 }
        in_remnanode && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ && !/^  remnanode:/ { in_remnanode=0 }
        in_remnanode && /^[[:space:]]*volumes:[[:space:]]*$/ && !added {
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
    ' "$COMPOSE_FILE" > "$tmp_file"

    if [ $? -eq 0 ]; then
        mv "$tmp_file" "$COMPOSE_FILE"
        success "Volume добавлен: $volume"
        return 0
    fi

    rm -f "$tmp_file"
    error "Не удалось найти секцию volumes у сервиса remnanode."
    return 1
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
