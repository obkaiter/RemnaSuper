#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
repository=obkaiter/RemnaSuper
branch="${REMNASUPER_BRANCH:-}"
if [[ -z "$branch" && -f "$app_dir/BRANCH" ]]; then
    read -r branch < "$app_dir/BRANCH"
fi
branch="${branch:-tui}"
[[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,119}$ && "$branch" != *..* && "$branch" != */ ]] ||
    { printf '[x] Недопустимое имя ветки.\n' >&2; exit 1; }

action="${1:---check}"
if [[ "${REMNASUPER_SKIP_UPDATE:-0}" == 1 && "$action" == --check ]]; then
    printf '%s\n' skipped
    exit 0
fi
if [[ ! "$app_dir" =~ ^/opt/RemnaSuper-tui/release[.][A-Za-z0-9]{8}$ ]]; then
    if [[ "$action" == --check ]]; then
        printf '%s\n' local
        exit 0
    fi
    printf '[x] Обновление доступно для установленной копии.\n' >&2
    exit 1
fi
if [[ "$action" == --apply && "$(realpath -- "$app_dir/../current")" != "$app_dir" ]]; then
    printf '[x] Уже запущена предыдущая редакция. Выйдите и запустите rs-tui.\n' >&2
    exit 1
fi

local_version="$(cat -- "$app_dir/VERSION")"
remote_version="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 10 \
    --max-filesize 128 "https://raw.githubusercontent.com/$repository/$branch/VERSION")"
[[ "$remote_version" =~ ^[0-9]+([.][0-9]+)+$ ]] ||
    { printf '[x] Получен некорректный VERSION.\n' >&2; exit 1; }
if [[ "$remote_version" != "$local_version" &&
      "$(printf '%s\n%s\n' "$local_version" "$remote_version" | sort -V | head -n 1)" == "$local_version" ]]; then
    case "$action" in
        --check) printf '%s\n' "$remote_version" ;;
        --apply) REMNASUPER_BRANCH="$branch" exec bash "$app_dir/install-tui.sh" --expect-version "$remote_version" ;;
        *) exit 2 ;;
    esac
elif [[ "$action" == --check ]]; then
    printf '%s\n' current
elif [[ "$action" == --apply ]]; then
    printf '[i] Доступная версия уже установлена.\n'
else
    exit 2
fi
