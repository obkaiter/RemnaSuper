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
