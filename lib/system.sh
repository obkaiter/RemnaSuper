#!/usr/bin/env bash

_remnasuper_load_system_modules() {
    local module_dir
    module_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/system"

    source "$module_dir/services.sh"
    source "$module_dir/provisioning.sh"
    source "$module_dir/xray.sh"
    source "$module_dir/zapret.sh"
    source "$module_dir/certificates.sh"
    source "$module_dir/session.sh"
}

_remnasuper_load_system_modules
unset -f _remnasuper_load_system_modules
