#!/usr/bin/env bash

download_geofile_safely() {
    local url="$1"
    local target="$2"
    local tmp_file

    if ! tmp_file="$(mktemp "${target}.tmp.XXXXXX")"; then
        error "Не удалось создать временный файл для ${target}."
        return 1
    fi

    if wget -q --show-progress --timeout=30 --tries=3 -O "$tmp_file" "$url" \
        && [ -s "$tmp_file" ] \
        && chmod 0644 "$tmp_file" \
        && mv -f "$tmp_file" "$target"; then
        return 0
    fi

    rm -f "$tmp_file"
    error "Не удалось безопасно обновить ${target}; существующий файл сохранён."
    return 1
}

update_geofile_cron() {
    local filename="$1"
    local url="${2:-}"
    local target="${GEOFILES_DIR}/${filename}"
    local entries updated_entries

    if ! entries="$(LC_ALL=C crontab -l 2>&1)"; then
        if [[ "$entries" != 'no crontab for '* ]]; then
            error "Не удалось прочитать crontab: $entries"
            return 1
        fi
        [[ -n "$url" ]] || return 0
        entries=''
    fi

    updated_entries="$(printf '%s\n' "$entries" | LC_ALL=C awk -v tmp="'$target.tmp.XXXXXX'" '!index($0, tmp)')" || return 1
    if [[ -z "$url" && "$entries" == "$updated_entries" ]]; then
        return 0
    fi

    if ! {
        if [[ -n "$updated_entries" ]]; then printf '%s\n' "$updated_entries"; fi
        if [[ -n "$url" ]]; then
            printf "0 0 * * * exec 9>'%s'; /usr/bin/flock 9 || exit \$?; [ -f '%s' ] || exit 0; " \
                "$GEOFILES_LOCK" "$target"
            printf "tmp=\$(/usr/bin/mktemp '%s.tmp.XXXXXX') && /usr/bin/wget -q --timeout=30 --tries=3 -O \"\$tmp\" '%s' && [ -s \"\$tmp\" ] && /bin/chmod 0644 \"\$tmp\" && /bin/mv -f \"\$tmp\" '%s' || { status=\$?; [ -z \"\$tmp\" ] || /bin/rm -f \"\$tmp\"; exit \"\$status\"; }\n" \
                "$target" "$url" "$target"
        fi
    } | crontab -; then
        error "Не удалось сохранить задания crontab для $filename."
        return 1
    fi
}

