#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/remnasuper/traffic-shaper"
INTERFACE_FILE="$CONFIG_DIR/interface.conf"
BPF_OBJECT="$CONFIG_DIR/shaper.bpf.o"
CONTROLLER="$CONFIG_DIR/controller.py"
RULES_FILE="$CONFIG_DIR/rules.json"
WHITELIST_FILE="$CONFIG_DIR/whitelist.txt"
PIN_DIR="/sys/fs/bpf/remnasuper-traffic-shaper"
PIN_PROGS="$PIN_DIR/programs"
PIN_MAPS="$PIN_DIR/maps"
FILTER_PRIORITY="49152"
FILTER_HANDLE="0x5253"
ROOT_HANDLE="8000:"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '[x] Не найдена команда: %s\n' "$1" >&2
        return 1
    }
}

read_interface() {
    local interface

    [ -f "$INTERFACE_FILE" ] || {
        printf '[x] Не найден %s\n' "$INTERFACE_FILE" >&2
        return 1
    }
    interface="$(sed -n 's/^INTERFACE=//p' "$INTERFACE_FILE" | head -n 1)"
    if ! [[ "$interface" =~ ^[[:alnum:]_.:-]+$ ]]; then
        printf '[x] Некорректный сетевой интерфейс в %s\n' "$INTERFACE_FILE" >&2
        return 1
    fi
    ip link show dev "$interface" >/dev/null 2>&1 || {
        printf '[x] Сетевой интерфейс не существует: %s\n' "$interface" >&2
        return 1
    }
    printf '%s\n' "$interface"
}

remove_pins() {
    if [ "$PIN_DIR" != "/sys/fs/bpf/remnasuper-traffic-shaper" ]; then
        printf '[x] Отказ от очистки неожиданного BPF-пути: %s\n' "$PIN_DIR" >&2
        return 1
    fi
    rm -rf -- "$PIN_DIR"
}

stop_shaper() {
    local interface="${1:-}"

    if [ -z "$interface" ] && [ -f "$INTERFACE_FILE" ]; then
        interface="$(read_interface 2>/dev/null || true)"
    fi

    if [ -n "$interface" ] && ip link show dev "$interface" >/dev/null 2>&1; then
        tc filter del dev "$interface" egress pref "$FILTER_PRIORITY" 2>/dev/null || true
        tc filter del dev "$interface" ingress pref "$FILTER_PRIORITY" 2>/dev/null || true

        # Remove only the fq qdisc carrying RemnaSuper's unique handle. If an
        # administrator replaced it after startup, leave the new qdisc alone.
        if tc qdisc show dev "$interface" root 2>/dev/null | grep -q "qdisc fq ${ROOT_HANDLE}"; then
            tc qdisc del dev "$interface" root 2>/dev/null || true
        fi
    fi
    remove_pins
}

start_shaper() {
    local interface exit_code
    interface="$(read_interface)"

    for command in bpftool ip modprobe mount mountpoint python3 tc; do
        require_command "$command"
    done
    [ -s "$BPF_OBJECT" ] || {
        printf '[x] Не найден скомпилированный eBPF-объект: %s\n' "$BPF_OBJECT" >&2
        return 1
    }
    [ -x "$CONTROLLER" ] || {
        printf '[x] Не найден контроллер: %s\n' "$CONTROLLER" >&2
        return 1
    }

    mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
    modprobe cls_bpf
    modprobe sch_fq

    stop_shaper "$interface"
    mkdir -p "$PIN_PROGS" "$PIN_MAPS"

    cleanup_failed_start() {
        exit_code=$?
        if [ "$exit_code" -ne 0 ]; then
            printf '[x] Запуск шейпера прерван, выполняется безопасная очистка.\n' >&2
            stop_shaper "$interface" || true
        fi
        exit "$exit_code"
    }
    trap cleanup_failed_start EXIT

    # fq is required for EDT timestamps set by the download classifier.
    if ! tc qdisc replace dev "$interface" root handle "$ROOT_HANDLE" fq; then
        tc qdisc del dev "$interface" root 2>/dev/null || true
        tc qdisc add dev "$interface" root handle "$ROOT_HANDLE" fq
    fi
    tc qdisc add dev "$interface" clsact 2>/dev/null || true

    bpftool prog loadall "$BPF_OBJECT" "$PIN_PROGS" \
        type classifier pinmaps "$PIN_MAPS"

    [ -e "$PIN_PROGS/rs_download" ] || {
        printf '[x] В объекте не найдена программа rs_download.\n' >&2
        return 1
    }
    [ -e "$PIN_PROGS/rs_upload" ] || {
        printf '[x] В объекте не найдена программа rs_upload.\n' >&2
        return 1
    }

    tc filter replace dev "$interface" egress protocol all \
        pref "$FILTER_PRIORITY" handle "$FILTER_HANDLE" \
        bpf direct-action pinned "$PIN_PROGS/rs_download"
    tc filter replace dev "$interface" ingress protocol all \
        pref "$FILTER_PRIORITY" handle "$FILTER_HANDLE" \
        bpf direct-action pinned "$PIN_PROGS/rs_upload"

    python3 "$CONTROLLER" --pin-dir "$PIN_MAPS" \
        --rules-file "$RULES_FILE" restore
    python3 "$CONTROLLER" --pin-dir "$PIN_MAPS" \
        whitelist-sync --file "$WHITELIST_FILE"

    trap - EXIT
    printf '[ok] Шейпер запущен на интерфейсе %s.\n' "$interface"
}

case "${1:-}" in
    start) start_shaper ;;
    stop) stop_shaper ;;
    *)
        printf 'Использование: %s {start|stop}\n' "$0" >&2
        exit 2
        ;;
esac
