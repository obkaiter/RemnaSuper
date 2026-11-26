#!/usr/bin/env bash

version_gt() {
    local newest="$1"
    local current="$2"

    [ "$newest" != "$current" ] && [ "$(printf '%s\n%s\n' "$current" "$newest" | sort -V | head -n 1)" = "$current" ]
}

fetch_remote_version() {
    curl -fsSL --connect-timeout 5 --max-time 10 -H 'Cache-Control: no-cache' \
        "$GITHUB_RAW_BASE/VERSION" | tr -d '[:space:]'
}

prepare_install_dir() {
    local legacy_base legacy_path suffix=0

    if [ -d "$INSTALL_DIR" ] && [ ! -L "$INSTALL_DIR" ]; then
        return 0
    fi

    if [ -e "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ]; then
        legacy_base="${INSTALL_DIR}.legacy.$(date +%Y%m%d%H%M%S)"
        legacy_path="$legacy_base"

        while [ -e "$legacy_path" ] || [ -L "$legacy_path" ]; do
            suffix=$((suffix + 1))
            legacy_path="${legacy_base}.${suffix}"
        done

        info "${INSTALL_DIR} не является каталогом; перенос в ${legacy_path}."
        if ! mv -- "$INSTALL_DIR" "$legacy_path"; then
            error "Не удалось сохранить существующий ${INSTALL_DIR}."
            return 1
        fi
    fi

    if ! mkdir -p "$INSTALL_DIR"; then
        error "Не удалось создать каталог установки: ${INSTALL_DIR}"
        return 1
    fi
}

cleanup_runtime_install() {
    local file failed=0

    if (( activating && ! installed )); then
        for file in "${runtime_files[@]}"; do
            if [[ ! -e "$staging/next/$file" ]] &&
                ! mv -T -- "$INSTALL_DIR/$file" "$staging/next/$file"; then
                failed=1
                continue
            fi
            if [[ -e "$staging/previous/$file" || -L "$staging/previous/$file" ]] &&
                ! mv -T -- "$staging/previous/$file" "$INSTALL_DIR/$file"; then
                failed=1
            fi
        done
    fi
    if (( failed )); then
        error "Не удалось полностью вернуть прежнюю версию. Резервные файлы сохранены в $staging/previous."
    else
        rm -rf -- "$staging" || warn "Не удалось удалить временный каталог $staging."
    fi
}

install_from_dir() (
    local src_dir="$1" update_version="${2:-}"
    local staging file installed_version activating=0 installed=0
    local -a runtime_files=(lib RemnaSuper)

    if [ "$INSTALL_DIR" != "/opt/RemnaSuper" ]; then
        error "Небезопасный путь установки: $INSTALL_DIR"
        return 1
    fi

    if [[ ! -s "$src_dir/RemnaSuper" || ! -s "$src_dir/VERSION" ]]; then
        error "В архиве обновления нет обязательных файлов."
        return 1
    fi
    for file in config ui common update logs system geofiles menu system/relay_deploy; do
        if [[ ! -s "$src_dir/lib/$file.sh" ]]; then
            error "В архиве обновления нет обязательного файла lib/$file.sh."
            return 1
        fi
    done

    source "$src_dir/lib/system/relay_deploy.sh" && validate_relay_payload "$src_dir/haproxy" || return 1
    prepare_install_dir && lock_relay || return 1

    if [[ -n "$update_version" && -f "$INSTALL_DIR/VERSION" ]]; then
        if ! installed_version="$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION")"; then
            error "Не удалось прочитать установленную версию RemnaSuper."
            return 1
        fi
        if version_gt "$installed_version" "$update_version"; then
            error "Уже установлена более новая версия RemnaSuper ${installed_version}."
            return 1
        fi
    fi
    if [[ -d "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]]; then
        error "Не удалось создать команду rs: $COMMAND_LINK является каталогом."
        return 1
    fi

    if ! staging="$(mktemp -d "$INSTALL_DIR/.update.XXXXXXXX")"; then
        error "Не удалось создать временный каталог установки."
        return 1
    fi
    trap cleanup_runtime_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if ! mkdir -- "$staging/next" "$staging/previous" ||
        ! cp -a -- "$src_dir/lib" "$staging/next/" ||
        ! install -m 755 -- "$src_dir/RemnaSuper" "$staging/next/RemnaSuper" ||
        ! install -m 644 -- "$src_dir/VERSION" "$staging/next/VERSION"; then
        error "Не удалось подготовить файлы RemnaSuper к установке."
        return 1
    fi
    if [[ -f "$src_dir/install.sh" ]]; then
        if ! install -m 755 -- "$src_dir/install.sh" "$staging/next/install.sh"; then
            error "Не удалось подготовить install.sh к установке."
            return 1
        fi
        runtime_files+=(install.sh)
    fi
    if [[ -f "$src_dir/README.md" ]]; then
        if ! install -m 644 -- "$src_dir/README.md" "$staging/next/README.md"; then
            error "Не удалось подготовить README.md к установке."
            return 1
        fi
        runtime_files+=(README.md)
    fi
    runtime_files+=(VERSION)

    activating=1
    for file in "${runtime_files[@]}"; do
        if [[ -e "$INSTALL_DIR/$file" || -L "$INSTALL_DIR/$file" ]] &&
            ! mv -T -- "$INSTALL_DIR/$file" "$staging/previous/$file"; then
            error "Не удалось сохранить прежний файл или каталог $file."
            return 1
        fi
        if ! mv -T -- "$staging/next/$file" "$INSTALL_DIR/$file"; then
            error "Не удалось установить $file."
            return 1
        fi
    done
    if ! deploy_relay_payload "$src_dir/haproxy"; then
        error "Не удалось обновить сборщик HAProxy."
        return 1
    fi
    if [[ "$(readlink -- "$COMMAND_LINK" 2>/dev/null)" != "$INSTALL_DIR/RemnaSuper" ]] &&
        ! ln -sfnT -- "$INSTALL_DIR/RemnaSuper" "$COMMAND_LINK"; then
        error "Не удалось обновить команду rs: $COMMAND_LINK."
        return 1
    fi
    installed=1
)

download_and_install_update() (
    local remote_version="$1"
    local commit tmp_dir archive src_root src_dir archive_version
    local -a source_dirs

    if ! commit="$(curl -fsSL --connect-timeout 5 --max-time 10 \
        -H 'Accept: application/vnd.github.sha' -H 'Cache-Control: no-cache' \
        "https://api.github.com/repos/$GITHUB_REPO/commits/$GITHUB_BRANCH")" ||
        [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
        error "Не удалось определить коммит обновления на GitHub."
        return 1
    fi
    if ! tmp_dir="$(mktemp -d)"; then
        error "Не удалось создать временный каталог загрузки."
        return 1
    fi
    trap 'rm -rf -- "$tmp_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    archive="$tmp_dir/remnasuper.tar.gz"
    src_root="$tmp_dir/source"

    step "Скачивание обновления RemnaSuper..."
    if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$archive" "$GITHUB_TARBALL_BASE/$commit"; then
        error "Не удалось скачать обновление."
        return 1
    fi

    if ! mkdir -- "$src_root" || ! tar -xzf "$archive" -C "$src_root"; then
        error "Не удалось распаковать обновление."
        return 1
    fi

    source_dirs=("$src_root"/*)
    src_dir="${source_dirs[0]:-}"
    if (( ${#source_dirs[@]} != 1 )) || [[ ! -f "$src_dir/VERSION" ]] ||
        ! archive_version="$(tr -d '[:space:]' < "$src_dir/VERSION")" ||
        [[ ! "$archive_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        error "В архиве обновления нет корректного файла VERSION."
        return 1
    fi
    if version_gt "$remote_version" "$archive_version"; then
        error "Архив содержит версию ${archive_version}, а GitHub объявил ${remote_version}. Попробуйте обновиться позже."
        return 1
    fi

    install_from_dir "$src_dir" "$archive_version" || return 1
    success "Обновлено до версии ${archive_version}."
)

perform_update() {
    local remote_version="$1" execfail=0
    shift

    download_and_install_update "$remote_version" || return 1
    info "Перезапуск RemnaSuper..."
    shopt -q execfail && execfail=1
    shopt -s execfail
    exec "$INSTALL_DIR/RemnaSuper" "$@"
    (( execfail )) || shopt -u execfail
    error "Не удалось запустить установленную версию RemnaSuper."
    return 1
}

check_for_updates() {
    local mode="$1" remote_version
    shift

    if [[ "$mode" == auto && "${REMNASUPER_SKIP_UPDATE:-0}" == 1 ]]; then
        warn "Автообновление пропущено: REMNASUPER_SKIP_UPDATE=1."
        return 0
    fi

    if ! check_command curl >/dev/null 2>&1; then
        warn "Проверка обновления пропущена: curl не найден."
        [[ "$mode" == auto ]]
        return $?
    fi
    if ! check_command tar >/dev/null 2>&1; then
        warn "Проверка обновления пропущена: tar не найден."
        [[ "$mode" == auto ]]
        return $?
    fi

    if ! remote_version="$(fetch_remote_version 2>/dev/null)" ||
        [[ ! "$remote_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        warn "Не удалось проверить версию на GitHub."
        [[ "$mode" == auto ]]
        return $?
    fi

    if version_gt "$remote_version" "$REMNASUPER_VERSION"; then
        warn "Доступна новая версия: ${remote_version}. Текущая: ${REMNASUPER_VERSION}."
        perform_update "$remote_version" "$@"
        return $?
    fi

    success "Версия актуальна: ${REMNASUPER_VERSION}."
}
