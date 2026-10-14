#!/usr/bin/env bash

wg_peer_name_valid() { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,31}$ ]]; }

wg_server_ready() {
    [ -f "$WG_DIR/server.key" ] && [ -f "$WG_DIR/server.pub" ] &&
        [ -f "$WG_DIR/wan-interface" ] && [ -f "$WG_CONFIG" ] && [ -d "$WG_DIR/peers" ]
}

wg_peer_names() {
    local file name
    [ -d "$WG_DIR/peers" ] || return 0
    for file in "$WG_DIR"/peers/*.conf; do
        [ -f "$file" ] || continue
        name="${file##*/}"
        name="${name%.conf}"
        wg_peer_name_valid "$name" && printf '%s\n' "$name"
    done
}

wg_peer_address() {
    sed -n 's/^Address = \([0-9.]*\)\/32$/\1/p' "$WG_DIR/peers/$1.conf" | head -n 1
}

wg_install() {
    if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
        success "WireGuard уже установлен."
        return 0
    fi
    check_command apt-get || return 1
    step "Установка WireGuard из репозиториев Debian/Ubuntu..."
    DEBIAN_FRONTEND=noninteractive apt-get update &&
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools || {
        error "Не удалось установить WireGuard."
        return 1
    }
    check_command wg && check_command wg-quick
}

wg_write_server_config() {
    local output="$1" name address public_key
    {
        printf '[Interface]\nAddress = %s.1/24\nListenPort = %s\nPrivateKey = %s\n' \
            "$WG_SUBNET" "$WG_PORT" "$(cat "$WG_DIR/server.key")"
        printf 'PostUp = iptables -t nat -C POSTROUTING -s %s.0/24 -o %s -j MASQUERADE || iptables -t nat -A POSTROUTING -s %s.0/24 -o %s -j MASQUERADE\n' \
            "$WG_SUBNET" "$(cat "$WG_DIR/wan-interface")" "$WG_SUBNET" "$(cat "$WG_DIR/wan-interface")"
        printf 'PostDown = iptables -t nat -D POSTROUTING -s %s.0/24 -o %s -j MASQUERADE || true\n' \
            "$WG_SUBNET" "$(cat "$WG_DIR/wan-interface")"
        while IFS= read -r name; do
            [ -f "$WG_DIR/peers/$name.disabled" ] && continue
            address="$(wg_peer_address "$name")"
            public_key="$(cat "$WG_DIR/peers/$name.pub")"
            printf '\n# RemnaSuper peer: %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' \
                "$name" "$public_key" "$address"
        done < <(wg_peer_names)
    } > "$output"
}

wg_apply_server_config() {
    local previous stripped
    if ! systemctl is-active --quiet "wg-quick@$WG_IFACE"; then
        error "Сервис wg-quick@$WG_IFACE не запущен. Сначала восстановите его работу."
        return 1
    fi
    previous="$(mktemp "${WG_CONFIG}.previous.XXXXXX")" || return 1
    stripped="$(mktemp "${WG_CONFIG}.stripped.XXXXXX")" || { rm -f "$previous"; return 1; }
    cp -p "$WG_CONFIG" "$previous" || { rm -f "$previous" "$stripped"; return 1; }
    if ! wg_write_server_config "$stripped" || ! mv -f "$stripped" "$WG_CONFIG"; then
        rm -f "$previous" "$stripped"
        return 1
    fi
    chmod 600 "$WG_CONFIG"
    if ! wg-quick strip "$WG_CONFIG" > "$stripped" ||
        ! wg syncconf "$WG_IFACE" "$stripped"; then
        mv -f "$previous" "$WG_CONFIG"
        wg-quick strip "$WG_CONFIG" > "$stripped" && wg syncconf "$WG_IFACE" "$stripped" || true
        rm -f "$stripped"
        return 1
    fi
    rm -f "$previous" "$stripped"
}

