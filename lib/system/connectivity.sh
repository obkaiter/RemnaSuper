#!/usr/bin/env bash

connectivity_seconds_to_ms() {
    awk -v seconds="${1:-0}" 'BEGIN { printf "%.0f", seconds * 1000 }'
}

connectivity_human_bytes() {
    awk -v bytes="${1:-0}" 'BEGIN {
        split("Б КБ МБ ГБ", units, " ")
        unit=1
        while (bytes >= 1024 && unit < 4) {
            bytes /= 1024
            unit++
        }
        if (unit == 1) printf "%.0f %s", bytes, units[unit]
        else printf "%.1f %s", bytes, units[unit]
    }'
}

connectivity_resolve() {
    local host="$1"
    local family="$2"

    if command -v getent >/dev/null 2>&1; then
        getent "ahosts${family}" "$host" 2>/dev/null |
            awk '$2 == "STREAM" && !seen[$1]++ { addresses[++count]=$1 }
                END {
                    for (i=1; i<=count && i<=3; i++) {
                        printf "%s%s", (i > 1 ? ", " : ""), addresses[i]
                    }
                }'
        return
    fi

    if command -v dig >/dev/null 2>&1; then
        if [ "$family" = "v4" ]; then
            dig +time=2 +tries=1 +short A "$host" 2>/dev/null
        else
            dig +time=2 +tries=1 +short AAAA "$host" 2>/dev/null
        fi | awk 'NF && !seen[$0]++ {
            addresses[++count]=$0
        }
        END {
            for (i=1; i<=count && i<=3; i++) {
                printf "%s%s", (i > 1 ? ", " : ""), addresses[i]
            }
        }'
    fi
}

connectivity_ping() {
    local host="$1"
    local output loss rtt

    if ! command -v ping >/dev/null 2>&1; then
        printf "не проверен (команда ping отсутствует)"
        return
    fi

    output="$(LC_ALL=C ping -4 -c 3 -W 2 "$host" 2>&1)"
    loss="$(printf '%s\n' "$output" | awk -F', ' '/packet loss/ {
        for (i=1; i<=NF; i++) if ($i ~ /packet loss/) { print $i; exit }
    }')"
    rtt="$(printf '%s\n' "$output" | awk -F' = ' '/^(rtt|round-trip)/ {
        split($2, values, "/")
        if (length(values) >= 4) printf "min/avg/max %.1f/%.1f/%.1f мс", values[1], values[2], values[3]
        exit
    }')"

    if [ -n "$rtt" ]; then
        printf "%s; %s" "$rtt" "${loss:-потери неизвестны}"
    elif [ -n "$loss" ]; then
        printf "%s; ответы не получены или ICMP заблокирован" "$loss"
    else
        printf "ошибка: %s" "$(printf '%s\n' "$output" | tail -n 1)"
    fi
}

connectivity_curl_error() {
    case "$1" in
        5|6)  printf "ошибка DNS" ;;
        7)    printf "TCP-соединение отклонено" ;;
        28)   printf "тайм-аут" ;;
        35)   printf "ошибка TLS" ;;
        47)   printf "слишком много перенаправлений" ;;
        52)   printf "пустой ответ сервера" ;;
        56)   printf "соединение было прервано" ;;
        60)   printf "ошибка проверки TLS-сертификата" ;;
        *)    printf "ошибка curl (код %s)" "$1" ;;
    esac
}

