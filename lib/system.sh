#!/usr/bin/env bash

_remnasuper_load_system_modules() {
    local module_dir
    module_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/system"

    source "$module_dir/services.sh"
    source "$module_dir/smtp_egress.sh"
    source "$module_dir/node_port.sh"
    source "$module_dir/provisioning.sh"
    source "$module_dir/relay_deploy.sh"
    source "$module_dir/relay.sh"
    source "$module_dir/relay_bandwidth.sh"
    source "$module_dir/relay_traffic.sh"
    source "$module_dir/relay_acme.sh"
    source "$module_dir/relay_site.sh"
    source "$module_dir/node_precheck.sh"
    source "$module_dir/ssh_keys.sh"
    source "$module_dir/dpi_detector.sh"
    source "$module_dir/xray.sh"
    source "$module_dir/tor.sh"
    source "$module_dir/warp.sh"
    source "$module_dir/psiphon.sh"
    source "$module_dir/zapret.sh"
    source "$module_dir/certificates.sh"
    source "$module_dir/ipv6.sh"
    source "$module_dir/tls_hsts.sh"
    source "$module_dir/session.sh"
    source "$module_dir/iperf3_ru.sh"
    source "$module_dir/cpu_steal.sh"
    source "$module_dir/uninstall.sh"
}

_remnasuper_load_system_modules
unset -f _remnasuper_load_system_modules
