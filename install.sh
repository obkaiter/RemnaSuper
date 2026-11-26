#!/usr/bin/env bash
set -euo pipefail

GITHUB_REPO="obkaiter/RemnaSuper"
GITHUB_BRANCH="${REMNASUPER_BRANCH:-main}"

if [ "$EUID" -ne 0 ]; then
    printf "[x] Запустите установку от root: curl -fsSL https://raw.githubusercontent.com/%s/%s/install.sh | sudo bash\n" "$GITHUB_REPO" "$GITHUB_BRANCH"
    exit 1
fi

cd /

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf "[x] Команда '%s' не найдена.\n" "$1"
        exit 1
    fi
}

require_command curl
require_command tar

if ! commit="$(curl -fsSL --connect-timeout 5 --max-time 10 \
    -H 'Accept: application/vnd.github.sha' -H 'Cache-Control: no-cache' \
    "https://api.github.com/repos/$GITHUB_REPO/commits/$GITHUB_BRANCH")" ||
    [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    printf "[x] Не удалось определить коммит установки на GitHub.\n"
    exit 1
fi

tmp_dir="$(mktemp -d)"
archive="$tmp_dir/remnasuper.tar.gz"
src_root="$tmp_dir/source"

cleanup() {
    rm -rf -- "$tmp_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf "[>] Скачивание RemnaSuper...\n"
curl -fsSL --connect-timeout 10 --max-time 60 -o "$archive" \
    "https://codeload.github.com/$GITHUB_REPO/tar.gz/$commit"

mkdir -p "$src_root"
tar -xzf "$archive" -C "$src_root"
source_dirs=("$src_root"/*)
if (( ${#source_dirs[@]} != 1 )) || [[ ! -d "${source_dirs[0]}" ]]; then
    printf "[x] Не удалось определить каталог RemnaSuper в архиве.\n"
    exit 1
fi
APP_DIR="${source_dirs[0]}"

for module in config ui common update; do
    if [[ ! -s "$APP_DIR/lib/$module.sh" ]]; then
        printf "[x] В архиве нет обязательного файла lib/%s.sh.\n" "$module"
        exit 1
    fi
    source "$APP_DIR/lib/$module.sh"
done

step "Установка в $INSTALL_DIR..."
install_from_dir "$APP_DIR"

success "Установлено."
info "Запуск из любого места: rs"
