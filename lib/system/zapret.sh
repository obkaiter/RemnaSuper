#!/usr/bin/env bash

_remnasuper_load_zapret_modules() {
    local module_dir
    module_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/zapret"

    source "$module_dir/install.sh"
    source "$module_dir/runtime.sh"
    source "$module_dir/strategy.sh"
    source "$module_dir/uninstall.sh"
}

_remnasuper_load_zapret_modules
unset -f _remnasuper_load_zapret_modules
