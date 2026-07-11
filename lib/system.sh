#!/usr/bin/env bash

restart_node() {
    header "Перезапуск ноды"
    check_docker || { pause; return; }

    warn "Подключения прервутся примерно на 5-10 секунд."
    restart_remnanode_compose
    pause
}

restart_agent() {
    header "Перезапуск агента"
    check_docker || { pause; return; }

    if [ -d "$AGENT_DIR" ]; then
        if (cd "$AGENT_DIR" && docker compose restart >/dev/null 2>&1); then
            success "Агент перезапущен."
        else
            error "Ошибка при перезапуске агента."
        fi
    else
        error "Папка агента не найдена: $AGENT_DIR"
    fi
    pause
}

initial_setup() {
    header "Первоначальная настройка"
    check_command apt-get || { pause; return; }
    check_command sudo || { pause; return; }

    step "apt-get update..."
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get update; then
        error "apt-get update завершился с ошибкой."
        pause
        return
    fi

    step "apt-get upgrade..."
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -o com.ubuntu.ipt.needrestart=0; then
        error "apt-get upgrade завершился с ошибкой."
        pause
        return
    fi
    success "apt update && apt upgrade выполнены."

    step "Установка cron, mc и wget..."
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cron mc wget; then
        success "cron, mc и wget установлены."
    else
        error "Не удалось установить cron, mc и wget."
    fi

    pause
}

install_remnawave_reverse_proxy() {
    header "Установка remnawave-reverse-proxy"
    check_command curl || { pause; return; }
    check_command bash || { pause; return; }

    step "Запуск install_remnawave.sh..."
    if bash <(curl -Ls https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh); then
        success "remnawave-reverse-proxy установлен."
    else
        error "Установка remnawave-reverse-proxy завершилась с ошибкой."
    fi

    pause
}

follow_until_interrupt() {
    local interrupted=0
    local command_status

    trap 'interrupted=1' INT
    "$@"
    command_status=$?
    trap - INT

    if [ "$interrupted" -eq 1 ] || [ "$command_status" -gt 128 ]; then
        printf "\n"
        info "Просмотр остановлен."
    fi
    pause
}

view_errors() {
    header "Просмотр ошибок"
    check_docker || { pause; return; }

    follow_until_interrupt docker exec -it remnanode tail -n +1 -f /var/log/supervisor/xray.out.log
}

view_xray_logs() {
    header "Просмотр логов Xray"
    follow_until_interrupt tail -f /var/log/remnanode/access.log
}

install_zapret() {
    header "Установка zapret"
    check_command curl || { pause; return; }

    if sh -c "$(curl -fsSL https://raw.githubusercontent.com/Snowy-Fluffy/zapret.installer/refs/heads/main/installer.sh)"; then
        success "Установка zapret завершена."
    else
        error "Установка zapret завершилась с ошибкой."
    fi
    pause
}

install_tspu_checker() {
    header "Установка tspu checker"
    check_command apt || { pause; return; }
    check_command git || { pause; return; }
    check_command sudo || { pause; return; }

    sudo apt install -y hping3 nmap netcat-openbsd openssl dnsutils curl || {
        error "Не удалось установить зависимости tspu checker."
        pause
        return
    }
    cd /opt || { error "Не удалось перейти в /opt."; pause; return; }
    git clone https://github.com/ku78/tspu-checker.git || {
        error "Не удалось клонировать tspu-checker."
        pause
        return
    }
    cd tspu-checker || { error "Каталог /opt/tspu-checker не найден."; pause; return; }
    chmod +x tspu_check.sh
    sudo ./tspu_check.sh
    pause
}

install_remnanode_certificates() {
    header "Установка сертификатов в RemnaNode"
    local certificate_domains=()
    local domain
    local fullchain_volume
    local privkey_volume

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден."
        pause
        return
    fi

    mapfile -t certificate_domains < <(
        awk '
            /^services:[[:space:]]*$/ { in_services=1; next }
            in_services && /^[^[:space:]#][^:]*:/ { in_services=0 }
            in_services && /^  remnawave-nginx:[[:space:]]*$/ {
                in_nginx=1
                in_volumes=0
                next
            }
            in_nginx && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
                in_nginx=0
                in_volumes=0
            }
            in_nginx && /^    volumes:[[:space:]]*$/ {
                in_volumes=1
                next
            }
            in_volumes && /^    [A-Za-z0-9_.-]+:/ { in_volumes=0 }
            in_volumes {
                marker="/etc/letsencrypt/live/"
                start=index($0, marker)
                if (!start) {
                    next
                }

                path=substr($0, start + length(marker))
                slash=index(path, "/")
                if (!slash) {
                    next
                }

                domain=substr(path, 1, slash - 1)
                filename=substr(path, slash + 1)
                if (filename ~ /^(fullchain|privkey)\.pem:/ && !seen[domain]++) {
                    print domain
                }
            }
        ' "$COMPOSE_FILE"
    )

    if [ "${#certificate_domains[@]}" -eq 0 ]; then
        error "Не удалось найти сертификаты в volumes сервиса remnawave-nginx."
        pause
        return
    fi

    if [ "${#certificate_domains[@]}" -gt 1 ]; then
        error "В volumes сервиса remnawave-nginx найдены сертификаты нескольких доменов: ${certificate_domains[*]}"
        pause
        return
    fi

    domain="${certificate_domains[0]}"
    if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
        [[ "$domain" != *.* ]] || [[ "$domain" == *..* ]]; then
        error "В remnawave-nginx найдено некорректное доменное имя: $domain"
        pause
        return
    fi

    info "Домен найден в remnawave-nginx: $domain"
    fullchain_volume="/etc/letsencrypt/live/${domain}/fullchain.pem:/etc/nginx/ssl/${domain}/fullchain.pem:ro"
    privkey_volume="/etc/letsencrypt/live/${domain}/privkey.pem:/etc/nginx/ssl/${domain}/privkey.pem:ro"

    backup_compose
    # Новые записи добавляются сразу после volumes, поэтому добавляем их в обратном порядке.
    add_remnanode_volume "$privkey_volume" || { pause; return; }
    add_remnanode_volume "$fullchain_volume" || { pause; return; }

    restart_remnanode_compose
    pause
}

run_node_accelerator() {
    header "Выполнение Node Accelerator"
    check_command curl || { pause; return; }
    check_command sudo || { pause; return; }

    step "Запуск Node Accelerator..."
    curl -fsSL https://raw.githubusercontent.com/jestivald/node-accelerator/main/install.sh | sudo bash -s all

    local pipe_status=("${PIPESTATUS[@]}")
    local curl_exit="${pipe_status[0]}"
    local bash_exit="${pipe_status[1]}"
    if [ "$curl_exit" -eq 0 ] && [ "$bash_exit" -eq 0 ]; then
        success "Node Accelerator выполнен."
    else
        error "Node Accelerator завершился с ошибкой. curl: $curl_exit, bash: $bash_exit"
    fi

    pause
}

exit_menu() {
    header "Завершение"
    success "Готово."
    exit 0
}
