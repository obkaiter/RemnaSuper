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

