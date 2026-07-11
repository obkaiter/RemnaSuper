#!/usr/bin/env bash

_remnasuper_load_geofiles_core_modules() {
    local module_dir
    module_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

    source "$module_dir/downloads.sh"
    source "$module_dir/compose.sh"
    source "$module_dir/operations.sh"
}

_remnasuper_load_geofiles_core_modules
unset -f _remnasuper_load_geofiles_core_modules
