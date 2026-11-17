#!/usr/bin/env bash

relay_traffic_command() {
    if [[ ! -f "$RELAY_DIR/collector/collector.py" || ! -f "$RELAY_DIR/config/config.json" ]]; then
        error "Сборщик ещё не настроен. Выберите «Установить HAProxy» в меню обслуживания." >&2
        return 1
    fi
    /usr/bin/python3 -B "$RELAY_DIR/collector/collector.py" "$@"
}

check_relay_haproxy_config() {
    check_command haproxy && (cd / && haproxy -c -f "$RELAY_HAPROXY_CONFIG")
}

prepare_relay_socket_directory() {
    local socket_path="$1" user group

    user="$(systemctl show --property=User --value haproxy.service)" || return 1
    if [[ -z "$user" || "$user" == root || "$user" == 0 ]]; then
        (umask 077; mkdir -p -- "${socket_path%/*}")
        return $?
    fi
    group="$(systemctl show --property=Group --value haproxy.service)" || return 1
    if [[ -z "$group" ]]; then
        group="$(id -g -- "$user")" || return 1
    fi
    if ! mkdir -p -- "${socket_path%/*}" ||
        ! chgrp -- "$group" "$RELAY_DIR" "$RELAY_DIR/run" "${socket_path%/*}" ||
        ! chmod 0710 -- "$RELAY_DIR" ||
        ! chmod 0770 -- "$RELAY_DIR/run" "${socket_path%/*}"; then
        error "Не удалось назначить службе HAProxy права на каталог Stats Socket."
        return 1
    fi
}

relay_haproxy_service() (
    local action="$1"

    lock_relay && check_command systemctl || return 1
    if [[ "$action" != stop ]]; then
        check_relay_haproxy_config || return 1
    fi
    systemctl "$action" haproxy
)

