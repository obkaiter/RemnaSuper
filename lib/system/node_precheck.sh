#!/usr/bin/env bash

run_node_precheck() {
    local run_status=0

    check_command curl || { pause; return; }
    check_command bash || { pause; return; }

    if bash <(curl -fsSL --max-time 30 "$NODE_PRECHECK_URL"); then
        run_status=0
    else
        run_status=$?
        error "Node Precheck завершился с ошибкой."
    fi

    pause
    return "$run_status"
}
