#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/lib/system/wireguard.sh"

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
WG_IFACE=rswg0
WG_DIR="$test_dir/state"
WG_CONFIG="$test_dir/rswg0.conf"
WG_SUBNET=10.77.0
WG_PORT=51820
mkdir -p "$WG_DIR/peers"
printf 'SERVER_PRIVATE\n' > "$WG_DIR/server.key"
printf 'SERVER_PUBLIC\n' > "$WG_DIR/server.pub"
printf 'eth0\n' > "$WG_DIR/wan-interface"
printf '[Interface]\n' > "$WG_CONFIG"

error() { :; }
success() { :; }
section() { :; }
info() { :; }
warn() { :; }
systemctl() {
    if [ -f "$test_dir/fail-start" ] && [ "$*" = 'enable --now wg-quick@rswg0' ]; then return 1; fi
    return 0
}
wg-quick() {
    [ "$1" = strip ] || return 1
    cat "$2"
}
wg() {
    case "$1" in
        genkey) printf 'PRIVATE_%s\n' "${next_key:-one}" ;;
        pubkey) read -r key; printf 'PUBLIC_%s\n' "$key" ;;
        syncconf)
            [ ! -f "$test_dir/fail-sync" ] || return 1
            cp "$3" "$test_dir/live.conf" ;;
        show) printf 'PUBLIC_PRIVATE_one\t(none)\t(none)\t10.77.0.2/32\t0\t0\t0\t25\n' ;;
        *) return 1 ;;
    esac
}

wg_create_peer alpha exit.example >/dev/null
[ "$(wg_peer_address alpha)" = 10.77.0.2 ]
grep -Fq 'AllowedIPs = 10.77.0.2/32' "$WG_CONFIG"
grep -Fq 'Endpoint = exit.example:51820' "$WG_DIR/peers/alpha.conf"
next_key=two wg_create_peer beta exit.example >/dev/null
[ "$(wg_peer_address beta)" = 10.77.0.3 ]
wg_set_peer_enabled alpha 0 >/dev/null
! grep -Fq 'PUBLIC_PRIVATE_one' "$WG_CONFIG"
wg_set_peer_enabled alpha 1 >/dev/null
grep -Fq 'PUBLIC_PRIVATE_one' "$WG_CONFIG"

touch "$test_dir/fail-sync"
if wg_delete_peer alpha; then exit 1; fi
[ -f "$WG_DIR/peers/alpha.conf" ]
grep -Fq 'PUBLIC_PRIVATE_one' "$WG_CONFIG"
rm -f "$test_dir/fail-sync"
wg_delete_peer alpha >/dev/null
[ ! -f "$WG_DIR/peers/alpha.conf" ]
! grep -Fq 'PUBLIC_PRIVATE_one' "$WG_CONFIG"
grep -Fq 'PUBLIC_PRIVATE_two' "$WG_CONFIG"

WG_DIR="$test_dir/new-state"
WG_CONFIG="$test_dir/new-wg/rswg0.conf"
WG_SYSCTL="$test_dir/new-sysctl.conf"
check_command() { return 0; }
ufw() {
    printf '%s\n' "$*" >> "$test_dir/ufw-calls"
    [ "$1" = status ] && printf 'Status: active\n'
    return 0
}
ss() { return 0; }
ip() {
    [ "$*" = '-4 route get 1.1.1.1' ] && printf '1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.2\n'
    return 0
}
sysctl() {
    [ "$1" = -n ] && printf '0\n'
    return 0
}
iptables() { return 0; }
touch "$test_dir/fail-start"
if wg_setup_server; then exit 1; fi
[ ! -e "$WG_CONFIG" ]
[ ! -e "$WG_SYSCTL" ]
rm -f "$test_dir/fail-start"
wg_setup_server >/dev/null
grep -Fq 'ListenPort = 51820' "$WG_CONFIG"
grep -Fq 'PostUp = iptables -t nat' "$WG_CONFIG"
grep -Fq 'route allow in on rswg0 out on eth0 from 10.77.0.0/24 comment RemnaSuper WireGuard transit' "$test_dir/ufw-calls"
wg_remove_server >/dev/null
[ ! -e "$WG_CONFIG" ]
[ ! -e "$WG_DIR" ]
printf 'WireGuard flow test passed\n'