wg_setup_server() (
    local wan old_forward key status
    wg_server_ready && return 0
    [ ! -e "$WG_CONFIG" ] && [ ! -e "$WG_DIR" ] && [ ! -e "$WG_SYSCTL" ] || {
        error "Обнаружена неполная или сторонняя конфигурация WireGuard. Автоматическая перезапись запрещена."
        return 1
    }
    for key in wg wg-quick ufw ip iptables sysctl systemctl ss; do check_command "$key" || return 1; done
    status="$(LC_ALL=C ufw status)" || return 1
    [[ "$status" == Status:\ active* ]] || { error "Сначала включите UFW."; return 1; }
    if ss -H -lun | grep -Eq ":$WG_PORT([[:space:]]|$)"; then
        error "UDP-порт $WG_PORT уже используется."
        return 1
    fi
    if printf '%s\n' "$status" | grep -Eq "(^|[[:space:]])$WG_PORT/udp([[:space:]]|$)"; then
        error "В UFW уже есть правило для UDP $WG_PORT. Существующее правило не изменено."
        return 1
    fi
    [ -z "$(ip -4 route show "$WG_SUBNET.0/24")" ] || {
        error "Подсеть $WG_SUBNET.0/24 уже используется."
        return 1
    }
    wan="$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    [[ "$wan" =~ ^[a-zA-Z0-9_.-]+$ ]] || { error "Не удалось определить внешний интерфейс."; return 1; }
    old_forward="$(sysctl -n net.ipv4.ip_forward)" || return 1
    umask 077
    mkdir -p "$WG_DIR/peers" "${WG_CONFIG%/*}" || return 1
    chmod 700 "$WG_DIR" "$WG_DIR/peers"
    printf '%s\n' "$wan" > "$WG_DIR/wan-interface"
    if ! wg genkey > "$WG_DIR/server.key" ||
        ! wg pubkey < "$WG_DIR/server.key" > "$WG_DIR/server.pub" ||
        ! wg_write_server_config "$WG_CONFIG"; then
        error "Не удалось создать ключи или конфигурацию WireGuard."
        rm -f "$WG_CONFIG" "$WG_DIR/server.key" "$WG_DIR/server.pub" "$WG_DIR/wan-interface"
        rmdir "$WG_DIR/peers" "$WG_DIR" 2>/dev/null || true
        return 1
    fi
    chmod 600 "$WG_CONFIG" "$WG_DIR/server.key"
    if ! printf 'net.ipv4.ip_forward=1\n' > "$WG_SYSCTL" ||
        ! sysctl -w net.ipv4.ip_forward=1 >/dev/null ||
        ! ufw allow "$WG_PORT/udp" comment "RemnaSuper WireGuard $WG_IFACE" ||
        ! ufw route allow in on "$WG_IFACE" out on "$wan" from "$WG_SUBNET.0/24" comment "RemnaSuper WireGuard transit" ||
        ! systemctl enable --now "wg-quick@$WG_IFACE"; then
        error "Запуск WireGuard не удался; выполняется откат."
        systemctl disable --now "wg-quick@$WG_IFACE" >/dev/null 2>&1 || true
        iptables -t nat -D POSTROUTING -s "$WG_SUBNET.0/24" -o "$wan" -j MASQUERADE >/dev/null 2>&1 || true
        ufw --force delete route allow in on "$WG_IFACE" out on "$wan" from "$WG_SUBNET.0/24" >/dev/null 2>&1 || true
        ufw --force delete allow "$WG_PORT/udp" >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.ip_forward=$old_forward" >/dev/null 2>&1 || true
        rm -f "$WG_SYSCTL" "$WG_CONFIG" "$WG_DIR/server.key" "$WG_DIR/server.pub" "$WG_DIR/wan-interface"
        rmdir "$WG_DIR/peers" "$WG_DIR" 2>/dev/null || true
        return 1
    fi
    success "WireGuard слушает UDP $WG_PORT на $WG_IFACE; UFW и IPv4 NAT настроены."
)

