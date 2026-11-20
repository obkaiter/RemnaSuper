#!/usr/bin/env bash

valid_relay_bandwidth() {
    local mbps="$1"

    [[ "$mbps" =~ ^[1-9][0-9]{0,4}$ ]] && (( mbps <= RELAY_BANDWIDTH_MAX_MBPS ))
}

relay_bandwidth_config() {
    local action="$1" config="$2" mbps="${3:-0}" status=0

    check_command awk >&2 || return 1
    LC_ALL=C awk -v action="$action" -v mbps="$mbps" -v max_mbps="$RELAY_BANDWIDTH_MAX_MBPS" '
        function make_rules(rate, rules) {
            rules[1] = "    filter bwlim-out " down " limit " rate " key src,ipmask(32,128) table " tables "/download min-size 2896"
            rules[2] = "    filter bwlim-in " up " limit " rate " key src,ipmask(32,128) table " tables "/upload min-size 2896"
            rules[3] = "    tcp-request content set-bandwidth-limit " down
            rules[4] = "    tcp-request content set-bandwidth-limit " up
            rules[5] = "peers " tables
            rules[6] = "    disabled"
            rules[7] = "    table download type ipv6 size 100k expire 1h store bytes_out_rate(1s)"
            rules[8] = "    table upload type ipv6 size 100k expire 1h store bytes_in_rate(1s)"
        }
        BEGIN {
            bytes_per_mbps = 125000
            down = "remnasuper_download"
            up = "remnasuper_upload"
            tables = "remnasuper_bandwidth"
        }
        {
            original[FNR] = $0
            sub(/\r$/, "")
            owned = sub(/ # RemnaSuper bandwidth$/, "")
            if ($1 ~ /^(global|defaults|frontend|backend|listen|peers|resolvers|userlist|cache|mailers|program|ring|log-forward|log-profile|traces|acme|crt-store|http-errors|fcgi-app)$/) {
                entry = ($1 == "frontend" && $2 == "bitwire_entry")
                owned_tables = (owned && $1 == "peers" && $2 == tables)
                if (entry) {
                    entry_count++
                    entry_line = FNR
                }
                if (!owned && $1 == "peers" && $2 == tables) conflict = 1
            }
            if (owned) {
                installed[++count] = $0
                managed[FNR] = 1
                if (count == 1) bytes = $5
                if (count <= 4 ? !entry : !owned_tables) invalid = 1
            } else if (owned_tables && NF && $1 !~ /^#/) {
                invalid = 1
            } else if (entry && $1 == "filter" && $2 ~ /^bwlim-(in|out)$/ && ($3 == down || $3 == up)) {
                conflict = 1
            }
        }
        END {
            if (count) {
                if (invalid || count != 8 || bytes !~ /^[1-9][0-9]*$/ ||
                    bytes > max_mbps * bytes_per_mbps || bytes % bytes_per_mbps != 0) exit 22
                make_rules(bytes, expected)
                for (i = 1; i <= count; i++)
                    if (installed[i] != expected[i]) exit 22
            }
            if (action == "status") {
                if (count) printf "%d\n", bytes / bytes_per_mbps
                exit
            }
            if (action == "set") {
                if (entry_count != 1) exit 21
                if (conflict) exit 23
                make_rules(sprintf("%.0f", mbps * bytes_per_mbps), rules)
            }
            for (i = 1; i <= FNR; i++) {
                if (!managed[i]) print original[i]
                if (action == "set" && i == entry_line)
                    for (j = 1; j <= 4; j++) print rules[j] " # RemnaSuper bandwidth"
            }
            if (action == "set")
                for (j = 5; j <= 8; j++) print rules[j] " # RemnaSuper bandwidth"
        }
    ' "$config" || status=$?

    case "$status" in
        21) error "Для установки лимита нужен один frontend bitwire_entry." >&2 ;;
        22) error "Не удалось прочитать правила лимита скорости RemnaSuper в конфигурации HAProxy." >&2 ;;
        23) error "Имена фильтров или таблиц лимита скорости уже заняты в конфигурации HAProxy." >&2 ;;
    esac
    return "$status"
}

read_relay_bandwidth() {
    [[ -e "$RELAY_HAPROXY_CONFIG" || -L "$RELAY_HAPROXY_CONFIG" ]] || return 0
    if [[ ! -f "$RELAY_HAPROXY_CONFIG" || ! -r "$RELAY_HAPROXY_CONFIG" ]]; then
        error "Не удалось прочитать конфигурацию HAProxy: $RELAY_HAPROXY_CONFIG." >&2
        return 1
    fi
    relay_bandwidth_config status "$RELAY_HAPROXY_CONFIG"
}

change_relay_bandwidth() (
    local action="$1" mbps="${2:-}" current version

    lock_relay && check_command systemctl || return 1
    current="$(read_relay_bandwidth)" || return 1
    case "$action" in
        set)
            valid_relay_bandwidth "$mbps" || return 1
            if [[ "$current" == "$mbps" ]]; then
                info "Лимит скорости уже установлен на $mbps Мбит/с."
                return 0
            fi
            if [[ ! -f "$RELAY_HAPROXY_CONFIG" ]]; then
                error "Конфигурация HAProxy отсутствует: $RELAY_HAPROXY_CONFIG."
                return 1
            fi
            version="$(run_relay_haproxy -v)" || return 1
            if [[ ! "$version" =~ ^HAProxy\ version\ ([0-9]+)\.([0-9]+) ]] ||
                (( BASH_REMATCH[1] < 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] < 7) )); then
                error "Для установки лимита скорости требуется HAProxy 2.7 или новее."
                return 1
            fi
            commit_relay_config 0 relay_bandwidth_config set "$RELAY_HAPROXY_CONFIG" "$mbps" || return 1
            success "Установлен лимит $mbps Мбит/с на IP-адрес в каждом направлении."
            ;;
        remove)
            if [[ -z "$current" ]]; then
                info "Лимит скорости RemnaSuper не настроен."
                return 0
            fi
            commit_relay_config 0 relay_bandwidth_config strip "$RELAY_HAPROXY_CONFIG" || return 1
            success "Лимит скорости RemnaSuper удалён."
            ;;
        *) return 1 ;;
    esac
)
