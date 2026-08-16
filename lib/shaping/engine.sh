#!/usr/bin/env bash

shaper_service_active() {
    command -v systemctl >/dev/null 2>&1 && \
        systemctl is-active --quiet "$SHAPER_SERVICE_NAME"
}

shaper_kernel_supported() {
    local current minimum="5.4"
    current="$(uname -r | cut -d- -f1)"
    [ "$(printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n 1)" = "$minimum" ]
}

shaper_current_interface() {
    [ -f "$SHAPER_INTERFACE_FILE" ] || return 1
    sed -n 's/^INTERFACE=//p' "$SHAPER_INTERFACE_FILE" | head -n 1
}

shaper_validate_interface() {
    local interface="$1"
    [[ "$interface" =~ ^[[:alnum:]_.:-]+$ ]] || return 1
    ip link show dev "$interface" >/dev/null 2>&1 || return 1
    case "$interface" in
        lo|docker*|br-*|veth*) return 1 ;;
    esac
}

shaper_detect_interface() {
    local interface
    interface="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
    if shaper_validate_interface "$interface"; then
        printf '%s\n' "$interface"
        return 0
    fi
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | while read -r interface; do
        if shaper_validate_interface "$interface"; then
            printf '%s\n' "$interface"
            return 0
        fi
    done
}

shaper_choose_interface() {
    local suggested interface
    suggested="$(shaper_detect_interface || true)"

    printf "\nДоступные физические/виртуальные интерфейсы:\n" >&2
    ip -br link show | grep -Ev '^(lo|docker|br-|veth)' >&2 || true
    printf "\n" >&2
    if [ -n "$suggested" ]; then
        read -rp "Интерфейс с клиентским трафиком [$suggested]: " interface
        interface="${interface:-$suggested}"
    else
        read -rp "Интерфейс с клиентским трафиком: " interface
    fi

    if ! shaper_validate_interface "$interface"; then
        error "Интерфейс '$interface' не существует или относится к служебным Docker-интерфейсам." >&2
        return 1
    fi
    printf '%s\n' "$interface"
}

shaper_install_dependencies() {
    local packages=(clang llvm libbpf-dev iproute2 python3 kmod util-linux)

    check_command apt-get || return 1
    step "Установка зависимостей eBPF-шейпера..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
        error "Не удалось обновить индекс пакетов."
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"; then
        error "Не удалось установить clang/libbpf/iproute2."
        return 1
    fi

    if ! command -v bpftool >/dev/null 2>&1; then
        step "Установка bpftool..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y bpftool 2>/dev/null || \
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                linux-tools-common "linux-tools-$(uname -r)" 2>/dev/null || true
    fi
    if ! command -v bpftool >/dev/null 2>&1; then
        error "bpftool не найден после установки пакетов. Для нестандартного ядра установите совместимый bpftool."
        return 1
    fi
}

shaper_compile_bpf() {
    local source_file="$SHAPER_CONFIG_DIR/shaper.bpf.c"
    local object_file="$SHAPER_CONFIG_DIR/shaper.bpf.o"
    local multiarch include_arg=""
    local -a compile_args=(-O2 -g -target bpf)

    if command -v dpkg-architecture >/dev/null 2>&1; then
        multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
        if [ -n "$multiarch" ] && [ -d "/usr/include/$multiarch/asm" ]; then
            include_arg="-I/usr/include/$multiarch"
        fi
    fi
    if [ -z "$include_arg" ] && [ -d "/usr/include/$(uname -m)-linux-gnu/asm" ]; then
        include_arg="-I/usr/include/$(uname -m)-linux-gnu"
    fi

    step "Компиляция eBPF-программы..."
    if [ -n "$include_arg" ]; then
        compile_args+=("$include_arg")
    fi
    compile_args+=(-c "$source_file" -o "$object_file")
    if ! clang "${compile_args[@]}"; then
        error "Компиляция eBPF-программы завершилась ошибкой."
        return 1
    fi
    chmod 0644 "$object_file"
}

shaper_install_assets() {
    install -d -m 0755 "$SHAPER_CONFIG_DIR"
    install -m 0644 "$REMNASUPER_APP_DIR/lib/shaping/shaper.bpf.c" \
        "$SHAPER_CONFIG_DIR/shaper.bpf.c"
    install -m 0755 "$REMNASUPER_APP_DIR/lib/shaping/controller.py" \
        "$SHAPER_CONTROLLER"
    install -m 0755 "$REMNASUPER_APP_DIR/lib/shaping/service.sh" \
        "$SHAPER_CONFIG_DIR/service.sh"
    "$SHAPER_CONTROLLER" --rules-file "$SHAPER_RULES_FILE" init >/dev/null
    if [ ! -f "$SHAPER_WHITELIST_FILE" ]; then
        install -m 0600 /dev/null "$SHAPER_WHITELIST_FILE"
    fi
}