wg_next_address() {
    local number file used
    for ((number=2; number<=254; number++)); do
        used=0
        for file in "$WG_DIR"/peers/*.conf; do
            [ -f "$file" ] || continue
            if grep -Fxq "Address = $WG_SUBNET.$number/32" "$file"; then used=1; break; fi
        done
        if [ "$used" -eq 0 ]; then
            printf '%s.%s\n' "$WG_SUBNET" "$number"
            return 0
        fi
    done
    return 1
}

wg_endpoint_valid() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ ]] && [[ "$1" != *..* ]]
}

wg_create_peer() (
    local name="$1" endpoint="$2" address private public file
    wg_peer_name_valid "$name" || { error "Имя: латинские буквы, цифры, _ и -, до 32 символов; первая — буква."; return 1; }
    wg_endpoint_valid "$endpoint" || { error "Укажите публичный IPv4 или DNS-имя сервера без порта."; return 1; }
    wg_server_ready || wg_setup_server || return 1
    [ ! -e "$WG_DIR/peers/$name.conf" ] || { error "Подключение $name уже существует."; return 1; }
    address="$(wg_next_address)" || { error "Адреса подсети WireGuard закончились."; return 1; }
    umask 077
    file="$WG_DIR/peers/$name.conf"
    private="$(wg genkey)" || return 1
    public="$(printf '%s\n' "$private" | wg pubkey)" || return 1
    if ! printf '%s\n' "$public" > "$WG_DIR/peers/$name.pub"; then
        rm -f "$WG_DIR/peers/$name.pub"
        return 1
    fi
    if ! cat > "$file" <<EOF
[Interface]
PrivateKey = $private
Address = $address/32
Table = off
MTU = 1420
PostUp = ip route replace default dev %i metric 10 table 20177
PostDown = ip route del default dev %i metric 10 table 20177 || true

[Peer]
PublicKey = $(cat "$WG_DIR/server.pub")
Endpoint = $endpoint:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    then
        rm -f "$file" "$WG_DIR/peers/$name.pub"
        return 1
    fi
    chmod 600 "$file" "$WG_DIR/peers/$name.pub"
    if ! wg_apply_server_config; then
        rm -f "$file" "$WG_DIR/peers/$name.pub"
        error "Не удалось применить новое подключение; изменения отменены."
        return 1
    fi
    wg_show_peer "$name"
)

wg_show_peer() {
    local name="$1" address client_iface
    [ -f "$WG_DIR/peers/$name.conf" ] || { error "Подключение $name не найдено."; return 1; }
    address="$(wg_peer_address "$name")"
    client_iface="rswg${address##*.}"
    section "Конфигурация peer $name для другой VPS"
    cat "$WG_DIR/peers/$name.conf"
    section "Xray outbound для исходящей VPS"
    cat <<EOF
{
  "tag": "wg-$name",
  "protocol": "freedom",
  "settings": { "domainStrategy": "UseIPv4" },
  "streamSettings": { "sockopt": { "mark": 20177 } }
}
EOF
    info "На исходящей VPS установите WireGuard, сохраните конфиг как /etc/wireguard/$client_iface.conf (0600) и запустите wg-quick@$client_iface."
    info "Для policy routing на исходящей VPS:"
    printf 'ip route replace blackhole default metric 42767 table 20177\n'
    printf 'ip rule add fwmark 20177 lookup 20177 priority 20177\n'
    printf 'ip route replace default dev %s metric 10 table 20177\n' "$client_iface"
    warn "Сделайте blackhole и ip rule постоянными до запуска Xray; маршрут через интерфейс клиентский wg-quick добавляет сам. Иначе возможен выход через IP исходящей VPS."
    warn "Xray SO_MARK должен работать в том же network namespace, что и ip rule (например, RemnaNode с network_mode: host и CAP_NET_ADMIN)."
    warn "DNS и IPv6 этим IPv4-туннелем не перенаправляются. Проверьте их отдельно."
    info "Секретный конфиг peer: $WG_DIR/peers/$name.conf; адрес: $address. Передавайте только защищённым способом."
}

wg_set_peer_enabled() {
    local name="$1" enabled="$2" marker="$WG_DIR/peers/$1.disabled"
    [ -f "$WG_DIR/peers/$name.conf" ] || return 1
    if [ "$enabled" = 1 ]; then
        rm -f "$marker" || return 1
    else
        : > "$marker" || return 1
    fi
    if ! wg_apply_server_config; then
        if [ "$enabled" = 1 ]; then : > "$marker"; else rm -f "$marker"; fi
        return 1
    fi
    success "Подключение $name: $([ "$enabled" = 1 ] && printf 'включено' || printf 'отключено')."
}

wg_delete_peer() {
    local name="$1" backup
    [ -f "$WG_DIR/peers/$name.conf" ] || return 1
    backup="$(mktemp -d)" || return 1
    if ! cp -p "$WG_DIR/peers/$name.conf" "$WG_DIR/peers/$name.pub" "$backup/"; then
        rm -f "$backup/"*; rmdir "$backup"
        return 1
    fi
    [ ! -f "$WG_DIR/peers/$name.disabled" ] || cp -p "$WG_DIR/peers/$name.disabled" "$backup/" || return 1
    if ! rm -f "$WG_DIR/peers/$name.conf" "$WG_DIR/peers/$name.pub" "$WG_DIR/peers/$name.disabled"; then
        cp -p "$backup/"* "$WG_DIR/peers/"
        rm -f "$backup/"*; rmdir "$backup"
        return 1
    fi
    if ! wg_apply_server_config; then
        cp -p "$backup/"* "$WG_DIR/peers/"
        rm -f "$backup/"*; rmdir "$backup"
        return 1
    fi
    rm -f "$backup/"*; rmdir "$backup"
    success "Подключение $name удалено и отозвано на сервере."
}

wg_change_peer_endpoint() {
    local name="$1" endpoint="$2" tmp
    wg_endpoint_valid "$endpoint" || return 1
    tmp="$(mktemp "$WG_DIR/peers/.endpoint.XXXXXX")" || return 1
    if ! sed "s/^Endpoint = .*/Endpoint = $endpoint:$WG_PORT/" "$WG_DIR/peers/$name.conf" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$WG_DIR/peers/$name.conf"
    success "Адрес сервера обновлён в клиентском конфиге $name. Передайте новый файл на исходящую VPS."
}

