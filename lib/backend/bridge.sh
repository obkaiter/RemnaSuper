#!/usr/bin/env bash
set -o pipefail

TUI_JOB="$1"
TUI_OUTCOME="$2"
action_module="$3"
action_target="$4"
shift 4
APP_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
TUI_PROTOCOL="$APP_DIR/lib/backend/tui_protocol.py"

source "$APP_DIR/lib/config.sh"
source "$APP_DIR/lib/common.sh"

RED= GREEN= YELLOW= BLUE= CYAN= WHITE= DIM= NC= BOLD=

tui_event() {
    /usr/bin/python3 "$TUI_PROTOCOL" "$TUI_JOB" event "$1" "$2"
}

info() { tui_event log "$1"; }
step() { tui_event step "$1"; }
success() { tui_event log "$1"; }
warn() { tui_event warning "$1"; }
error() { printf E >&"$TUI_OUTCOME"; tui_event error "$1"; }
header() { tui_event step "$1"; }
section() { tui_event step "$1"; }
divider() { :; }
pause() { return "$?"; }

request_input() {
    local destination="$1" prompt="$2" fallback="${3:-}" reply
    reply="$(/usr/bin/python3 "$TUI_PROTOCOL" "$TUI_JOB" ask text "$prompt" "$fallback")" || return "$?"
    printf -v "$destination" '%s' "$reply"
}

confirm() {
    /usr/bin/python3 "$TUI_PROTOCOL" "$TUI_JOB" ask confirm "$1" >/dev/null
}

tui_choose() {
    local destination="$1" prompt="$2" fallback="$3" selection
    shift 3
    selection="$(/usr/bin/python3 "$TUI_PROTOCOL" "$TUI_JOB" ask choice "$prompt" "$fallback" "$@")" || return "$?"
    printf -v "$destination" '%s' "$selection"
}

tui_edit() {
    local destination="$1" prompt="$2" contents="$3" reply
    if (( ${#contents} > 3500 )); then
        error "Файл слишком велик для встроенного редактора."
        return 1
    fi
    reply="$(/usr/bin/python3 "$TUI_PROTOCOL" "$TUI_JOB" ask editor "$prompt" "$contents")" || return "$?"
    printf -v "$destination" '%s' "$reply"
}

case "$action_module" in
    geofiles) source "$APP_DIR/lib/geofiles.sh" ;;
    logs)
        source "$APP_DIR/lib/logs.sh"
        source "$APP_DIR/lib/backend/logs.sh"
        ;;
    system) source "$APP_DIR/lib/system.sh" ;;
    adapter) source "$APP_DIR/lib/system.sh"; source "$APP_DIR/lib/backend/adapters.sh" ;;
    *) error "Неизвестная группа backend."; exit 1 ;;
esac

export REMNASUPER_TUI_JOB="$TUI_JOB"

edit_zapret_strategy_file() {
    local path="$1" current new_value
    current="$(cat -- "$path")" || return 1
    tui_edit new_value "Параметры NFQWS2_OPT без префикса и внешних кавычек" "$current" || return "$?"
    printf '%s\n' "$new_value" > "$path"
}

"$action_target" "$@"