shaper_write_interface() {
    local interface="$1" temporary
    temporary="$(mktemp)"
    printf 'INTERFACE=%s\n' "$interface" > "$temporary"
    chmod 0600 "$temporary"
    mv "$temporary" "$SHAPER_INTERFACE_FILE"
}

shaper_write_service() {
    local temporary
    temporary="$(mktemp)"
    cat > "$temporary" <<EOF
[Unit]
Description=RemnaSuper eBPF traffic shaper
Documentation=https://github.com/SP1K33/RemnaSuper
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
LimitMEMLOCK=infinity
TimeoutStartSec=45
ExecStart=/bin/bash $SHAPER_CONFIG_DIR/service.sh start
ExecStop=/bin/bash $SHAPER_CONFIG_DIR/service.sh stop

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$temporary"
    mv "$temporary" "$SHAPER_SERVICE_FILE"
    systemctl daemon-reload
}

shaper_prepare_engine() {
    local interface="$1"

    if ! shaper_kernel_supported; then
        error "Требуется ядро Linux 5.4 или новее. Текущее: $(uname -r)."
        return 1
    fi
    shaper_validate_interface "$interface" || {
        error "Некорректный интерфейс: $interface"
        return 1
    }
    shaper_install_dependencies || return 1
    shaper_install_assets || return 1
    shaper_compile_bpf || return 1

    if shaper_service_active; then
        systemctl stop "$SHAPER_SERVICE_NAME" || return 1
    fi
    shaper_write_interface "$interface" || return 1
    shaper_write_service || return 1

    step "Запуск $SHAPER_SERVICE_NAME..."
    if ! systemctl enable --now "$SHAPER_SERVICE_NAME"; then
        error "Шейпер не запустился. Последние сообщения сервиса:"
        journalctl -u "$SHAPER_SERVICE_NAME" --no-pager -n 30 || true
        return 1
    fi
    success "eBPF-шейпер запущен на интерфейсе $interface."
}

shaper_ensure_engine() {
    local interface
    interface="$(shaper_current_interface 2>/dev/null || true)"
    if ! shaper_validate_interface "$interface"; then
        interface="$(shaper_choose_interface)" || return 1
    fi

    if shaper_service_active && [ -x "$SHAPER_CONTROLLER" ]; then
        return 0
    fi
    shaper_prepare_engine "$interface"
}

shaper_sync_whitelist() {
    if ! shaper_service_active; then
        info "Whitelist сохранён и будет применён при следующем запуске шейпера."
        return 0
    fi
    "$SHAPER_CONTROLLER" --pin-dir "$SHAPER_PIN_DIR/maps" \
        whitelist-sync --file "$SHAPER_WHITELIST_FILE"
}

shaper_disable() {
    if [ ! -f "$SHAPER_SERVICE_FILE" ] && \
       ! systemctl list-unit-files "$SHAPER_SERVICE_NAME" --no-legend 2>/dev/null | grep -q .; then
        info "Сервис шейпера не установлен."
        return 0
    fi
    if systemctl disable --now "$SHAPER_SERVICE_NAME"; then
        success "Шейпер остановлен. Правила и whitelist сохранены."
    else
        error "Не удалось полностью остановить сервис шейпера."
        return 1
    fi
}

shaper_remove() {
    shaper_disable || return 1
    if [ "$SHAPER_CONFIG_DIR" != "/etc/remnasuper/traffic-shaper" ] || \
       [ "$SHAPER_PIN_DIR" != "/sys/fs/bpf/remnasuper-traffic-shaper" ]; then
        error "Отказ от удаления: неожиданные системные пути."
        return 1
    fi
    if [ -x "$SHAPER_CONFIG_DIR/service.sh" ]; then
        "$SHAPER_CONFIG_DIR/service.sh" stop || true
    fi
    rm -f -- "$SHAPER_SERVICE_FILE"
    rm -rf -- "$SHAPER_CONFIG_DIR" "$SHAPER_PIN_DIR"
    systemctl daemon-reload
    success "Шейпер и его правила полностью удалены."
}
