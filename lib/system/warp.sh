#!/usr/bin/env bash

run_warp_native_script() {
    local script_name="$1"
    local script_url="$2"
    local first_marker="$3"
    local second_marker="$4"
    local temp_dir
    local script_path
    local exit_code

    check_command curl || { pause; return 1; }
    check_command bash || { pause; return 1; }
    check_command mktemp || { pause; return 1; }

    temp_dir="$(mktemp -d)" || {
        error "Не удалось создать временный каталог для скрипта WARP."
        pause
        return 1
    }
    script_path="$temp_dir/$script_name.sh"

    step "Загрузка скрипта $script_name из distillium/warp-native..."
    if ! curl -fsSL --connect-timeout 10 --max-time 120 \
        -o "$script_path" "$script_url"; then
        error "Не удалось скачать скрипт $script_name для WARP."
        rm -f -- "$script_path"
        rmdir -- "$temp_dir" 2>/dev/null || true
        pause
        return 1
    fi

    if ! head -n 1 "$script_path" | grep -qx '#!/bin/bash' ||
        ! grep -Fq -- "$first_marker" "$script_path" ||
        ! grep -Fq -- "$second_marker" "$script_path" ||
        ! bash -n "$script_path"; then
        error "Загруженный файл не прошёл проверку скрипта $script_name WARP."
        rm -f -- "$script_path"
        rmdir -- "$temp_dir" 2>/dev/null || true
        pause
        return 1
    fi

    step "Запуск скрипта $script_name WARP..."
    bash "$script_path"
    exit_code=$?

    rm -f -- "$script_path"
    rmdir -- "$temp_dir" 2>/dev/null || true

    if [ "$exit_code" -ne 0 ]; then
        error "Скрипт $script_name WARP завершился с ошибкой. Код: $exit_code"
        pause
        return "$exit_code"
    fi

    return 0
}

install_warp_native() {
    run_warp_native_script "install" "$WARP_NATIVE_INSTALLER_URL" \
        'WGCF_DIR="/opt/warp-native/wgcf"' 'function rollback_install'
}

uninstall_warp_native() {
    run_warp_native_script "uninstall" "$WARP_NATIVE_UNINSTALLER_URL" \
        'systemctl disable --now wg-quick@warp' 'rm -rf /opt/warp-native'
}

show_warp_status() {
    header "Состояние WARP"
    check_command systemctl || { pause; return 1; }

    if systemctl is-active --quiet "$WARP_NATIVE_SERVICE"; then
        success "Интерфейс warp запущен."
    else
        warn "Интерфейс warp остановлен или не установлен."
    fi

    if systemctl is-enabled --quiet "$WARP_NATIVE_SERVICE"; then
        info "Автозапуск $WARP_NATIVE_SERVICE включён."
    else
        info "Автозапуск $WARP_NATIVE_SERVICE выключен или не настроен."
    fi

    if command -v wg >/dev/null 2>&1; then
        if ! wg show "$WARP_NATIVE_INTERFACE"; then
            info "Данные WireGuard для интерфейса warp недоступны."
        fi
    else
        info "Команда wg не найдена."
    fi

    pause
}

show_warp_interface_info() {
    header "Сведения об интерфейсе WARP"
    check_command wg || { pause; return 1; }
    check_command ip || { pause; return 1; }

    if ! wg show "$WARP_NATIVE_INTERFACE"; then
        warn "Интерфейс warp не найден или не запущен."
    fi
    if ! ip -brief address show dev "$WARP_NATIVE_INTERFACE"; then
        info "Сетевой интерфейс warp не найден."
    fi

    pause
}

warp_service_action() {
    local action="$1"
    local description="$2"

    check_command systemctl || { pause; return 1; }
    if ! systemctl "$action" "$WARP_NATIVE_SERVICE"; then
        error "Не удалось выполнить команду systemctl $action для $WARP_NATIVE_SERVICE."
        pause
        return 1
    fi

    success "$description"
    pause
}
