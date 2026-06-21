#!/usr/bin/env bash

download_geofile_safely() {
    local url="$1"
    local target="$2"
    local tmp_file

    if ! tmp_file="$(mktemp "${target}.tmp.XXXXXX")"; then
        error "Не удалось создать временный файл для ${target}."
        return 1
    fi

    if wget -q --show-progress -O "$tmp_file" "$url" \
        && [ -s "$tmp_file" ] \
        && chmod 0644 "$tmp_file" \
        && mv -f "$tmp_file" "$target"; then
        return 0
    fi

    rm -f "$tmp_file"
    error "Не удалось безопасно обновить ${target}; существующий файл сохранён."
    return 1
}

add_geofile_cron() {
    local filename="$1"
    local url="$2"
    local target="${GEOFILES_DIR}/${filename}"

    (
        crontab -l 2>/dev/null | grep -vF "$filename" || true
        printf "0 0 * * * tmp=\$(/usr/bin/mktemp '%s.tmp.XXXXXX') && /usr/bin/wget -q -O \"\$tmp\" '%s' && [ -s \"\$tmp\" ] && /bin/chmod 0644 \"\$tmp\" && /bin/mv -f \"\$tmp\" '%s' || { status=\$?; [ -z \"\$tmp\" ] || /bin/rm -f \"\$tmp\"; exit \"\$status\"; }\n" \
            "$target" "$url" "$target"
    ) | crontab -
}

migrate_legacy_geofile_volume() {
    local filename="$1"
    local legacy_volume="/opt/remnawave/xray/share/${filename}:/usr/local/bin/${filename}"
    local current_volume="${GEOFILES_DIR}/${filename}:/usr/local/bin/${filename}"

    if grep -qF "$legacy_volume" "$COMPOSE_FILE"; then
        if ! sed -i "s|${legacy_volume}|${current_volume}|g" "$COMPOSE_FILE"; then
            error "Не удалось перенести volume для ${filename} в ${GEOFILES_DIR}."
            return 1
        fi
        success "Volume для ${filename} перенесён в ${GEOFILES_DIR}."
    fi
}

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

install_roscomvpn_geofiles() {
    install_geofile "roscomvpn" \
        "https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat" \
        "https://github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat"
}

uninstall_roscomvpn_geofiles() {
    uninstall_geofile "roscomvpn" "true" "true"
}

install_loyalsoldier_geofiles() {
    install_geofile "loyalsoldier" \
        "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat" \
        "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
}

uninstall_loyalsoldier_geofiles() {
    uninstall_geofile "loyalsoldier" "true" "true"
}

install_xray_routing_geofiles() {
    install_geofile "xray-routing" \
        "https://raw.githubusercontent.com/Davoyan/xray-routing/main/release/geosite.dat" \
        "https://raw.githubusercontent.com/Davoyan/xray-routing/main/release/geoip.dat"
}

uninstall_xray_routing_geofiles() {
    uninstall_geofile "xray-routing" "true" "true"
}

install_all_geofiles() {
    header "Установка всех geofiles"
    install_roscomvpn_geofiles
    divider
    install_loyalsoldier_geofiles
    divider
    install_xray_routing_geofiles
}

uninstall_all_geofiles() {
    header "Удаление всех geofiles"
    uninstall_roscomvpn_geofiles
    divider
    uninstall_loyalsoldier_geofiles
    divider
    uninstall_xray_routing_geofiles
}
