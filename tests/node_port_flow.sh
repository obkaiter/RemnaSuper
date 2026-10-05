#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/lib/system/node_port.sh"

test_dir="$(mktemp -d)"
trap 'rm -f "$test_dir"/*; rmdir "$test_dir"' EXIT
NODE_DIR="$test_dir"
COMPOSE_FILE="$NODE_DIR/docker-compose.yml"

cat > "$COMPOSE_FILE" <<'YAML'
services:
  remnanode:
    environment:
      - NODE_PORT=2222
YAML
touch "$test_dir/old-rule"

header() { :; }
step() { :; }
info() { :; }
warn() { :; }
success() { :; }
error() { :; }
pause() { :; }
check_docker() { return 0; }
check_command() { return 0; }
backup_compose() { cp -p "$COMPOSE_FILE" "$test_dir/backup.yml"; }
restart_remnanode_compose() {
    printf 'restart\n' >> "$test_dir/calls"
    if [ -f "$test_dir/fail-next-restart" ]; then
        rm -f "$test_dir/fail-next-restart"
        return 1
    fi
}

docker() {
    printf 'docker %s\n' "$*" >> "$test_dir/calls"
    case "$*" in
        'compose config') return 0 ;;
        'compose config --services') printf 'remnanode\n' ;;
        'compose ps --all --quiet remnanode')
            [ -f "$test_dir/container" ] && printf '0123456789ab\n'
            return 0 ;;
        *) return 1 ;;
    esac
}

ufw() {
    printf 'ufw %s\n' "$*" >> "$test_dir/calls"
    case "$*" in
        'status numbered')
            printf 'Status: active\n'
            [ ! -f "$test_dir/old-rule" ] || printf '[ 1] 2222/tcp ALLOW IN 138.124.32.28\n'
            [ ! -f "$test_dir/new-rule" ] || printf '[ 1] 59609/tcp ALLOW IN 138.124.32.28\n' ;;
        '--force delete 1') rm -f "$test_dir/old-rule" ;;
        'allow from 138.124.32.28 to any port 59609 proto tcp') touch "$test_dir/new-rule" ;;
        'allow from 138.124.32.28 to any port 2222 proto tcp') touch "$test_dir/old-rule" ;;
        '--force delete allow from 138.124.32.28 to any port 59609 proto tcp')
            rm -f "$test_dir/new-rule" ;;
        *) return 1 ;;
    esac
}

ss() {
    test "$*" = '-H -antu'
}

if change_node_port < /dev/null; then
    printf '%s\n' 'Missing container was accepted' >&2
    exit 1
fi
test -f "$test_dir/old-rule"
test ! -f "$test_dir/backup.yml"
if grep -q '^ufw ' "$test_dir/calls"; then
    printf '%s\n' 'UFW was checked before container presence' >&2
    exit 1
fi

touch "$test_dir/container"
printf '59609\n' | change_node_port
test -f "$test_dir/backup.yml"
test ! -f "$test_dir/old-rule"
test -f "$test_dir/new-rule"
test "$(_node_port_read_compose_value)" = 59609
test "$(grep -c '^restart$' "$test_dir/calls")" = 1
test "$(grep -c '^docker compose config$' "$test_dir/calls")" = 3

cp -p "$test_dir/backup.yml" "$COMPOSE_FILE"
touch "$test_dir/old-rule" "$test_dir/fail-next-restart"
rm -f "$test_dir/new-rule"
if printf '59609\n' | change_node_port; then
    printf '%s\n' 'Failed restart was accepted' >&2
    exit 1
fi
test "$(_node_port_read_compose_value)" = 2222
test -f "$test_dir/old-rule"
test ! -f "$test_dir/new-rule"
test "$(grep -c '^restart$' "$test_dir/calls")" = 3

ss_output=$'tcp ESTAB 0 0 10.0.0.1:49152 10.0.0.2:443\nudp UNCONN 0 0 0.0.0.0:51820 0.0.0.0:*'
ufw_status=$'Status: active\n[ 1] 49153/tcp ALLOW IN 138.124.32.28'
_node_port_is_in_use 49152 "$ss_output"
shuf() {
    local candidate
    for candidate in "$@"; do
        case "$candidate" in
            49152|49153|51820) return 1 ;;
        esac
    done
    printf '%s\n' "$2"
}
random_port="$(_node_port_choose_random 2222 "$ss_output" "$ufw_status")"
test "$random_port" -ge 49152
test "$random_port" -le 65535

printf '%s\n' 'node_port flow fixture: OK'
