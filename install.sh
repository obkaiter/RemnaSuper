#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/RemnaSuper"
COMMAND_LINK="/usr/local/bin/RemnaSuper"
GITHUB_REPO="SP1K33/RemnaSuper"
GITHUB_BRANCH="${REMNASUPER_BRANCH:-main}"
GITHUB_TARBALL_URL="https://codeload.github.com/${GITHUB_REPO}/tar.gz/refs/heads/${GITHUB_BRANCH}"

if [ "$EUID" -ne 0 ]; then
    printf "[x] Запустите установку от root: curl -fsSL https://raw.githubusercontent.com/%s/%s/install.sh | sudo bash\n" "$GITHUB_REPO" "$GITHUB_BRANCH"
    exit 1
fi

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf "[x] Команда '%s' не найдена.\n" "$1"
        exit 1
    fi
}

require_command curl
require_command tar

if [ "$INSTALL_DIR" != "/opt/RemnaSuper" ]; then
    printf "[x] Небезопасный путь установки: %s\n" "$INSTALL_DIR"
    exit 1
fi

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

        printf "[i] %s уже существует и не является каталогом. Перенос в %s\n" "$INSTALL_DIR" "$legacy_path"
        if ! mv -- "$INSTALL_DIR" "$legacy_path"; then
            printf "[x] Не удалось сохранить существующий %s.\n" "$INSTALL_DIR"
            return 1
        fi
    fi

    if ! mkdir -p "$INSTALL_DIR"; then
        printf "[x] Не удалось создать каталог установки: %s\n" "$INSTALL_DIR"
        return 1
    fi
}

tmp_dir="$(mktemp -d)"
archive="$tmp_dir/remnasuper.tar.gz"
src_root="$tmp_dir/source"

cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

printf "[>] Скачивание RemnaSuper...\n"
curl -fL --connect-timeout 10 --max-time 60 -o "$archive" "$GITHUB_TARBALL_URL"

mkdir -p "$src_root"
tar -xzf "$archive" -C "$src_root"
src_dir="$(find "$src_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

if [ -z "$src_dir" ] || [ ! -f "$src_dir/RemnaSuper" ] || [ ! -d "$src_dir/lib" ] || [ ! -f "$src_dir/VERSION" ]; then
    printf "[x] В архиве нет обязательных файлов RemnaSuper.\n"
    exit 1
fi

printf "[>] Установка в %s...\n" "$INSTALL_DIR"
prepare_install_dir
rm -rf "$INSTALL_DIR/lib"
cp -a "$src_dir/lib" "$INSTALL_DIR/"
install -m 755 "$src_dir/RemnaSuper" "$INSTALL_DIR/RemnaSuper"
install -m 644 "$src_dir/VERSION" "$INSTALL_DIR/VERSION"
[ -f "$src_dir/install.sh" ] && install -m 755 "$src_dir/install.sh" "$INSTALL_DIR/install.sh"
[ -f "$src_dir/README.md" ] && install -m 644 "$src_dir/README.md" "$INSTALL_DIR/README.md"

ln -sfn "$INSTALL_DIR/RemnaSuper" "$COMMAND_LINK"

printf "[ok] Установлено.\n"
printf "[i] Запуск из любого места: RemnaSuper\n"
