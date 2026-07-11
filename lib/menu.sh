#!/usr/bin/env bash

_remnasuper_load_menu_modules() {
    local module_dir
    module_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/menu"

    source "$module_dir/actions.sh"
    source "$module_dir/zapret.sh"
    source "$module_dir/geofiles.sh"
    source "$module_dir/main.sh"
}

_remnasuper_load_menu_modules
unset -f _remnasuper_load_menu_modules
