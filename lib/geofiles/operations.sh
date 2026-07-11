#!/usr/bin/env bash

install_geofile() {
    local repo_name="$1"
    local geosite_url="$2"
    local geoip_url="$3"
    local files_downloaded=0

    header "Установка geofiles: ${repo_name}"
    check_command wget || return 1
    mkdir -p "$GEOFILES_DIR"

    if [ "$geosite_url" != "none" ]; then
        local geosite_filename="${repo_name}-geosite.dat"
        step "Скачивание geosite.dat..."
        if ! download_geofile_safely "$geosite_url" "${GEOFILES_DIR}/${geosite_filename}"; then
            error "Ошибка при скачивании geosite.dat."
            return 1
        fi
        files_downloaded=$((files_downloaded + 1))
        if ! add_geofile_cron "$geosite_filename" "$geosite_url"; then
            error "Не удалось добавить задачу обновления ${geosite_filename} в crontab."
            return 1
        fi
        success "geosite.dat скачан: ${GEOFILES_DIR}/${geosite_filename}"
        success "Задача добавлена в crontab: ежедневное обновление в 00:00."
    fi

    if [ "$geoip_url" != "none" ]; then
        local geoip_filename="${repo_name}-geoip.dat"
        step "Скачивание geoip.dat..."
        if ! download_geofile_safely "$geoip_url" "${GEOFILES_DIR}/${geoip_filename}"; then
            error "Ошибка при скачивании geoip.dat."
            return 1
        fi
        files_downloaded=$((files_downloaded + 1))
        if ! add_geofile_cron "$geoip_filename" "$geoip_url"; then
            error "Не удалось добавить задачу обновления ${geoip_filename} в crontab."
            return 1
        fi
        success "geoip.dat скачан: ${GEOFILES_DIR}/${geoip_filename}"
        success "Задача добавлена в crontab: ежедневное обновление в 00:00."
    fi

    if [ "$files_downloaded" -eq 0 ]; then
        error "Не указаны URL для скачивания файлов."
        return 1
    fi

    if [ -f "$COMPOSE_FILE" ]; then
        printf "\n"
        step "Добавление volumes в docker-compose.yml..."
        backup_compose

        if [ "$geosite_url" != "none" ]; then
            local geosite_filename="${repo_name}-geosite.dat"
            migrate_legacy_geofile_volume "$geosite_filename" || return 1
            add_remnanode_volume "${GEOFILES_DIR}/${geosite_filename}:/usr/local/bin/${geosite_filename}" || return 1
        fi
        if [ "$geoip_url" != "none" ]; then
            local geoip_filename="${repo_name}-geoip.dat"
            migrate_legacy_geofile_volume "$geoip_filename" || return 1
            add_remnanode_volume "${GEOFILES_DIR}/${geoip_filename}:/usr/local/bin/${geoip_filename}" || return 1
        fi

        restart_remnanode_compose
    else
        printf "\n"
        warn "Файл docker-compose.yml не найден по пути ${COMPOSE_FILE}"
        info "Настройка volume и перезапуск контейнеров пропущены."
    fi
}

uninstall_geofile() {
    local repo_name="$1"
    local has_geosite="$2"
    local has_geoip="$3"
    local files_removed=0
    local modified=false

    header "Удаление geofiles: ${repo_name}"

    if [ "$has_geosite" = "true" ]; then
        local geosite_filename="${repo_name}-geosite.dat"
        local geosite_path="${GEOFILES_DIR}/${geosite_filename}"
        if [ -f "$geosite_path" ]; then
            step "Удаление файла: ${geosite_path}"
            rm -f "$geosite_path"
            files_removed=$((files_removed + 1))
            success "Файл ${geosite_filename} удален."
        else
            info "Файл ${geosite_filename} не найден, пропуск."
        fi
        step "Удаление задачи из crontab для ${geosite_filename}..."
        (crontab -l 2>/dev/null | grep -vF "${geosite_filename}" || true) | crontab -
        success "Задача для ${geosite_filename} удалена из crontab."
    fi

    if [ "$has_geoip" = "true" ]; then
        local geoip_filename="${repo_name}-geoip.dat"
        local geoip_path="${GEOFILES_DIR}/${geoip_filename}"
        if [ -f "$geoip_path" ]; then
            step "Удаление файла: ${geoip_path}"
            rm -f "$geoip_path"
            files_removed=$((files_removed + 1))
            success "Файл ${geoip_filename} удален."
        else
            info "Файл ${geoip_filename} не найден, пропуск."
        fi
        step "Удаление задачи из crontab для ${geoip_filename}..."
        (crontab -l 2>/dev/null | grep -vF "${geoip_filename}" || true) | crontab -
        success "Задача для ${geoip_filename} удалена из crontab."
    fi

    if [ "$files_removed" -eq 0 ]; then
        info "Нет файлов для удаления."
    fi

    if [ -f "$COMPOSE_FILE" ]; then
        printf "\n"
        step "Удаление volumes из docker-compose.yml..."
        backup_compose

        if [ "$has_geosite" = "true" ]; then
            local geosite_filename="${repo_name}-geosite.dat"
            if grep -qF "$geosite_filename" "$COMPOSE_FILE"; then
                sed -i "\|${geosite_filename}|d" "$COMPOSE_FILE"
                modified=true
                success "Volume для ${geosite_filename} удален."
            fi
        fi

        if [ "$has_geoip" = "true" ]; then
            local geoip_filename="${repo_name}-geoip.dat"
            if grep -qF "$geoip_filename" "$COMPOSE_FILE"; then
                sed -i "\|${geoip_filename}|d" "$COMPOSE_FILE"
                modified=true
                success "Volume для ${geoip_filename} удален."
            fi
        fi

        if [ "$modified" = true ]; then
            restart_remnanode_compose
        else
            info "Volumes не найдены в docker-compose.yml."
        fi
    else
        printf "\n"
        warn "Файл docker-compose.yml не найден по пути ${COMPOSE_FILE}"
        info "Удаление volumes пропущено."
    fi

    success "Удаление geofiles завершено."
}

