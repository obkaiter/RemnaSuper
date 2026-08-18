#!/usr/bin/env bash

REMNASUPER_NAME="RemnaSuper"
REMNASUPER_APP_DIR="${APP_DIR:-/opt/RemnaSuper}"
if [ -f "$REMNASUPER_APP_DIR/VERSION" ]; then
    REMNASUPER_VERSION="$(tr -d '[:space:]' < "$REMNASUPER_APP_DIR/VERSION")"
else
    REMNASUPER_VERSION="0.0.0"
fi

INSTALL_DIR="/opt/RemnaSuper"
COMMAND_LINK="/usr/local/bin/rs"
GITHUB_REPO="SP1K33/RemnaSuper"
GITHUB_BRANCH="${REMNASUPER_BRANCH:-main}"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"
GITHUB_TARBALL_URL="https://codeload.github.com/${GITHUB_REPO}/tar.gz/refs/heads/${GITHUB_BRANCH}"

NODE_DIR="/opt/remnanode"
AGENT_DIR="/opt/remnawave-node-agent"
GEOFILES_DIR="/opt/remnanode/geofiles"
LOG_DIR="/var/log/remnanode"
COMPOSE_FILE="$NODE_DIR/docker-compose.yml"
ROTATE_CONF="/etc/logrotate.d/remnanode"
ZAPRET_DIR="/opt/ss-zapret2"
ZAPRET_LEGACY_DIR="/opt/ss-zapret"
ZAPRET_REPO="https://github.com/vernette/ss-zapret2.git"
ZAPRET_SERVICE="ss-zapret2"
ZAPRET_CONTAINER="zapret2-proxy"
ZAPRET_CONTAINER_DIR="/opt/zapret2"
ZAPRET_OUTBOUND_FILE="$ZAPRET_DIR/xray-outbound.json"

TOR_DIR="/opt/remnasuper-tor"
TOR_CONFIG_DIR="/etc/tor/torrc.d"
TOR_CONFIG_FILE="$TOR_CONFIG_DIR/remnasuper.conf"
TOR_MAIN_CONFIG="/etc/tor/torrc"
TOR_OUTBOUND_FILE="$TOR_DIR/xray-outbound.json"
TOR_PACKAGE_MARKER="$TOR_DIR/packages-installed-by-remnasuper"
TOR_COOKIE_FILE="/run/tor/control.authcookie"
TOR_SOCKS_PORT=9050
TOR_CONTROL_PORT=9051
