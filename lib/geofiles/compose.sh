#!/usr/bin/env bash

rewrite_geofile_volume() {
    local action="$1"
    local filename="$2"
    local compose="$3"

    LC_ALL=C awk -v action="$action" \
        -v current="$GEOFILES_DIR/$filename:/usr/local/bin/$filename" \
        -v legacy="/opt/remnawave/xray/share/$filename:/usr/local/bin/$filename" '
        function end_volumes() {
            if (!in_volumes) return
            if (action == "install" && !found_volume) print "      - " current
            if (action == "remove" && removed_volume && !kept_volume) print "      []"
            in_volumes=0
        }
        function end_remnanode() {
            if (!in_remnanode) return
            end_volumes()
            if (action == "install" && !found_volumes) {
                print "    volumes:"
                print "      - " current
            }
            in_remnanode=0
        }
        /^services:[[:space:]]*(#.*)?$/ { in_services=1; print; next }
        /^[^[:space:]#]/ { end_remnanode(); in_services=0 }
        in_services && /^  [^[:space:]#]/ {
            end_remnanode()
            if (/^  remnanode:[[:space:]]*(#.*)?$/) {
                in_remnanode=1
                found_service=1
            }
        }
        in_remnanode && /^    [^[:space:]#-]/ { end_volumes() }
        in_remnanode && /^    volumes:/ {
            found_volumes=1
            if (/^    volumes:[[:space:]]*\[\][[:space:]]*(#.*)?$/ && action == "install") {
                sub(/\[\]/, "")
            }
            if (/^    volumes:[[:space:]]*(#.*)?$/) in_volumes=1
            else if (action == "install") unsupported=1
        }
        in_volumes && /^[[:space:]]*-[[:space:]]+/ {
            entry=$0
            sub(/^[[:space:]]*-[[:space:]]+/, "", entry)
            sub(/[[:space:]]+#.*$/, "", entry)
            sub(/[[:space:]]+$/, "", entry)
            gsub(/^["\047]|["\047]$/, "", entry)
            path=entry
            sub(/:(ro|rw)$/, "", path)
            if (path == current || path == legacy) {
                if (action == "remove") {
                    removed_volume=1
                    next
                }
                if (found_volume) next
                found_volume=1
                if (path == legacy) $0="      - " current substr(entry, length(legacy)+1)
            }
            kept_volume=1
        }
        { print }
        END {
            end_remnanode()
            if (action == "install" && (!found_service || unsupported)) exit 1
        }
    ' "$compose"
}

configure_geofile_volumes() (
    local action="$1"
    shift
    local filename staged_compose='' rewritten_compose='' compose_backup

    if [[ ! -f "$COMPOSE_FILE" ]]; then
        warn "Файл $COMPOSE_FILE не найден. Изменение volumes и перезапуск RemnaNode пропущены."
        return 0
    fi
    if [[ -L "$COMPOSE_FILE" ]]; then
        error "Файл $COMPOSE_FILE является символической ссылкой."
        return 1
    fi
    trap '[[ -z "$staged_compose" ]] || rm -f -- "$staged_compose"; [[ -z "$rewritten_compose" ]] || rm -f -- "$rewritten_compose"' EXIT
    if ! staged_compose="$(mktemp "${COMPOSE_FILE}.XXXXXX")" ||
        ! rewritten_compose="$(mktemp "${COMPOSE_FILE}.XXXXXX")" ||
        ! cp -p -- "$COMPOSE_FILE" "$staged_compose"; then
        error "Не удалось подготовить временную копию $COMPOSE_FILE."
        return 1
    fi
    for filename in "$@"; do
        if ! rewrite_geofile_volume "$action" "$filename" "$staged_compose" > "$rewritten_compose" ||
            ! cat -- "$rewritten_compose" > "$staged_compose"; then
            error "Не удалось обработать volume для $filename в секции services.remnanode.volumes."
            return 1
        fi
    done
    if cmp -s -- "$COMPOSE_FILE" "$staged_compose"; then
        [[ "$action" != install ]] && return 0
        check_docker && (cd "$NODE_DIR" && docker compose config --quiet) &&
            restart_remnanode_compose
        return $?
    fi

    check_docker || return 1
    if ! (cd "$NODE_DIR" && docker compose -f "$staged_compose" config --quiet); then
        error "Изменённая конфигурация Docker Compose не прошла проверку."
        return 1
    fi
    if ! backup_compose compose_backup || ! mv -f -- "$staged_compose" "$COMPOSE_FILE"; then
        error "Не удалось обновить $COMPOSE_FILE."
        return 1
    fi
    if ! restart_remnanode_compose; then
        warn "Восстановление конфигурации Docker Compose из резервной копии."
        if ! cp -p -- "$compose_backup" "$staged_compose" ||
            ! mv -f -- "$staged_compose" "$COMPOSE_FILE" ||
            ! restart_remnanode_compose; then
            error "Не удалось полностью восстановить RemnaNode. Резервная копия: $compose_backup"
        fi
        return 1
    fi
)
