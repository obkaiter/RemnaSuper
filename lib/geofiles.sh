#!/usr/bin/env bash

install_geofile() {
    local repo_name="$1"
    local geosite_url="$2"
    local geoip_url="$3"
    local files_downloaded=0

    header "Установка geofiles: ${repo_name}"
    check_command wget || return 1
    mkdir -p "$XRAY_SHARE_DIR"

    if [ "$geosite_url" != "none" ]; then
        local geosite_filename="${repo_name}-geosite.dat"
        step "Скачивание geosite.dat..."
        if ! wget -q --show-progress -O "${XRAY_SHARE_DIR}/${geosite_filename}" "$geosite_url"; then
            error "Ошибка при скачивании geosite.dat."
            return 1
        fi
        files_downloaded=$((files_downloaded + 1))
        (
            crontab -l 2>/dev/null | grep -v "${geosite_filename}" || true
            printf "0 0 * * * /usr/bin/wget -q -O %s/%s %s\n" "$XRAY_SHARE_DIR" "$geosite_filename" "$geosite_url"
        ) | crontab -
        success "geosite.dat скачан: ${XRAY_SHARE_DIR}/${geosite_filename}"
        success "Задача добавлена в crontab: ежедневное обновление в 00:00."
    fi

    if [ "$geoip_url" != "none" ]; then
        local geoip_filename="${repo_name}-geoip.dat"
        step "Скачивание geoip.dat..."
        if ! wget -q --show-progress -O "${XRAY_SHARE_DIR}/${geoip_filename}" "$geoip_url"; then
            error "Ошибка при скачивании geoip.dat."
            return 1
        fi
        files_downloaded=$((files_downloaded + 1))
        (
            crontab -l 2>/dev/null | grep -v "${geoip_filename}" || true
            printf "0 0 * * * /usr/bin/wget -q -O %s/%s %s\n" "$XRAY_SHARE_DIR" "$geoip_filename" "$geoip_url"
        ) | crontab -
        success "geoip.dat скачан: ${XRAY_SHARE_DIR}/${geoip_filename}"
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
            add_remnanode_volume "${XRAY_SHARE_DIR}/${geosite_filename}:/usr/local/bin/${geosite_filename}" || return 1
        fi
        if [ "$geoip_url" != "none" ]; then
            local geoip_filename="${repo_name}-geoip.dat"
            add_remnanode_volume "${XRAY_SHARE_DIR}/${geoip_filename}:/usr/local/bin/${geoip_filename}" || return 1
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
        local geosite_path="${XRAY_SHARE_DIR}/${geosite_filename}"
        if [ -f "$geosite_path" ]; then
            step "Удаление файла: ${geosite_path}"
            rm -f "$geosite_path"
            files_removed=$((files_removed + 1))
            success "Файл ${geosite_filename} удален."
        else
            info "Файл ${geosite_filename} не найден, пропуск."
        fi
        step "Удаление задачи из crontab для ${geosite_filename}..."
        (crontab -l 2>/dev/null | grep -v "${geosite_filename}" || true) | crontab -
        success "Задача для ${geosite_filename} удалена из crontab."
    fi

    if [ "$has_geoip" = "true" ]; then
        local geoip_filename="${repo_name}-geoip.dat"
        local geoip_path="${XRAY_SHARE_DIR}/${geoip_filename}"
        if [ -f "$geoip_path" ]; then
            step "Удаление файла: ${geoip_path}"
            rm -f "$geoip_path"
            files_removed=$((files_removed + 1))
            success "Файл ${geoip_filename} удален."
        else
            info "Файл ${geoip_filename} не найден, пропуск."
        fi
        step "Удаление задачи из crontab для ${geoip_filename}..."
        (crontab -l 2>/dev/null | grep -v "${geoip_filename}" || true) | crontab -
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
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
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
