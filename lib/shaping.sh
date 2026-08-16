#!/usr/bin/env bash

_remnasuper_load_shaping_modules() {
    local module_dir
    module_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/shaping"

    source "$module_dir/engine.sh"
}

_remnasuper_load_shaping_modules
unset -f _remnasuper_load_shaping_modules
