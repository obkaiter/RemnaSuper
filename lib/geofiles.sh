#!/usr/bin/env bash

_remnasuper_load_geofiles_modules() {
    local module_dir
    module_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/geofiles"

    source "$module_dir/core.sh"
    source "$module_dir/providers.sh"
}

_remnasuper_load_geofiles_modules
unset -f _remnasuper_load_geofiles_modules
