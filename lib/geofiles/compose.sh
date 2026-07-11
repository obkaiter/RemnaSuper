#!/usr/bin/env bash

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

