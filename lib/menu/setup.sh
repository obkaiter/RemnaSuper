#!/usr/bin/env bash

show_vps_setup_menu() {
    clear
    show_brand "Настройка VPS"

    menu_item 1 "Сгенерировать ssh-ключ и отключить вход по паролю"
    menu_item 2 "apt update && apt upgrade"
    menu_item 3 "Отключить IPv6"
    menu_item 4 "Установить fail2ban"
    menu_item 5 "Ограничить исходящий SMTP"

    menu_section "Навигация"
    menu_back_item
}

vps_setup_menu() {
    local choice

    while true; do
        select_menu choice 1 show_vps_setup_menu || return
        case $choice in
            1) run_action "Сгенерировать ssh-ключ и отключить вход по паролю" \
                "Будет сохранена резервная копия sshd_config. Для выбранного пользователя будет создан ключ Ed25519. Открытый ключ будет добавлен в ~/.ssh/authorized_keys, а закрытый будет временно доступен этому пользователю для скачивания по SCP. После проверки входа с новым ключом программа отключит парольную и интерактивную аутентификацию для всех пользователей и перечитает настройки ssh.service. Пользователи, у которых есть только пароль, потеряют возможность заново подключиться. Оставьте текущий сеанс открытым до завершения." \
                configure_ssh_key_login ;;
            2) run_action "apt update && apt upgrade" \
                "Будут обновлены пакеты системы и установлены cron, mc и wget. После успешного обновления VPS автоматически перезагрузится; подключения прервутся." \
                initial_setup ;;
            3) run_action "Отключить IPv6" \
                "Если есть правила IPv6 в UFW, RemnaSuper сохранит резервную копию /etc/ufw/user6.rules, удалит пользовательские правила и применит изменения при активном UFW с поддержкой IPv6. Затем создаст /etc/sysctl.d/zzzz-remnasuper-disable-ipv6.conf и отключит IPv6 сразу и после перезагрузки. SSH-сеансы и другие подключения по IPv6 могут оборваться." \
                disable_ipv6 ;;
            4) run_action "Установка fail2ban" \
                "Будет установлен fail2ban, включена защита SSH с четырьмя попытками входа за 10 минут и блокировкой на один час, после чего сервис будет добавлен в автозапуск и запущен." \
                install_fail2ban ;;
            5) smtp_egress_menu ;;
            0) return ;;
        esac
    done
}

show_node_setup_menu() {
    clear
    show_brand "Настройка Remnanode"

    menu_item 1 "Установить remnawave-reverse-proxy"
    menu_item 2 "Установить rkn-guard"
    menu_item 3 "Сменить порт взаимодействия с панелью"
    menu_item 4 "Подключить сертификаты в ноду"
    menu_item 5 "Исправить логи (access.log, xray.out.log)"
    menu_item 6 "Заглушка: TLS 1.2, TLS 1.3 и HSTS"
    menu_item 7 "Установка/удаление geofiles"
    menu_item 8 "Управление Node Accelerator"

    menu_section "Навигация"
    menu_back_item
}

node_setup_menu() {
    local choice

    while true; do
        select_menu choice 1 show_node_setup_menu || return
        case $choice in
            1) run_action "Установка remnawave-reverse-proxy" \
                "Будет скачан и запущен официальный install_remnawave.sh из репозитория eGamesAPI/remnawave-reverse-proxy." \
                install_remnawave_reverse_proxy ;;
            2) run_action "Установка rkn-guard" \
                "Будет загружен и запущен от root установщик rkn-guard из Flecksis/rkn-guard. Он установит необходимые пакеты, настроит фильтрацию адресов сканеров через iptables и ipset, логирование и systemd-службы; также будет предложено включить автообновление списков. Будут изменены сетевые правила сервера." \
                install_rkn_guard ;;
            3) run_action "Смена порта взаимодействия с панелью" \
                "В docker-compose.yml будет изменён порт NODE_PORT, а правило UFW для IP-адреса панели перенесено на новый порт. Если порт не указан, будет выбран свободный случайный порт. Затем нода будет перезапущена; подключения могут прерваться на 5–10 секунд." \
                change_node_port ;;
            4) run_action "Подключить сертификаты в ноду" \
                "Домен сертификата будет найден в docker-compose.yml, файл будет сохранён в бэкап, сертификаты подключены к RemnaNode, после чего нода будет перезапущена." \
                install_remnanode_certificates ;;
            5) run_action "Исправить логи (access.log, xray.out.log)" \
                "Будут созданы access.log и error.log, каталог логов подключён к RemnaNode в docker-compose.yml, нода и агент перезапущены, затем будет предложена настройка ротации логов. Стандартные профили после фактической ротации перезапускают работающий контейнер remnanode, чтобы Xray открыл новые файлы; активные подключения могут кратковременно прерваться." \
                fix_logs ;;
            6) run_action "Заглушка: TLS 1.2, TLS 1.3 и HSTS" \
                "В каждый TLS server-блок с доменным server_name в /opt/remnanode/nginx.conf будет добавлен заголовок Strict-Transport-Security со сроком 1 год и includeSubDomains. Перед заменой файла будет создана резервная копия, конфигурация nginx будет проверена в контейнере, затем контейнеры RemnaNode будут перезапущены. Текущие подключения могут кратковременно прерваться." \
                enable_tls_hsts ;;
            7) geofiles_menu ;;
            8) node_accelerator_menu ;;
            0) return ;;
        esac
    done
}
