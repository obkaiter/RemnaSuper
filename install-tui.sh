#!/usr/bin/env bash
set -euo pipefail
umask 022

install_dir=/opt/RemnaSuper-tui
command_link=/usr/local/bin/rs-tui
link_target="$install_dir/current/bin/remnasuper-tui"
repository=obkaiter/RemnaSuper
branch="${REMNASUPER_BRANCH:-tui}"
checkout='' expected='' rollback=false

while (( $# )); do
    case "$1" in
        --local) checkout="${2:?Укажите путь к исходникам}"; shift ;;
        --expect-version) expected="${2:?Укажите версию}"; shift ;;
        --rollback) rollback=true ;;
        --help)
            printf '%s\n' 'Установка: sudo bash install-tui.sh [--local ПУТЬ | --rollback]'
            exit 0
            ;;
        *) printf '[x] Неизвестный параметр: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

[[ "$EUID" == 0 ]] || { printf '[x] Запустите установку от root.\n' >&2; exit 1; }
[[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,119}$ && "$branch" != *..* && "$branch" != */ ]] ||
    { printf '[x] Недопустимое имя ветки.\n' >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null || { printf '[x] Команда %s не найдена.\n' "$1" >&2; exit 1; }
}

secure_directory() {
    [[ ! -L "$1" && -d "$1" && "$(stat -c %u -- "$1")" == 0 ]] &&
        [[ "$(find "$1" -maxdepth 0 -perm /022 -printf x)" != x ]]
}

require_command flock
require_command python3
secure_directory /opt && secure_directory /usr/local/bin ||
    { printf '[x] Проверьте владельца и права /opt и /usr/local/bin.\n' >&2; exit 1; }
if [[ ! -e "$install_dir" && ! -L "$install_dir" ]]; then
    mkdir -- "$install_dir"
fi
secure_directory "$install_dir" ||
    { printf '[x] Небезопасный каталог %s.\n' "$install_dir" >&2; exit 1; }
exec {lock}<"$install_dir"
flock -n "$lock" || { printf '[x] Уже идёт установка RemnaSuper TUI.\n' >&2; exit 1; }

journal_lock=/run/lock/remnasuper-network-diagnostics.lock
[[ ! -L "$journal_lock" ]] || { printf '[x] Небезопасный файл блокировки диагностики.\n' >&2; exit 1; }
exec {diagnostics_lock}>>"$journal_lock"
flock -n "$diagnostics_lock" || { printf '[x] Активна парная диагностика.\n' >&2; exit 1; }

journal_dir=/var/lib/remnasuper/network-diagnostics/sessions
if [[ -d "$journal_dir" && -n "$(find "$journal_dir" -name journal.json -print -quit)" ]]; then
    printf '[x] Активна диагностика или ожидается очистка её ресурсов.\n' >&2
    exit 1
fi

if [[ -e "$command_link" || -L "$command_link" ]]; then
    [[ -L "$command_link" && "$(readlink -- "$command_link")" == "$link_target" ]] ||
        { printf '[x] Команда %s уже занята.\n' "$command_link" >&2; exit 1; }
fi

