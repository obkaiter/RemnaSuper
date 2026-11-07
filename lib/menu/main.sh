#!/usr/bin/env bash

show_menu() {
    clear
    show_brand "Главное меню"

    section "Первоначальная настройка"
    menu_item 1 "apt update && apt upgrade"
    menu_item 2 "Установить remnawave-reverse-proxy"
    menu_item 3 "Установить rkn-guard"
    menu_item 4 "Установить сертификаты в RemnaNode"
    menu_item 5 "HTTP 301 на 80 порте"
    menu_item 6 "Управление Node Accelerator"
    menu_item 7 "Установить fail2ban"
    menu_item 8 "Исправить логи в RemnaNode"
    menu_item 9 "Установка/удаление geofiles"
    menu_item 10 "Сменить порт взаимодействия с панелью"

    section "Управление"
    menu_item 11 "Управление ss-zapret2"
    menu_item 12 "Управление Tor"
    menu_item 13 "Управление Psiphon"
    menu_item 14 "Проверить доступность сервисов"
    menu_item 15 "Перезапустить ноду"
    menu_item 16 "Перезапустить агента"

    section "Диагностика"
    menu_item 17 "Запустить ipregion"
    menu_item 18 "IP Check Place"
    menu_item 19 "Проверка скорости канала (bench.sh)"
    menu_item 20 "Просмотр ошибок Xray"
    menu_item 21 "Просмотр логов Xray"
    menu_item 22 "Комплексная диагностика соединения между двумя VPS"

    section "Навигация"
    menu_exit_item
    prompt_choice "0-22"
}

main_menu() {
    local choice

    while true; do
        show_menu
        read -r choice
        case $choice in
            1) run_action "apt update && apt upgrade" \
                "Будут обновлены пакеты системы и установлены cron, mc и wget. После успешного обновления VPS автоматически перезагрузится; подключения прервутся." \
                initial_setup ;;
            2) run_action "Установка remnawave-reverse-proxy" \
                "Будет скачан и запущен официальный install_remnawave.sh из репозитория eGamesAPI/remnawave-reverse-proxy." \
                install_remnawave_reverse_proxy ;;
            3) run_action "Установка rkn-guard" \
                "Будет загружен и запущен от root установщик rkn-guard из Flecksis/rkn-guard. Он установит необходимые пакеты, настроит фильтрацию адресов сканеров через iptables и ipset, логирование и systemd-службы; также будет предложено включить автообновление списков. Будут изменены сетевые правила сервера." \
                install_rkn_guard ;;
            4) run_action "Установка сертификатов в RemnaNode" \
                "Домен сертификата будет найден в docker-compose.yml, файл будет сохранён в бэкап, сертификаты подключены к RemnaNode, после чего нода будет перезапущена." \
                install_remnanode_certificates ;;
            5) run_action "HTTP 301 на 80 порте" \
                "HTTP 301 на 80 порту означает, что сервер отправляет постоянное перенаправление (Moved Permanently) для запросов, приходящих на стандартный незащищенный веб-порт 80 (обычно используемый для HTTP). Будет выполнено ufw allow 80/tcp, в /opt/remnanode/nginx.conf добавлен сервер для перенаправления на HTTPS и перезапущена нода. Текущие подключения могут кратковременно прерваться." \
                enable_http_redirect ;;
            6) node_accelerator_menu ;;
            7) run_action "Установка fail2ban" \
                "Будет установлен fail2ban, включена защита SSH с четырьмя попытками входа за 10 минут и блокировкой на один час, после чего сервис будет добавлен в автозапуск и запущен." \
                install_fail2ban ;;
            8) run_action "Исправление логов RemnaNode" \
                "Будут созданы access.log и error.log, каталог логов подключён к RemnaNode в docker-compose.yml, нода и агент перезапущены, затем будет предложена настройка ротации логов." \
                fix_logs ;;
            9) geofiles_menu ;;
            10) run_action "Смена порта взаимодействия с панелью" \
                "В docker-compose.yml будет изменён порт NODE_PORT, а правило UFW для IP-адреса панели перенесено на новый порт. Если порт не указан, будет выбран свободный случайный порт. Затем нода будет перезапущена; подключения могут прерваться на 5–10 секунд." \
                change_node_port ;;
            11) zapret_menu ;;
            12) tor_menu ;;
            13) psiphon_menu ;;
            14) run_action "Проверка доступности сервисов" \
                "Встроенная диагностика проверит Discord, YouTube, Telegram и Instagram: DNS-адреса, ICMP-пинг, HTTP-статус, конечный IP и задержки DNS/TCP/TLS/TTFB. Внешние скрипты и пакеты не скачиваются и не устанавливаются." \
                run_connectivity_check ;;
            15) run_action "Перезапуск ноды" \
                "Docker Compose перезапустит сервисы RemnaNode. Текущие подключения могут прерваться на 5-10 секунд." \
                restart_node ;;
            16) run_action "Перезапуск агента" \
                "Docker Compose перезапустит сервисы агента в /opt/remnawave/node-agent." \
                restart_agent ;;
            17) run_action "Запуск ipregion" \
                "Будет скачан и запущен скрипт ipregion из репозитория Davoyan/ipregion." \
                run_ipregion ;;
            18) run_action "IP Check Place" \
                "Будет скачан и запущен диагностический скрипт IP Check Place на английском языке." \
                run_ip_check_place ;;
            19) run_action "Проверка скорости канала (bench.sh)" \
                "Будет скачан и запущен скрипт bench.sh для проверки скорости канала." \
                run_bench ;;
            20) run_action "Просмотр ошибок Xray" \
                "Будет открыт непрерывный вывод /var/log/supervisor/xray.out.log из контейнера remnanode. Для выхода нажмите Ctrl+C." \
                view_errors ;;
            21) run_action "Просмотр логов Xray" \
                "Будет выполнена команда tail -f /var/log/remnanode/access.log. Для выхода нажмите Ctrl+C." \
                view_xray_logs ;;
            22) run_action "Парная диагностика двух VPS" \
                "Недостающие пакеты Python 3, iperf3, UFW и сетевых утилит будут предложены для отдельной постоянной установки через apt-get. UFW должен быть активен с входящей политикой deny: автоматически он не включается. Временно откроются адресные TCP/UDP-порты только для второй VPS; агент закроет собственные правила и слушатели, удалит тестовые файлы и сообщит, если очистка не удалась. Выбор готового профиля даёт ориентир 5, 15 или 30 минут без общего ограничения времени; средний и полный передают по 1 GiB файлами в каждую сторону, плюс TCP/UDP-трафик. Нагрузка может замедлить VPN и расходовать платный трафик. Отчёты сохраняются." \
                run_network_diagnostics ;;
            0) run_action "Выход" \
                "Работа RemnaSuper будет завершена." \
                exit_menu ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