wg_peer_status() {
    local name="$1" public latest now rx tx age state line
    public="$(cat "$WG_DIR/peers/$name.pub")"
    if [ -f "$WG_DIR/peers/$name.disabled" ]; then
        printf '%-32s %-15s %s\n' "$name" "$(wg_peer_address "$name")" "отключено"
        return
    fi
    line="$(wg show "$WG_IFACE" dump | awk -v key="$public" '$1==key {print $5, $6, $7}')"
    read -r latest rx tx <<< "$line"
    now="$(date +%s)"
    if [[ "$latest" =~ ^[0-9]+$ ]] && [ "$latest" -gt 0 ]; then
        age=$((now-latest))
        if [ "$age" -le 180 ]; then state="активно, handshake ${age} с назад"; else state="нет связи ${age} с"; fi
    else
        state="handshake ещё не было"
    fi
    printf '%-32s %-15s %s (RX %s, TX %s байт)\n' "$name" "$(wg_peer_address "$name")" "$state" "${rx:-0}" "${tx:-0}"
}

wg_restart_server() {
    wg_server_ready || { error "Сервер WireGuard от RemnaSuper не настроен."; return 1; }
    if ! systemctl restart "wg-quick@$WG_IFACE" ||
        ! systemctl is-active --quiet "wg-quick@$WG_IFACE"; then
        error "Не удалось запустить wg-quick@$WG_IFACE. Проверьте journalctl -u wg-quick@$WG_IFACE."
        return 1
    fi
    success "WireGuard перезапущен."
}

wg_remove_server() {
    local wan file
    wg_server_ready || { warn "Сервер WireGuard от RemnaSuper не найден."; return 0; }
    wan="$(cat "$WG_DIR/wan-interface")"
    [[ "$wan" =~ ^[a-zA-Z0-9_.-]+$ ]] || { error "Недостоверный внешний интерфейс в настройках."; return 1; }
    if ! systemctl disable --now "wg-quick@$WG_IFACE"; then
        error "Не удалось остановить сервис WireGuard. Файлы и UFW сохранены."
        return 1
    fi
    if ! ufw --force delete route allow in on "$WG_IFACE" out on "$wan" from "$WG_SUBNET.0/24"; then
        systemctl enable --now "wg-quick@$WG_IFACE" >/dev/null 2>&1 || true
        error "Не удалось удалить маршрутное правило UFW. Конфигурация сохранена."
        return 1
    fi
    if ! ufw --force delete allow "$WG_PORT/udp"; then
        ufw route allow in on "$WG_IFACE" out on "$wan" from "$WG_SUBNET.0/24" comment "RemnaSuper WireGuard transit" >/dev/null 2>&1 || true
        systemctl enable --now "wg-quick@$WG_IFACE" >/dev/null 2>&1 || true
        error "Не удалось удалить правило порта UFW. Конфигурация сохранена."
        return 1
    fi
    if ! rm -f -- "$WG_CONFIG" "$WG_SYSCTL" "$WG_DIR/server.key" "$WG_DIR/server.pub" "$WG_DIR/wan-interface"; then
        error "Не удалось удалить часть файлов WireGuard; проверьте $WG_DIR и $WG_CONFIG."
        return 1
    fi
    for file in "$WG_DIR"/peers/*.conf; do
        [ -f "$file" ] || continue
        rm -f -- "$file" "${file%.conf}.pub" "${file%.conf}.disabled"
    done
    rmdir "$WG_DIR/peers" "$WG_DIR" 2>/dev/null ||
        warn "В $WG_DIR остались неизвестные файлы; они сохранены."
    success "Сервер WireGuard и подключения RemnaSuper удалены."
    info "IPv4 forwarding в текущем ядре не отключён: его могут использовать другие сервисы."
}