work="$(mktemp -d "$install_dir/stage.XXXXXXXX")"
release=''
active=false
cleanup() {
    rm -rf -- "$work"
    if [[ -n "$release" && "$active" == false &&
          "$(readlink -- "$install_dir/current")" != "${release##*/}" ]]; then
        rm -rf -- "$release"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

read_release() {
    local link="$1" target
    if [[ ! -e "$link" && ! -L "$link" ]]; then return 0; fi
    target="$(readlink -- "$link")" || return 1
    [[ "$target" =~ ^release[.][A-Za-z0-9]{8}$ ]] && secure_directory "$install_dir/$target" || return 1
    printf '%s\n' "$target"
}

current="$(read_release "$install_dir/current")" ||
    { printf '[x] Неизвестный формат действующей установки.\n' >&2; exit 1; }
previous="$(read_release "$install_dir/previous")" ||
    { printf '[x] Неизвестный формат предыдущей установки.\n' >&2; exit 1; }

activate() {
    local target="$1"
    ln -s -- "$target" "$work/current"
    if [[ -n "$current" ]]; then
        ln -s -- "$current" "$work/previous"
        mv -Tf -- "$work/previous" "$install_dir/previous"
    fi
    if [[ ! -L "$command_link" ]]; then
        ln -sT -- "$link_target" "$command_link"
    fi
    mv -Tf -- "$work/current" "$install_dir/current"
}

if "$rollback"; then
    [[ -n "$previous" && "$previous" != "$current" ]] ||
        { printf '[x] Предыдущего выпуска для возврата нет.\n' >&2; exit 1; }
    "$install_dir/$previous/bin/remnasuper-tui" --self-test
    activate "$previous"
    printf '[ok] Предыдущая версия снова доступна через rs-tui.\n'
    exit 0
fi

if [[ -z "$checkout" ]]; then
    require_command curl
    printf '[>] Загрузка исходников из %s, ветка %s.\n' "$repository" "$branch"
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 \
        --max-filesize 33554432 "https://codeload.github.com/$repository/tar.gz/refs/heads/$branch" -o "$work/source.tgz"
    mkdir "$work/source"
    checkout="$(python3 - "$work/source.tgz" "$work/source" <<'PY'
import sys
import tarfile
from pathlib import Path, PurePosixPath

with tarfile.open(sys.argv[1], "r:gz") as archive:
    members = archive.getmembers()
    roots = set()
    seen = set()
    total = 0
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts or path in seen:
            raise SystemExit("Небезопасный путь в архиве исходников.")
        if not member.isdir() and not member.isfile():
            raise SystemExit("Архив содержит ссылки или специальные файлы.")
        seen.add(path)
        roots.add(path.parts[0])
        total += member.size
        if total > 64 * 1024 * 1024 or len(seen) > 4096:
            raise SystemExit("Превышен предел размера архива.")
        member.mode = 0o755 if member.isdir() else 0o644
        member.uid = member.gid = 0
        member.uname = member.gname = ""
    if len(roots) != 1:
        raise SystemExit("Отсутствует единый каталог исходников.")
    archive.extractall(sys.argv[2], members=members, numeric_owner=False)
print(Path(sys.argv[2]) / roots.pop())
PY
)"
else
    checkout="$(realpath -e -- "$checkout")"
fi

for file in VERSION CMakeLists.txt src/main.cpp install-tui.sh lib/config.sh \
    lib/backend/{actions.json,bridge.sh,dispatch.py,tui_protocol.py,update-tui.sh} \
    lib/system/network_diagnostics/{agent,measure,protocol,report,safety}.py \
    haproxy/collector/{collector,database,haproxy_stats,reports}.py haproxy/systemd/haproxy-traffic.service; do
    [[ -s "$checkout/$file" && ! -L "$checkout/$file" ]] ||
        { printf '[x] Отсутствует обязательный файл %s.\n' "$file" >&2; exit 1; }
done
version="$(cat -- "$checkout/VERSION")"
[[ "$version" =~ ^[0-9]+([.][0-9]+)+$ && ( -z "$expected" || "$version" == "$expected" ) ]] ||
    { printf '[x] Версия в архиве не совпадает с ожидаемой.\n' >&2; exit 1; }

if ! command -v cmake >/dev/null || ! command -v c++ >/dev/null || ! command -v make >/dev/null ||
    ! command -v pkg-config >/dev/null ||
    ! pkg-config --exists ncursesw panelw menuw formw vterm || ! dpkg-query -W -f='${db:Status-Status}' nlohmann-json3-dev 2>/dev/null | grep -qx installed; then
    require_command apt-get
    printf '[>] Установка зависимостей сборки через APT.\n'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential cmake pkg-config libncurses-dev libvterm-dev nlohmann-json3-dev ncurses-term
fi

printf '[>] Сборка RemnaSuper TUI %s.\n' "$version"
cmake -S "$checkout" -B "$work/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$work/build" --parallel 2

release="$(mktemp -d "$install_dir/release.XXXXXXXX")"
chmod 755 -- "$release"
cmake --install "$work/build" --prefix "$release"
cp -R --no-preserve=mode,ownership -- "$checkout/lib" "$checkout/haproxy" "$release/"
install -m 0644 -- "$checkout/VERSION" "$release/VERSION"
install -m 0755 -- "$checkout/install-tui.sh" "$release/install-tui.sh"
printf '%s\n' "$branch" > "$release/BRANCH"
[[ "$("$release/bin/remnasuper-tui" --version)" == "$version" ]]
"$release/bin/remnasuper-tui" --self-test
activate "${release##*/}"
active=true
printf '[ok] RemnaSuper TUI %s установлен. Запуск: sudo rs-tui\n' "$version"