relay_stats_config() {
    local mode="$1" source="$2" socket_path="${3:-}" contstats="${4:-0}" managed_lines="${5:-}"

    LC_ALL=C awk -v mode="$mode" -v sock="$socket_path" -v cont="$contstats" -v owned="$managed_lines" '
        function flush_section() {
            if (mode != "add") return
            if (section == "global" && !has_socket)
                print "    stats socket " sock " mode 660 level user # RemnaSuper traffic"
            if (section == "defaults" && cont && !has_contstats)
                print "    option contstats # RemnaSuper traffic"
        }
        BEGIN { restore_count = split(owned, restore_lines, "\n") }
        {
            owned_line = ($0 ~ /^[ \t]*stats[ \t]+socket[ \t]+\/opt\/RemnaSuper\/haproxy\/run\/[^ \t]+ mode 660 level user # RemnaSuper traffic$/ ||
                          $0 ~ /^[ \t]*option[ \t]+contstats # RemnaSuper traffic$/)
            if (mode == "owned") {
                if (owned_line) print
                next
            }
            if (mode == "strip" && owned_line) next
            if ($1 ~ /^(global|defaults|frontend|backend|listen|peers|resolvers|userlist|cache|mailers|program|ring|log-forward|log-profile|traces|acme|crt-store|http-errors|fcgi-app)$/) {
                flush_section()
                section = $1
                has_socket = 0
                has_contstats = 0
                if (section == "global") found_global = 1
                if (section == "defaults") defaults_count++
                if (mode == "restore" && (section == "global" || section == "defaults")) {
                    print
                    for (i=1; i<=restore_count; i++) {
                        if ((section == "global" && restore_lines[i] ~ /stats socket/) ||
                            (section == "defaults" && restore_lines[i] ~ /option contstats/)) print restore_lines[i]
                    }
                    next
                }
            }
            if (section == "global" && $1 == "stats" && $2 == "socket") {
                address = $3
                gsub(/^["\047]|["\047]$/, "", address)
                sub(/^unix@/, "", address)
                if (address == sock) has_socket = 1
                else if (mode == "add" && owned_line) next
            }
            if (($1 == "option" && $2 == "contstats") ||
                (($1 == "no" || $1 == "default") && $2 == "option" && $3 == "contstats")) {
                if (section == "defaults") {
                    if (!has_contstats && $1 == "option") enabled_defaults++
                    if ($1 != "option") overridden = 1
                    has_contstats = 1
                }
                if ((section == "frontend" || section == "listen") && $1 != "option") overridden = 1
            }
            if (mode != "contstats") print
        }
        END {
            flush_section()
            if (mode == "add" && !found_global) print "\nglobal\n    stats socket " sock " mode 660 level user # RemnaSuper traffic"
            if (mode == "contstats" && (!defaults_count || enabled_defaults < defaults_count || overridden)) exit 1
        }
    ' "$source"
}

wait_relay_stats_socket() {
    local previous_worker="${1:-}" worker attempt

    for attempt in {1..12}; do
        if worker="$(relay_traffic_command probe --worker 2>/dev/null)" && [[ "$worker" != "$previous_worker" ]]; then
            return 0
        fi
        (( attempt == 12 )) || sleep 1
    done
    error "Stats Socket HAProxy не ответил после применения конфигурации."
    relay_traffic_command probe
    return 1
}

prepare_relay_payload() (
    local source="$REMNASUPER_APP_DIR/haproxy" staging extracted version

    if [[ -f "$source/collector/collector.py" ]]; then
        deploy_relay_payload "$source"
        return $?
    fi
    check_command curl && check_command tar || return 1
    staging="$(mktemp -d "$RELAY_DIR/run/payload.XXXXXXXX")" || return 1
    trap 'rm -rf -- "$staging"' EXIT
    step "Загрузка файлов сборщика для установленной версии RemnaSuper..."
    curl -fsSL --connect-timeout 10 --max-time 60 -o "$staging/source.tar.gz" "$GITHUB_TARBALL_URL" &&
        tar -xzf "$staging/source.tar.gz" -C "$staging" || return 1
    extracted="$(find "$staging" -mindepth 1 -maxdepth 1 -type d -print -quit)" || return 1
    version="$(tr -d '[:space:]' < "$extracted/VERSION")" || return 1
    if [[ "$version" != "$REMNASUPER_VERSION" ]]; then
        error "Версия файлов сборщика отличается от установленной версии RemnaSuper. Сначала обновите RemnaSuper."
        return 1
    fi
    deploy_relay_payload "$extracted/haproxy"
)

register_relay_collector() (
    if relay_service_registered; then
        systemctl daemon-reload && systemctl enable --now "$RELAY_SERVICE"
        return $?
    fi
    if [[ -e "$RELAY_SERVICE_LINK" || -L "$RELAY_SERVICE_LINK" ]] ||
        [[ "$(systemctl show --property=LoadState --value "$RELAY_SERVICE")" != not-found ]]; then
        error "Обнаружена другая служба с именем $RELAY_SERVICE."
        return 1
    fi
    ln -s -- "$RELAY_DIR/systemd/$RELAY_SERVICE" "$RELAY_SERVICE_LINK" || return 1
    trap '
        systemctl disable --now "$RELAY_SERVICE"
        rm -f -- "$RELAY_SERVICE_LINK"
        systemctl daemon-reload
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    systemctl daemon-reload && systemctl enable --now "$RELAY_SERVICE" || return 1
    trap - EXIT
)

install_relay_haproxy() (
    local ID='' ID_LIKE='' socket_path contstats=0

    if [[ ! -r /etc/os-release ]]; then
        error "Не удалось определить операционную систему."
        return 1
    fi
    source /etc/os-release
    if [[ ! " $ID $ID_LIKE " =~ [[:space:]](debian|ubuntu)[[:space:]] ]]; then
        error "Для установки HAProxy требуется Debian, Ubuntu или совместимый дистрибутив."
        return 1
    fi
    lock_relay && check_command systemctl && prepare_relay_directories && prepare_relay_payload || return 1
    if [[ -e "$RELAY_SERVICE_LINK" || -L "$RELAY_SERVICE_LINK" ]] && ! relay_service_registered; then
        error "Путь $RELAY_SERVICE_LINK занят другой службой."
        return 1
    fi
    install_relay_packages haproxy python3 tzdata less || return 1
    check_command haproxy || return 1
    haproxy -v || return 1
    if ! /usr/bin/python3 -B -c 'import sqlite3; from zoneinfo import ZoneInfo; ZoneInfo("Europe/Moscow")'; then
        error "Сборщику нужны Python 3.9 или новее, SQLite и tzdata."
        return 1
    fi
    /usr/bin/python3 -B "$RELAY_DIR/collector/collector.py" init || return 1
    socket_path="$(relay_traffic_command socket-path)" || return 1
    if [[ ! "$socket_path" =~ ^/opt/RemnaSuper/haproxy/run/[A-Za-z0-9_./-]+$ ]] || (( ${#socket_path} > 107 )); then
        error "Укажите допустимый путь Unix-сокета внутри $RELAY_DIR/run."
        return 1
    fi
    prepare_relay_socket_directory "$socket_path" || return 1
    if ! relay_stats_config contstats "$RELAY_HAPROXY_CONFIG"; then
        info "option contstats обновляет счётчики во время длительных TCP-сеансов."
        if confirm "Добавить option contstats в секции defaults, где настройка отсутствует?"; then
            contstats=1
        fi
    fi
    commit_relay_config 0 relay_stats_config add "$RELAY_HAPROXY_CONFIG" "$socket_path" "$contstats" || return 1
    if ! relay_stats_config contstats "$RELAY_HAPROXY_CONFIG"; then
        warn "В некоторых секциях длительные соединения могут учитываться при их закрытии. Проверьте option contstats."
    fi
    systemctl enable --now haproxy && relay_traffic_command probe && register_relay_collector || return 1
    success "HAProxy и $RELAY_SERVICE запущены."
)

remove_relay_haproxy() (
    local mode="$1" managed_lines=''

    lock_relay && check_command dpkg-query && check_command systemctl || return 1
    if [[ "$mode" != history && "$mode" != full ]]; then
        return 1
    fi
    if [[ -L "$RELAY_DIR" || "$RELAY_DIR" != /opt/RemnaSuper/haproxy ]]; then
        error "Небезопасный путь модуля HAProxy: $RELAY_DIR."
        return 1
    fi
    if [[ ( -e "$RELAY_SERVICE_LINK" || -L "$RELAY_SERVICE_LINK" ) ]] && ! relay_service_registered; then
        error "Системная ссылка $RELAY_SERVICE_LINK принадлежит другой службе."
        return 1
    fi
    if [[ -f "$RELAY_HAPROXY_CONFIG" ]]; then
        managed_lines="$(relay_stats_config owned "$RELAY_HAPROXY_CONFIG")" || return 1
        if [[ -n "$managed_lines" && -L "$RELAY_HAPROXY_CONFIG" ]]; then
            error "Невозможно убрать настройки сборщика из конфигурации, заданной ссылкой."
            return 1
        fi
    fi
    if [[ -n "$managed_lines" ]] || relay_service_registered; then
        prepare_relay_directories || return 1
    fi
    if relay_service_registered && [[ -f "$RELAY_SERVICE_LINK" ]]; then
        backup_config_file "$RELAY_SERVICE_LINK" '' "$RELAY_DIR/backups" || return 1
    fi
    if relay_package_installed haproxy; then
        check_command apt-get && apt-get remove -y haproxy || return 1
    fi
    if relay_service_registered; then
        systemctl disable --now "$RELAY_SERVICE" && rm -f -- "$RELAY_SERVICE_LINK" || return 1
    fi
    systemctl daemon-reload || return 1
    if [[ -n "$managed_lines" ]]; then
        commit_relay_config 1 relay_stats_config strip "$RELAY_HAPROXY_CONFIG" || return 1
    fi
    if [[ "$mode" == full ]]; then
        rm -rf --one-file-system -- "$RELAY_DIR" || return 1
        success "HAProxy и модуль статистики удалены вместе с данными."
    else
        remove_relay_payload || return 1
        success "HAProxy и сборщик удалены. История и настройки сохранены в $RELAY_DIR."
    fi
)

remove_relay_payload() {
    local code

    if [[ -L "$RELAY_DIR/collector" ]]; then
        code="$(readlink -- "$RELAY_DIR/collector")" || return 1
        if [[ ! "$code" =~ ^code\.[A-Za-z0-9]{8}$ ]]; then
            error "Неизвестная ссылка на код сборщика: $RELAY_DIR/collector."
            return 1
        fi
        rm -rf -- "${RELAY_DIR:?}/${code:?}" || return 1
        rm -f -- "$RELAY_DIR/collector" || return 1
    fi
    rm -f -- "$RELAY_DIR/systemd/$RELAY_SERVICE"
}
