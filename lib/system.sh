#!/usr/bin/env bash

restart_node() {
    header "Перезапуск ноды"
    check_docker || { pause; return; }

    warn "Подключения прервутся примерно на 5-10 секунд."
    if confirm "Продолжить?"; then
        restart_remnanode_compose
    else
        info "Отменено."
    fi
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

restore_backup() {
    header "Восстановление из бэкапа"
    local backups=()
    local num

    mapfile -t backups < <(ls -t "${COMPOSE_FILE}.bak."* 2>/dev/null)
    if [ ${#backups[@]} -eq 0 ]; then
        warn "Бэкапы не найдены."
        pause
        return
    fi

    section "Доступные бэкапы"
    for i in "${!backups[@]}"; do
        menu_item "$((i + 1))" "${backups[$i]}"
    done
    menu_back_item
    prompt_choice "0-${#backups[@]}"
    read -r num

    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt 0 ] && [ "$num" -le "${#backups[@]}" ]; then
        warn "Восстановление: ${backups[$((num - 1))]}"
        if confirm "Подтвердить?"; then
            cp "${backups[$((num - 1))]}" "$COMPOSE_FILE"
            success "Восстановлено. Перезапустите ноду."
        fi
    elif [ "$num" = "0" ]; then
        info "Отменено."
    else
        warn "Неверный выбор."
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

view_errors() {
    header "Просмотр ошибок"
    check_docker || { pause; return; }

    docker exec -it remnanode tail -n +1 -f /var/log/supervisor/xray.out.log
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
