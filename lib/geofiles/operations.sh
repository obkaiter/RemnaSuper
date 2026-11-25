#!/usr/bin/env bash

install_geofile() (
    local repo_name="$1"
    shift
    local filename url lock_fd
    local -a filenames=()

    header "Установка geofiles: $repo_name"
    check_command wget && check_command crontab && check_command flock || return 1
    if ! { exec {lock_fd}> "$GEOFILES_LOCK"; } || ! flock "$lock_fd"; then
        error "Не удалось получить блокировку geofiles."
        return 1
    fi
    if ! mkdir -p -- "$GEOFILES_DIR"; then
        error "Не удалось создать каталог $GEOFILES_DIR."
        return 1
    fi

    while (( $# > 0 )); do
        filename="$1"
        url="$2"
        shift 2
        step "Скачивание $filename..."
        download_geofile_safely "$url" "$GEOFILES_DIR/$filename" || return 1
        update_geofile_cron "$filename" "$url" || return 1
        filenames+=("$filename")
        success "Файл $filename установлен. Обновление через cron ежедневно в 00:00."
    done

    configure_geofile_volumes install "${filenames[@]}"
)

uninstall_geofile() (
    local repo_name="$1"
    shift
    local filename lock_fd

    header "Удаление geofiles: $repo_name"
    check_command crontab && check_command flock || return 1
    if ! { exec {lock_fd}> "$GEOFILES_LOCK"; } || ! flock "$lock_fd"; then
        error "Не удалось получить блокировку geofiles."
        return 1
    fi
    configure_geofile_volumes remove "$@" || return 1

    for filename in "$@"; do
        update_geofile_cron "$filename" || return 1
        if ! rm -f -- "$GEOFILES_DIR/$filename"; then
            error "Не удалось удалить $GEOFILES_DIR/$filename."
            return 1
        fi
    done
    success "Удаление geofiles завершено."
)
