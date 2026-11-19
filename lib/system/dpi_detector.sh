#!/usr/bin/env bash

dpi_detector_session() (
    local tool work_dir script_status

    for tool in curl tar python3 timeout; do
        check_command "$tool" || return 1
    done

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
    if ! python3 -m venv .venv; then
        error "Не удалось создать окружение Python. На Debian/Ubuntu проверьте наличие пакета python3-venv."
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
