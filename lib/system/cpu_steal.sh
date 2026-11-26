#!/usr/bin/env bash

run_cpu_steal() {
    local status=0
    header "Проверить CPU steal"
    measure_cpu_steal || status=$?
    pause
    return "$status"
}

measure_cpu_steal() {
    local interval=5 stats=/proc/stat
    local command server vcpu_count readings cpu value level line

    for command in awk hostname nproc sleep; do
        check_command "$command" || return 1
    done
    if ! server="$(hostname)" || ! vcpu_count="$(nproc)"; then
        error "Не удалось определить имя сервера или количество доступных vCPU."
        return 1
    fi

    info "Сервер: $server"
    info "Доступно vCPU: $vcpu_count"
    step "Измерение CPU steal в течение $interval секунд..."

    if ! readings="$(LC_ALL=C awk -v stats="$stats" -v interval="$interval" '
        function total_time(    field, total) {
            for (field = 2; field <= 9; field++)
                total += $field
            return total
        }
        BEGIN {
            while ((read_status = getline < stats) > 0) {
                if ($1 ~ /^cpu[0-9]*$/ && NF >= 9) {
                    previous_total[$1] = total_time()
                    previous_steal[$1] = $9
                }
            }
            if (read_status < 0 || !("cpu" in previous_total) || close(stats) != 0)
                exit 1
            if (system("sleep " interval) != 0)
                exit 1

            while ((read_status = getline < stats) > 0) {
                if ($1 !~ /^cpu[0-9]*$/ || NF < 9 || !($1 in previous_total))
                    continue
                elapsed = total_time() - previous_total[$1]
                stolen = $9 - previous_steal[$1]
                if (elapsed <= 0 || stolen < 0 || stolen > elapsed)
                    continue

                value = 100 * stolen / elapsed
                level = value < 2 ? "normal" : (value < 5 ? "warning" : "high")
                printf "%s %.2f %s\n", $1, value, level
            }
            if (read_status < 0 || close(stats) != 0)
                exit 1
        }
    ')"; then
        error "Не удалось измерить CPU steal по статистике $stats."
        return 1
    fi
    if [[ -z "$readings" ]]; then
        error "В $stats нет пригодных данных для расчёта CPU steal."
        return 1
    fi

    section "Доля CPU steal"
    while read -r cpu value level; do
        if [[ "$cpu" == cpu ]]; then
            cpu="Итого"
        fi
        printf -v line '%s  %s%%' "$cpu" "$value"
        case "$level" in
            normal) success "$line — норма" ;;
            warning) warn "$line — повышено" ;;
            high) error "$line — высоко" ;;
        esac
    done <<< "$readings"
}
