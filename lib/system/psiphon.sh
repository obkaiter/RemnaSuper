#!/usr/bin/env bash

PSIPHON_INSTANCE="${PSIPHON_INSTANCE:-1}"
PSIPHON_OUTBOUND_TAG="psiphon-out"

set_psiphon_instance() {
    local instance="$1"

    if [[ ! "$instance" =~ ^([1-9]|[1-9][0-9])$ ]]; then
        error "Номер подключения Psiphon должен быть от 1 до 99."
        return 1
    fi

    PSIPHON_INSTANCE="$instance"
    if [ "$instance" = "1" ]; then
        PSIPHON_DIR="/opt/vps-psiphon"
        PSIPHON_ENV_FILE="/etc/default/vps-psiphon"
        PSIPHON_CLI="/usr/local/sbin/vps-psiphon"
        PSIPHON_SERVICE="vps-psiphon.service"
        PSIPHON_OUTBOUND_TAG="psiphon-out"
    else
        PSIPHON_DIR="/opt/vps-psiphon-$instance"
        PSIPHON_ENV_FILE="/etc/default/vps-psiphon-$instance"
        PSIPHON_CLI="/usr/local/sbin/vps-psiphon-$instance"
        PSIPHON_SERVICE="vps-psiphon-$instance.service"
        PSIPHON_OUTBOUND_TAG="psiphon-out-$instance"
    fi
    PSIPHON_OUTBOUND_FILE="$PSIPHON_DIR/xray-outbound.json"
}

psiphon_instance_exists() {
    local instance="$1"
    local saved_instance="$PSIPHON_INSTANCE"
    local result

    set_psiphon_instance "$instance" || return 1
    [ -e "$PSIPHON_ENV_FILE" ] || [ -x "$PSIPHON_CLI" ] ||
        [ -e "/etc/systemd/system/$PSIPHON_SERVICE" ] || [ -d "$PSIPHON_DIR" ]
    result=$?
    set_psiphon_instance "$saved_instance" || return 1
    return "$result"
}

list_psiphon_instances() {
    local instance
    for instance in $(seq 1 99); do
        if psiphon_instance_exists "$instance"; then
            printf '%s\n' "$instance"
        fi
    done
}

next_psiphon_instance() {
    local instance
    for instance in $(seq 1 99); do
        if ! psiphon_instance_exists "$instance"; then
            printf '%s\n' "$instance"
            return 0
        fi
    done
    return 1
}

set_psiphon_instance "${PSIPHON_INSTANCE:-1}"

read_psiphon_setting() {
    local key="$1"

    sed -n "s/^${key}=//p" "$PSIPHON_ENV_FILE" 2>/dev/null | head -n 1
}

