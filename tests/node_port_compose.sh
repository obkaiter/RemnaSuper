#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/lib/system/node_port.sh"

test_dir="$(mktemp -d)"
trap 'rm -f "$test_dir/docker-compose.yml" "$test_dir/expected.yml" "$test_dir/result.yml"; rmdir "$test_dir"' EXIT
COMPOSE_FILE="$test_dir/docker-compose.yml"

cat > "$COMPOSE_FILE" <<'YAML'
x-logging: &logging
  logging:
    driver: json-file
x-common: &common
  image: remnawave/node:latest
services:
  remnanode:
    <<: [*common, *logging]
    environment:
      - NODE_PORT=2222
      - OTHER=ok
  remnawave-nginx:
    <<: [*common, *logging]
    environment:
      - OTHER=nginx
YAML

test "$(_node_port_read_compose_value)" = 2222
sed 's/NODE_PORT=2222/NODE_PORT=59609/' "$COMPOSE_FILE" > "$test_dir/expected.yml"
_node_port_write_compose_value 59609 "$test_dir/result.yml"
cmp "$test_dir/expected.yml" "$test_dir/result.yml"
COMPOSE_FILE="$test_dir/result.yml"
test "$(_node_port_read_compose_value)" = 59609

printf '%s\n' 'node_port Compose fixture: OK'
