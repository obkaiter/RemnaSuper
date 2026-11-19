#!/usr/bin/env bash

dpi_detector_install_dependencies() {
    local python="$1" dependency python_version
    local -a packages=() apt_options=(-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

    for dependency in curl:curl tar:tar gzip:gzip ps:procps; do
        check_command "${dependency%%:*}" >/dev/null || packages+=("${dependency#*:}")
    done
    if ! check_command timeout >/dev/null || ! check_command mktemp >/dev/null ||
        ! check_command rm >/dev/null; then
        packages+=(coreutils)
    fi
    if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
        packages+=(ca-certificates)
    fi

    if ! check_command "$python" >/dev/null; then
        packages+=(python3-venv)
    elif ! "$python" -E -c 'import ensurepip, venv; ensurepip.version()' >/dev/null 2>&1; then
        if ! python_version="$("$python" -E -c 'import sys; print("%d.%d" % sys.version_info[:2])')" ||
            [[ ! "$python_version" =~ ^3\.[0-9]+$ ]]; then
            error "Не удалось определить версию системного Python."
            return 1
        fi
        packages+=("python${python_version}-venv")
    fi

    (( ${#packages[@]} )) || return 0
    check_command apt-get || return 1

    step "Установка системных зависимостей DPI Detector: ${packages[*]}."
    if ! DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" update ||
        ! DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y \
            --no-install-recommends "${packages[@]}"; then
        error "Не удалось установить системные зависимости DPI Detector: ${packages[*]}."
        return 1
    fi
}

dpi_detector_session() (
    local python=/usr/bin/python3 tool work_dir script_status

    dpi_detector_install_dependencies "$python" || return 1
    for tool in curl tar gzip ps timeout mktemp rm "$python"; do
        check_command "$tool" || return 1
    done
    if ! "$python" -E -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
        error "Для зависимостей DPI Detector нужен системный Python версии 3.9 или новее."
        return 1
    fi

    work_dir="$(mktemp -d /tmp/remnasuper-dpi.XXXXXXXXXX)" || {
        error "Не удалось создать временный каталог для DPI Detector."
        return 1
    }
    trap 'rm -rf -- "${work_dir:?}"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    cd -- "$work_dir" || return 1

    step "Скачивание DPI Detector"
    if ! curl -fsSL --connect-timeout 10 --max-time 60 --output source.tar.gz "$DPI_DETECTOR_URL"; then
        error "Не удалось скачать DPI Detector."
        return 1
    fi
    if ! tar -xzf source.tar.gz --strip-components=1 ||
        [[ ! -s dpi_detector.py || ! -s requirements.txt || ! -s config.yml ||
           ! -s domains.txt || ! -s tcp16.json || ! -s whitelist_sni.txt ||
           ! -d app || ! -d cli || ! -d core || ! -d utils ]]; then
        error "Не удалось распаковать DPI Detector или в архиве отсутствуют обязательные файлы."
        return 1
    fi

    step "Подготовка временного окружения Python"
    if ! "$python" -E -m venv .venv; then
        error "Не удалось создать окружение Python для DPI Detector."
        return 1
    fi
    if ! timeout 180s .venv/bin/python -m pip --disable-pip-version-check --no-cache-dir \
        --timeout 15 --retries 1 install -r requirements.txt; then
        error "Не удалось установить зависимости DPI Detector."
        return 1
    fi

    .venv/bin/python dpi_detector.py
    script_status=$?
    if [[ "$script_status" -ne 0 && "$script_status" -ne 130 ]]; then
        error "DPI Detector завершился с кодом $script_status."
    fi
    return "$script_status"
)

run_dpi_detector() {
    local status=0

    dpi_detector_session || status=$?
    pause
    return "$status"
}