write_psiphon_outbound() {
    local bind_address
    local socks_port
    local tmp_file
    local expected_dir="/opt/vps-psiphon"

    if [ ! -r "$PSIPHON_ENV_FILE" ]; then
        error "Конфигурация Psiphon не найдена: $PSIPHON_ENV_FILE"
        return 1
    fi
    [ "$PSIPHON_INSTANCE" = "1" ] || expected_dir="/opt/vps-psiphon-$PSIPHON_INSTANCE"
    if [ "$PSIPHON_DIR" != "$expected_dir" ]; then
        error "Обнаружен небезопасный путь для Xray outbound Psiphon."
        return 1
    fi

    bind_address="$(read_psiphon_setting BIND)"
    socks_port="$(read_psiphon_setting SOCKS_PORT)"

    if [[ ! "$bind_address" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        error "В $PSIPHON_ENV_FILE указан некорректный адрес SOCKS5: ${bind_address:-пусто}"
        return 1
    fi
    if [[ ! "$socks_port" =~ ^[0-9]+$ ]] ||
        [ "$socks_port" -lt 1 ] || [ "$socks_port" -gt 65535 ]; then
        error "В $PSIPHON_ENV_FILE указан некорректный порт SOCKS5: ${socks_port:-пусто}"
        return 1
    fi

    tmp_file="$(mktemp "$PSIPHON_DIR/.xray-outbound.XXXXXX")" || return 1
    if ! cat > "$tmp_file" << EOF
{
  "tag": "$PSIPHON_OUTBOUND_TAG",
  "protocol": "socks",
  "settings": {
    "address": "$bind_address",
    "port": $socks_port
  }
}
EOF
    then
        rm -f -- "$tmp_file"
        return 1
    fi

    chmod 644 "$tmp_file" || {
        rm -f -- "$tmp_file"
        return 1
    }
    mv "$tmp_file" "$PSIPHON_OUTBOUND_FILE"
}

psiphon_exit_ip() {
    local bind_address
    local socks_port

    bind_address="$(read_psiphon_setting BIND)"
    socks_port="$(read_psiphon_setting SOCKS_PORT)"
    [ -n "$bind_address" ] && [ -n "$socks_port" ] || return 1

    curl -4 --socks5-hostname "${bind_address}:${socks_port}" \
        --connect-timeout 10 --max-time 30 -fsS https://api.ipify.org 2>/dev/null
}

run_psiphon_cli() {
    local command="$1"
    shift

    if [ ! -x "$PSIPHON_CLI" ]; then
        error "Psiphon не установлен: команда не найдена: $PSIPHON_CLI"
        return 1
    fi

    "$PSIPHON_CLI" "$command" "$@"
}

normalize_psiphon_region_list() {
    local input="${1^^}"
    local region
    local normalized=""

    input="${input//,/ }"
    for region in $input; do
        normalized="${normalized:+$normalized }$region"
    done
    printf "%s\n" "$normalized"
}

psiphon_region_is_supported() {
    local region="$1"

    case " $PSIPHON_SUPPORTED_REGIONS " in
        *" $region "*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_psiphon_region_pool() {
    local regions="$1"
    local region

    for region in $regions; do
        if ! psiphon_region_is_supported "$region"; then
            error "Регион '$region' не поддерживается Psiphon."
            return 1
        fi
    done
}

validate_psiphon_accept_regions() {
    local regions="$1"
    local region

    [ -z "$regions" ] && return 0
    [ "$regions" = "ANY" ] && return 0

    for region in $regions; do
        if [[ ! "$region" =~ ^[A-Z]{2}$ ]]; then
            error "Некорректный код региона: '$region'. Используйте двухбуквенные ISO-коды."
            return 1
        fi
    done
}

install_psiphon() {
    header "Установка Psiphon"
    local tmp_dir
    local installer
    local exit_code
    local exit_ip

    check_command curl || { pause; return; }
    check_command bash || { pause; return; }
    check_command mktemp || { pause; return; }
    check_command systemctl || { pause; return; }
    check_docker || { pause; return; }

    if ! docker info >/dev/null 2>&1; then
        error "Docker daemon не запущен или недоступен."
        pause
        return
    fi

    if ! tmp_dir="$(mktemp -d)"; then
        error "Не удалось создать временный каталог для установщика Psiphon."
        pause
        return
    fi
    installer="$tmp_dir/psiphon_install.sh"

    step "Скачивание актуального установщика Psiphon..."
    if ! curl -fsSL --connect-timeout 10 --max-time 60 \
        -o "$installer" "$PSIPHON_INSTALLER_URL"; then
        error "Не удалось скачать установщик Psiphon."
        rm -f -- "$installer"
        rmdir "$tmp_dir" 2>/dev/null || true
        pause
        return
    fi

    if ! head -n 1 "$installer" | grep -qx '#!/usr/bin/env bash' ||
        ! grep -Fq 'CONF_DIR="/opt/$P/config"' "$installer" ||
        ! grep -Fq 'vps-psiphon.service' "$installer" ||
        ! grep -Fq 'uninstall)' "$installer"; then
        error "Загруженный файл не похож на ожидаемый установщик vps-psiphon."
        rm -f -- "$installer"
        rmdir "$tmp_dir" 2>/dev/null || true
        pause
        return
    fi

    step "Запуск установщика Psiphon №$PSIPHON_INSTANCE без публикации HTTP-прокси..."
    if [ "$PSIPHON_INSTANCE" = "1" ]; then
        bash "$installer" --no-http
    else
        bash "$installer" --no-http --instance "$PSIPHON_INSTANCE"
    fi
    exit_code=$?

    rm -f -- "$installer"
    rmdir "$tmp_dir" 2>/dev/null || true

    if [ "$exit_code" -ne 0 ]; then
        error "Установка Psiphon завершилась с ошибкой. Код: $exit_code"
        pause
        return
    fi
    if ! systemctl is-active --quiet "$PSIPHON_SERVICE"; then
        error "Установщик завершился, но сервис $PSIPHON_SERVICE не запущен."
        pause
        return
    fi
    if ! write_psiphon_outbound; then
        error "Psiphon установлен, но не удалось сохранить Xray outbound."
        pause
        return
    fi

    exit_ip="$(psiphon_exit_ip || true)"
    if [ -n "$exit_ip" ]; then
        success "Подключение Psiphon №$PSIPHON_INSTANCE установлено; выходной IP: $exit_ip."
    else
        warn "Psiphon установлен, но выходной IP пока не удалось проверить."
        info "Состояние туннеля можно проверить командой: $PSIPHON_CLI status"
    fi
    info "Xray outbound: $PSIPHON_OUTBOUND_FILE"
    section "Готовый outbound для Xray"
    cat "$PSIPHON_OUTBOUND_FILE"
    printf "\n"
    pause
}

show_psiphon_status() {
    header "Состояние Psiphon"

    if ! run_psiphon_cli status; then
        error "Не удалось получить состояние Psiphon."
    fi
    pause
}

rotate_psiphon() {
    header "Ротация туннеля Psiphon"

    step "Перезапуск туннеля и выбор нового выхода..."
    if run_psiphon_cli rotate; then
        success "Ротация Psiphon завершена."
    else
        error "Не удалось выполнить ротацию Psiphon."
    fi
    pause
}

set_psiphon_region() {
    header "Выбор региона Psiphon"
    local region
    local cli_region

    if [ ! -x "$PSIPHON_CLI" ]; then
        error "Psiphon не установлен: команда не найдена: $PSIPHON_CLI"
        pause
        return
    fi

    info "Доступные регионы: $PSIPHON_SUPPORTED_REGIONS"
    printf "Введите код региона или auto для автоматического выбора: "
    read -r region
    region="$(normalize_psiphon_region_list "$region")"

    if [ "$region" != "AUTO" ] && ! psiphon_region_is_supported "$region"; then
        error "Регион '${region:-пусто}' не поддерживается Psiphon."
        pause
        return
    fi

    if [ "$region" = "AUTO" ]; then
        cli_region="auto"
    else
        cli_region="$region"
    fi

    step "Применение региона $cli_region и переподключение туннеля..."
    if run_psiphon_cli region "$cli_region"; then
        success "Регион Psiphon изменён."
    else
        error "Не удалось изменить регион Psiphon."
    fi
    pause
}

set_psiphon_region_pool() {
    header "Пул регионов Psiphon"
    local input
    local regions

    if [ ! -x "$PSIPHON_CLI" ]; then
        error "Psiphon не установлен: команда не найдена: $PSIPHON_CLI"
        pause
        return
    fi

    info "Доступные регионы: $PSIPHON_SUPPORTED_REGIONS"
    info "При каждой ротации будет выбран следующий регион из пула."
    printf "Введите коды через пробел или запятую; пустая строка очистит пул: "
    read -r input
    regions="$(normalize_psiphon_region_list "$input")"

    if ! validate_psiphon_region_pool "$regions"; then
        pause
        return
    fi

    if run_psiphon_cli pool "$regions"; then
        success "Пул регионов Psiphon обновлён."
    else
        error "Не удалось изменить пул регионов Psiphon."
    fi
    pause
}

set_psiphon_accept_regions() {
    header "Допустимые регионы Psiphon"
    local input
    local regions
    local cli_regions

    if [ ! -x "$PSIPHON_CLI" ]; then
        error "Psiphon не установлен: команда не найдена: $PSIPHON_CLI"
        pause
        return
    fi

    info "Это страны, которые watchdog допускает по оценке Google."
    info "Введите ISO-коды, any для любых стран или пустую строку для значений по умолчанию."
    printf "Допустимые регионы: "
    read -r input
    regions="$(normalize_psiphon_region_list "$input")"

    if ! validate_psiphon_accept_regions "$regions"; then
        pause
        return
    fi
    if [ "$regions" = "ANY" ]; then
        cli_regions="any"
    else
        cli_regions="$regions"
    fi

    if run_psiphon_cli accept "$cli_regions"; then
        success "Список допустимых регионов Psiphon обновлён."
    else
        error "Не удалось изменить допустимые регионы Psiphon."
    fi
    pause
}

test_psiphon_speed() {
    header "Проверка скорости Psiphon"

    if run_psiphon_cli speed; then
        success "Проверка скорости Psiphon завершена."
    else
        error "Проверка скорости Psiphon завершилась с ошибкой."
    fi
    pause
}

show_psiphon_client_logs() {
    header "Логи клиента Psiphon"
    local lines

    printf "Количество последних строк [50]: "
    read -r lines
    lines="${lines:-50}"
    if [[ ! "$lines" =~ ^[0-9]{1,5}$ ]] || [ "$lines" -lt 1 ] || [ "$lines" -gt 10000 ]; then
        error "Количество строк должно быть целым числом от 1 до 10000."
        pause
        return
    fi

    if ! run_psiphon_cli logs "$lines"; then
        error "Не удалось показать логи клиента Psiphon."
    fi
    pause
}

show_psiphon_watchdog_logs() {
    header "Логи watchdog Psiphon"
    local lines

    printf "Количество последних строк [30]: "
    read -r lines
    lines="${lines:-30}"
    if [[ ! "$lines" =~ ^[0-9]{1,5}$ ]] || [ "$lines" -lt 1 ] || [ "$lines" -gt 10000 ]; then
        error "Количество строк должно быть целым числом от 1 до 10000."
        pause
        return
    fi

    if ! run_psiphon_cli watchdog "$lines"; then
        error "Не удалось показать логи watchdog Psiphon."
    fi
    pause
}

show_psiphon_outbound() {
    header "Xray outbound для Psiphon"

    if [ -r "$PSIPHON_ENV_FILE" ]; then
        if ! write_psiphon_outbound; then
            error "Не удалось обновить Xray outbound из текущей конфигурации Psiphon."
            pause
            return
        fi
    elif [ ! -f "$PSIPHON_OUTBOUND_FILE" ]; then
        error "Outbound не найден. Сначала установите Psiphon через меню RemnaSuper."
        pause
        return
    fi

    info "Добавьте этот объект в массив outbounds конфигурации Xray:"
    printf "\n"
    cat "$PSIPHON_OUTBOUND_FILE"
    printf "\n"
    pause
}

uninstall_psiphon() {
    header "Удаление Psiphon"
    local exit_code
    local expected_dir="/opt/vps-psiphon"
    local expected_cli="/usr/local/sbin/vps-psiphon"

    if [ "$PSIPHON_INSTANCE" != "1" ]; then
        expected_dir="/opt/vps-psiphon-$PSIPHON_INSTANCE"
        expected_cli="/usr/local/sbin/vps-psiphon-$PSIPHON_INSTANCE"
    fi

    if [ "$PSIPHON_DIR" != "$expected_dir" ] ||
        [ "$PSIPHON_CLI" != "$expected_cli" ]; then
        error "Обнаружены небезопасные пути удаления Psiphon."
        pause
        return
    fi

    if [ ! -x "$PSIPHON_CLI" ]; then
        if [ -e "$PSIPHON_DIR" ] || [ -e "$PSIPHON_ENV_FILE" ]; then
            error "Установка Psiphon повреждена: штатная команда удаления не найдена: $PSIPHON_CLI"
        else
            warn "Psiphon не установлен."
        fi
        pause
        return
    fi

    step "Остановка сервисов и удаление Psiphon..."
    "$PSIPHON_CLI" uninstall
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        error "Удаление Psiphon завершилось с ошибкой. Код: $exit_code"
        pause
        return
    fi

    success "Подключение Psiphon №$PSIPHON_INSTANCE, его сервисы, контейнер, настройки и Xray outbound удалены."
    pause
}
