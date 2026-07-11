#!/usr/bin/env bash

_remnasuper_load_logs_modules() {
    local module_dir
    module_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/logs"

    source "$module_dir/remnanode.sh"
    source "$module_dir/logrotate.sh"
    source "$module_dir/cleanup.sh"
}

_remnasuper_load_logs_modules
unset -f _remnasuper_load_logs_modules