connectivity_check_service() {
    local name="$1"
    local url="$2"
    local host="$3"
    local ipv4 ipv6 ping_result error_file metrics curl_status error_text
    local http_code remote_ip remote_port local_ip local_port dns_time connect_time tls_time
    local ttfb_time total_time size_download speed_download effective_url ssl_result http_version
    local status status_color dns_ms tcp_ms tls_ms ttfb_ms total_ms

    printf "\n${BOLD}%s${NC} ${DIM}(%s)${NC}\n" "$name" "$host"

    ipv4="$(connectivity_resolve "$host" v4)"
    ipv6="$(connectivity_resolve "$host" v6)"
    printf "  DNS IPv4: %s\n" "${ipv4:-не найден}"
    printf "  DNS IPv6: %s\n" "${ipv6:-не найден}"

    ping_result="$(connectivity_ping "$host")"
    printf "  ICMP:     %s\n" "$ping_result"

    error_file="$(mktemp)" || {
        printf "  HTTP:     ${RED}не проверен${NC} — не удалось создать временный файл\n"
        CONNECTIVITY_FAILED=$((CONNECTIVITY_FAILED + 1))
        return
    }

    metrics="$(LC_ALL=C curl --silent --show-error --location --max-redirs 5 --noproxy '*' \
        --connect-timeout 5 --max-time 15 --output /dev/null \
        --user-agent "RemnaSuper connectivity checker/${REMNASUPER_VERSION:-unknown}" \
        --write-out '%{http_code}|%{remote_ip}|%{remote_port}|%{local_ip}|%{local_port}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{size_download}|%{speed_download}|%{url_effective}|%{ssl_verify_result}|%{http_version}' \
        "$url" 2>"$error_file")"
    curl_status=$?
    error_text="$(tr '\n' ' ' < "$error_file" | sed 's/[[:space:]]*$//')"
    rm -f "$error_file"

    if [ "$curl_status" -ne 0 ]; then
        printf "  HTTP:     ${RED}НЕДОСТУПЕН${NC} — %s" "$(connectivity_curl_error "$curl_status")"
        [ -n "$error_text" ] && printf ": %s" "$error_text"
        printf "\n"
        CONNECTIVITY_FAILED=$((CONNECTIVITY_FAILED + 1))
        return
    fi

    IFS='|' read -r http_code remote_ip remote_port local_ip local_port dns_time connect_time tls_time \
        ttfb_time total_time size_download speed_download effective_url ssl_result http_version <<< "$metrics"

    if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 400 ] 2>/dev/null; then
        status="ДОСТУПЕН"
        status_color="$GREEN"
        CONNECTIVITY_AVAILABLE=$((CONNECTIVITY_AVAILABLE + 1))
    else
        status="СЕРВЕР ОТВЕТИЛ"
        status_color="$YELLOW"
        CONNECTIVITY_LIMITED=$((CONNECTIVITY_LIMITED + 1))
    fi

    dns_ms="$(connectivity_seconds_to_ms "$dns_time")"
    connect_time="$(awk -v connect="$connect_time" -v dns="$dns_time" 'BEGIN { value=connect-dns; printf "%.6f", (value < 0 ? 0 : value) }')"
    tls_time="$(awk -v tls="$tls_time" -v connect="$dns_time" -v tcp="$connect_time" 'BEGIN {
        value=tls-connect-tcp
        printf "%.6f", (value < 0 ? 0 : value)
    }')"
    ttfb_time="$(awk -v ttfb="$ttfb_time" -v dns="$dns_time" -v tcp="$connect_time" -v tls="$tls_time" 'BEGIN {
        value=ttfb-dns-tcp-tls
        printf "%.6f", (value < 0 ? 0 : value)
    }')"
    tcp_ms="$(connectivity_seconds_to_ms "$connect_time")"
    tls_ms="$(connectivity_seconds_to_ms "$tls_time")"
    ttfb_ms="$(connectivity_seconds_to_ms "$ttfb_time")"
    total_ms="$(connectivity_seconds_to_ms "$total_time")"

    printf "  HTTP:     %b%s%b — код %s, HTTP/%s, TLS verify %s\n" \
        "$status_color" "$status" "$NC" "$http_code" "${http_version:-?}" "${ssl_result:-?}"
    printf "  Канал:    %s:%s → %s; получено %s, скорость %s/с\n" \
        "${local_ip:-?}" "${local_port:-?}" "${remote_ip:-?}:${remote_port:-443}" \
        "$(connectivity_human_bytes "$size_download")" "$(connectivity_human_bytes "$speed_download")"
    printf "  Задержки: DNS %s мс | TCP %s мс | TLS %s мс | TTFB %s мс | всего %s мс\n" \
        "$dns_ms" "$tcp_ms" "$tls_ms" "$ttfb_ms" "$total_ms"
    [ "$effective_url" != "$url" ] && printf "  URL:      %s\n" "$effective_url"
}

run_connectivity_check() {
    local resolver default_route proxy_configured="нет"

    header "Проверка доступности сервисов"
    check_command curl || { pause; return; }
    check_command awk || { pause; return; }
    check_command mktemp || { pause; return; }

    CONNECTIVITY_AVAILABLE=0
    CONNECTIVITY_LIMITED=0
    CONNECTIVITY_FAILED=0

    resolver="$(awk '/^[[:space:]]*nameserver[[:space:]]+/ { printf "%s%s", (found++ ? ", " : ""), $2 }' /etc/resolv.conf 2>/dev/null)"
    if command -v ip >/dev/null 2>&1; then
        default_route="$(ip -4 route show default 2>/dev/null | head -n 1)"
    fi
    if [ -n "${HTTPS_PROXY:-}${https_proxy:-}${ALL_PROXY:-}${all_proxy:-}" ]; then
        proxy_configured="настроен, но для проверки игнорируется"
    fi

    printf "Время:     %s\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf "Хост:      %s\n" "$(hostname 2>/dev/null || printf 'неизвестен')"
    printf "DNS:       %s\n" "${resolver:-не определён}"
    printf "HTTP proxy: %s\n" "$proxy_configured"
    [ -n "$default_route" ] && printf "Маршрут:   %s\n" "$default_route"

    connectivity_check_service "Discord"   "https://discord.com/"       "discord.com"
    connectivity_check_service "YouTube"   "https://www.youtube.com/"   "www.youtube.com"
    connectivity_check_service "Telegram"  "https://telegram.org/"      "telegram.org"
    connectivity_check_service "Instagram" "https://www.instagram.com/" "www.instagram.com"

    divider
    printf "Итог: ${GREEN}%s доступно${NC}, ${YELLOW}%s ответило с ошибкой HTTP${NC}, ${RED}%s недоступно${NC}.\n" \
        "$CONNECTIVITY_AVAILABLE" "$CONNECTIVITY_LIMITED" "$CONNECTIVITY_FAILED"
    info "ICMP проверяется отдельно: отсутствие ответа на ping не означает блокировку HTTPS."
    pause
}
