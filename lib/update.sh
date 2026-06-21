#!/usr/bin/env bash

version_gt() {
    local newest="$1"
    local current="$2"

    [ "$newest" != "$current" ] && [ "$(printf '%s\n%s\n' "$current" "$newest" | sort -V | head -n 1)" = "$current" ]
}

fetch_remote_version() {
    curl -fsSL --connect-timeout 5 --max-time 10 "$GITHUB_RAW_BASE/VERSION" | tr -d '[:space:]'
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

install_from_dir() {
    local src_dir="$1"

    if [ "$INSTALL_DIR" != "/opt/RemnaSuper" ]; then
        error "Небезопасный путь установки: $INSTALL_DIR"
        return 1
    fi

    if [ ! -f "$src_dir/RemnaSuper" ] || [ ! -f "$src_dir/VERSION" ] || [ ! -d "$src_dir/lib" ]; then
        error "В архиве обновления нет обязательных файлов."
        return 1
    fi

    prepare_install_dir || return 1
    rm -rf "$INSTALL_DIR/lib"
    cp -a "$src_dir/lib" "$INSTALL_DIR/"
    install -m 755 "$src_dir/RemnaSuper" "$INSTALL_DIR/RemnaSuper"
    install -m 644 "$src_dir/VERSION" "$INSTALL_DIR/VERSION"

    if [ -f "$src_dir/install.sh" ]; then
        install -m 755 "$src_dir/install.sh" "$INSTALL_DIR/install.sh"
    fi
    if [ -f "$src_dir/README.md" ]; then
        install -m 644 "$src_dir/README.md" "$INSTALL_DIR/README.md"
    fi

    ln -sfn "$INSTALL_DIR/RemnaSuper" "$COMMAND_LINK"
}

perform_update() {
    local remote_version="$1"
    shift

    local tmp_dir archive src_root src_dir
    tmp_dir="$(mktemp -d)"
    archive="$tmp_dir/remnasuper.tar.gz"
    src_root="$tmp_dir/source"

    step "Скачивание RemnaSuper v${remote_version}..."
    if ! curl -fL --connect-timeout 10 --max-time 60 -o "$archive" "$GITHUB_TARBALL_URL"; then
        rm -rf "$tmp_dir"
        error "Не удалось скачать обновление."
        return 1
    fi

    mkdir -p "$src_root"
    if ! tar -xzf "$archive" -C "$src_root"; then
        rm -rf "$tmp_dir"
        error "Не удалось распаковать обновление."
        return 1
    fi

    src_dir="$(find "$src_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [ -z "$src_dir" ] || ! install_from_dir "$src_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
    success "Обновлено до версии ${remote_version}."
    info "Перезапуск RemnaSuper..."
    exec "$COMMAND_LINK" "$@"
}

check_for_updates() {
    if [ "${REMNASUPER_SKIP_UPDATE:-0}" = "1" ]; then
        warn "Автообновление пропущено: REMNASUPER_SKIP_UPDATE=1."
        return 0
    fi

    if ! check_command curl >/dev/null 2>&1; then
        warn "Автообновление пропущено: curl не найден."
        return 0
    fi
    if ! check_command tar >/dev/null 2>&1; then
        warn "Автообновление пропущено: tar не найден."
        return 0
    fi

    local remote_version
    remote_version="$(fetch_remote_version 2>/dev/null || true)"

    if [ -z "$remote_version" ]; then
        warn "Не удалось проверить версию на GitHub."
        return 0
    fi

    if version_gt "$remote_version" "$REMNASUPER_VERSION"; then
        warn "Доступна новая версия: ${remote_version}. Текущая: ${REMNASUPER_VERSION}."
        perform_update "$remote_version" "$@"
        return $?
    fi

    success "Версия актуальна: ${REMNASUPER_VERSION}."
}
