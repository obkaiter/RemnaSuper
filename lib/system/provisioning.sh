#!/usr/bin/env bash

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

install_fail2ban() {
    header "Установка fail2ban"
    check_command apt || { pause; return; }
    check_command systemctl || { pause; return; }

    step "Установка fail2ban..."
    if ! apt -y install fail2ban; then
        error "Не удалось установить fail2ban."
        pause
        return
    fi

    step "Настройка защиты SSH..."
    if ! cat >/etc/fail2ban/jail.d/local.conf <<'EOF'
[sshd]
enabled = true
maxretry = 4
bantime = 1h
findtime = 10m
EOF
    then
        error "Не удалось записать /etc/fail2ban/jail.d/local.conf."
        pause
        return
    fi

    step "Запуск fail2ban..."
    if systemctl enable --now fail2ban; then
        success "fail2ban установлен, настроен и запущен."
    else
        error "Не удалось включить и запустить fail2ban."
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

run_ipregion() {
    check_command wget || { pause; return; }
    check_command bash || { pause; return; }

    if ! bash <(wget -qO- https://github.com/Davoyan/ipregion/raw/main/ipregion.sh); then
        error "ipregion завершился с ошибкой."
    fi
    pause
}

run_ip_check_place() {
    check_command curl || { pause; return; }
    check_command bash || { pause; return; }

    if ! bash <(curl -Ls https://IP.Check.Place) -l en; then
        error "IP Check Place завершился с ошибкой."
    fi
    pause
}

run_bench() {
    check_command curl || { pause; return; }
    check_command bash || { pause; return; }

    if ! bash <(curl -Ls https://bench.sh); then
        error "bench.sh завершился с ошибкой."
    fi
    pause
}

run_node_accelerator() {
    local action="$1"
    local target="${2:-}"
    local installer_url="https://raw.githubusercontent.com/jestivald/node-accelerator/main/install.sh"
    local tmp_dir installer exit_code
    local restart_shaper=0

    header "Node Accelerator"
    check_command curl || { pause; return; }
    check_command bash || { pause; return; }
    check_command mktemp || { pause; return; }
    check_command sudo || { pause; return; }

    case "$action:$target" in
        optimize:|all:|rollback:optimize|rollback:all)
            if command -v shaper_service_active >/dev/null 2>&1 && shaper_service_active; then
                restart_shaper=1
            fi
            ;;
    esac

    if ! tmp_dir="$(mktemp -d)"; then
        error "Не удалось создать временный каталог для Node Accelerator."
        pause
        return
    fi
    installer="$tmp_dir/install.sh"

    step "Скачивание актуального установщика Node Accelerator..."
    if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$installer" "$installer_url"; then
        error "Не удалось скачать установщик Node Accelerator."
        rmdir "$tmp_dir" 2>/dev/null || true
        pause
        return
    fi

    step "Запуск команды: $action${target:+ $target}..."
    if [ -n "$target" ]; then
        sudo bash "$installer" "$action" "$target"
    else
        sudo bash "$installer" "$action"
    fi
    exit_code=$?

    rm -f "$installer"
    rmdir "$tmp_dir" 2>/dev/null || true

    if [ "$restart_shaper" -eq 1 ]; then
        step "Повторное применение fq/eBPF после сетевых настроек Node Accelerator..."
        if systemctl restart "$SHAPER_SERVICE_NAME"; then
            success "Шейпер трафика повторно применён."
        else
            warn "Node Accelerator завершён, но шейпер не перезапустился. Проверьте его журнал в меню."
        fi
    fi

    if [ "$exit_code" -eq 0 ]; then
        success "Команда Node Accelerator успешно выполнена."
    else
        error "Node Accelerator завершился с ошибкой. Код: $exit_code"
    fi

    pause
}
