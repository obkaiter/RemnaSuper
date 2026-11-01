#!/usr/bin/env bash

run_network_diagnostics() {
    local agent_path result package command_name
    local -a missing_packages=()
    agent_path="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/network_diagnostics/agent.py"

    if [ ! -f "$agent_path" ]; then
        error "Файл агента диагностики не найден: $agent_path"
        pause
        return 1
    fi
    if [ ! -d /run/systemd/system ]; then
        error "Для аварийного восстановления нужен запущенный systemd; сессия не будет открывать порты."
        pause
        return 1
    fi

    while read -r command_name package; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done <<'PACKAGES'
python3 python3
iperf3 iperf3
ufw ufw
ip iproute2
ss iproute2
ping iputils-ping
tracepath iputils-tracepath
mtr mtr-tiny
sar sysstat
nstat iproute2
curl curl
PACKAGES

    if [ "${#missing_packages[@]}" -gt 0 ]; then
        if ! check_command apt-get; then
            error "Автоматическая установка поддерживается только через apt-get."
            pause
            return 1
        fi
        mapfile -t missing_packages < <(printf '%s\n' "${missing_packages[@]}" | sort -u)
        section "Недостающие пакеты"
        printf '  %s\n' "${missing_packages[@]}"
        warn "apt-get update и apt-get install создадут постоянные изменения в системе."
        if ! confirm "Установить перечисленные пакеты сейчас?"; then
            info "Установка отменена; диагностика не запущена."
            pause
            return 1
        fi
        if printf '%s\n' "${missing_packages[@]}" | grep -qx 'iperf3' &&
           command -v debconf-set-selections >/dev/null 2>&1; then
            printf '%s\n' 'iperf3 iperf3/start_daemon boolean false' | debconf-set-selections
        fi
        if ! DEBIAN_FRONTEND=noninteractive apt-get update ||
           ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"; then
            error "Не удалось установить все зависимости. Исправьте ошибку apt и повторите запуск."
            pause
            return 1
        fi
        for command_name in python3 iperf3 ufw ip ss ping tracepath mtr sar nstat curl; do
            if ! check_command "$command_name"; then
                pause
                return 1
            fi
        done
    fi

    python3 "$agent_path" run
    result=$?
    pause
    return "$result"
}
