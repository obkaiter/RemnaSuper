#!/usr/bin/env bash

show_setup_menu() {
    clear
    show_brand "Первоначальная настройка"

    section "Проверка сервера"
    menu_item 1 "Node Precheck"

    section "Настройка VPS"
    menu_item 2 "Сгенерировать ssh-ключ и отключить вход по паролю"
    menu_item 3 "apt update && apt upgrade"
    menu_item 4 "Отключить IPv6"
    menu_item 5 "Установить fail2ban"
    menu_item 6 "Установить rkn-guard"

    section "Настройка ноды"
    menu_item 7 "Установить remnawave-reverse-proxy"
    menu_item 8 "Сменить порт взаимодействия с панелью"
    menu_item 9 "Установить сертификаты"
    menu_item 10 "Исправить логи (access.log, xray.out.log)"
    menu_item 11 "Заглушка: TLS 1.2, TLS 1.3 и HSTS"
    menu_item 12 "HTTP 301 на 80 порте"
    menu_item 13 "Установка/удаление geofiles"
    menu_item 14 "Управление Node Accelerator"

    section "Навигация"
    menu_back_item
    prompt_choice "0-14"
}

initial_setup_menu() {
    local choice

    while true; do
        show_setup_menu
        read -r choice
        case $choice in
            1) run_action "Node Precheck" \
                "Скрипт будет загружен с vpn-hub.pro и выполнен через Bash с правами root. Он считывает сведения об ОС, процессоре, памяти, диске, сетевых интерфейсах, открытых портах и firewall; публичный IP отправляется внешним сервисам для геолокации и проверок. Globalping проверит этот IP по ICMP и TCP/22 из сетей РФ. Тест скорости может скачать до 100 МБ с Cloudflare и до 100 МБ с Selectel, а также отправить до 25 МБ на Cloudflare. Постоянные файлы и настройки не изменяются; тест записи на диск по умолчанию выключен." \
                run_node_precheck ;;
            2) run_action "Сгенерировать ssh-ключ и отключить вход по паролю" \
                "Будет сохранена резервная копия sshd_config. Для выбранного пользователя будет создан ключ Ed25519. Открытый ключ будет добавлен в ~/.ssh/authorized_keys, а закрытый будет временно доступен этому пользователю для скачивания по SCP. После проверки входа с новым ключом программа отключит парольную и интерактивную аутентификацию для всех пользователей и перечитает настройки ssh.service. Пользователи, у которых есть только пароль, потеряют возможность заново подключиться. Оставьте текущий сеанс открытым до завершения." \
                configure_ssh_key_login ;;
            3) run_action "apt update && apt upgrade" \
                "Будут обновлены пакеты системы и установлены cron, mc и wget. После успешного обновления VPS автоматически перезагрузится; подключения прервутся." \
                initial_setup ;;
            4) run_action "Отключить IPv6" \
                "IPv6 будет отключён на существующих и новых сетевых интерфейсах сразу и после перезагрузки. Будет создан файл /etc/sysctl.d/zzzz-remnasuper-disable-ipv6.conf и применены системные параметры; открытый по IPv6 SSH-сеанс или другие IPv6-подключения могут прерваться. После этого сервер будет доступен по IPv4, если он настроен." \
                disable_ipv6 ;;
            5) run_action "Установка fail2ban" \
                "Будет установлен fail2ban, включена защита SSH с четырьмя попытками входа за 10 минут и блокировкой на один час, после чего сервис будет добавлен в автозапуск и запущен." \
                install_fail2ban ;;
            6) run_action "Установка rkn-guard" \
                "Будет загружен и запущен от root установщик rkn-guard из Flecksis/rkn-guard. Он установит необходимые пакеты, настроит фильтрацию адресов сканеров через iptables и ipset, логирование и systemd-службы; также будет предложено включить автообновление списков. Будут изменены сетевые правила сервера." \
                install_rkn_guard ;;
            7) run_action "Установка remnawave-reverse-proxy" \
                "Будет скачан и запущен официальный install_remnawave.sh из репозитория eGamesAPI/remnawave-reverse-proxy." \
                install_remnawave_reverse_proxy ;;
            8) run_action "Смена порта взаимодействия с панелью" \
                "В docker-compose.yml будет изменён порт NODE_PORT, а правило UFW для IP-адреса панели перенесено на новый порт. Если порт не указан, будет выбран свободный случайный порт. Затем нода будет перезапущена; подключения могут прерваться на 5–10 секунд." \
                change_node_port ;;
            9) run_action "Установить сертификаты" \
                "Домен сертификата будет найден в docker-compose.yml, файл будет сохранён в бэкап, сертификаты подключены к RemnaNode, после чего нода будет перезапущена." \
                install_remnanode_certificates ;;
            10) run_action "Исправить логи (access.log, xray.out.log)" \
                "Будут созданы access.log и error.log, каталог логов подключён к RemnaNode в docker-compose.yml, нода и агент перезапущены, затем будет предложена настройка ротации логов." \
                fix_logs ;;
            11) run_action "Заглушка: TLS 1.2, TLS 1.3 и HSTS" \
                "В каждый TLS server-блок с доменным server_name в /opt/remnanode/nginx.conf будет добавлен заголовок Strict-Transport-Security со сроком 1 год и includeSubDomains. Перед заменой файла будет создана резервная копия, конфигурация nginx будет проверена в контейнере, затем контейнеры RemnaNode будут перезапущены. Текущие подключения могут кратковременно прерваться." \
                enable_tls_hsts ;;
            12) run_action "HTTP 301 на 80 порте" \
                "HTTP 301 на 80 порту означает, что сервер отправляет постоянное перенаправление (Moved Permanently) для запросов, приходящих на стандартный незащищенный веб-порт 80 (обычно используемый для HTTP). Будет выполнено ufw allow 80/tcp, в /opt/remnanode/nginx.conf добавлен сервер для перенаправления на HTTPS и перезапущена нода. Текущие подключения могут кратковременно прерваться." \
                enable_http_redirect ;;
            13) geofiles_menu ;;
            14) node_accelerator_menu ;;
            0) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
