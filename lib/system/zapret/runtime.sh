#!/usr/bin/env bash

ensure_ss_zapret_running() {
    local health_status=""
    local attempt

    check_docker || return 1

    if [ ! -f "$ZAPRET_DIR/docker-compose.yml" ]; then
        error "ss-zapret не установлен. Сначала выполните пункт 'Установить ss-zapret'."
        return 1
    fi

    if ! (cd "$ZAPRET_DIR" && docker compose up -d); then
        error "Не удалось запустить ss-zapret."
        return 1
    fi

    for ((attempt = 1; attempt <= 30; attempt++)); do
        health_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' zapret-proxy 2>/dev/null || true)"
        case "$health_status" in
            healthy|running) return 0 ;;
            unhealthy|exited|dead) break ;;
        esac
        sleep 1
    done

    error "Контейнер zapret-proxy не готов. Статус: ${health_status:-неизвестен}."
    return 1
}

