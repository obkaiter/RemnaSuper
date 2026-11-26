#!/usr/bin/env bash

run_iperf3_ru() {
    local status=0

    header "iperf3 до российских серверов"
    download_and_run_iperf3_ru || status=$?
    pause
    return "$status"
}

download_and_run_iperf3_ru() (
    local executable script missing=0

    for executable in bash curl mktemp sha256sum timeout; do
        check_command "$executable" || return 1
    done
    for executable in iperf3 jq ping awk; do
        check_command "$executable" || missing=1
    done
    if [ "$missing" -ne 0 ]; then
        info "Пакеты для замера в Debian и Ubuntu: iperf3, jq, iputils-ping и awk (например, mawk)."
        return 1
    fi

    if ! script="$(mktemp)"; then
        error "Не удалось создать временный файл для speedtest.sh."
        return 1
    fi
    trap 'rm -f -- "$script"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    step "Скачивание speedtest.sh с GitHub..."
    if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "$script" "$IPERF3_RU_URL"; then
        error "Не удалось скачать speedtest.sh."
        return 1
    fi
    if ! printf '%s  %s\n' "$IPERF3_RU_SHA256" "$script" | sha256sum -c --status; then
        error "Контрольная сумма speedtest.sh не совпала."
        return 1
    fi

    step "Замер скорости до публичных российских серверов..."
    if ! LC_ALL=C bash "$script"; then
        error "speedtest.sh завершился с ошибкой."
        return 1
    fi
)
