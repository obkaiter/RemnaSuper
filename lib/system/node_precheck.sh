#!/usr/bin/env bash

run_node_precheck() {
    local run_status=0

    check_command curl || { pause; return; }
    check_command bash || { pause; return; }

    if run_downloaded_bash "$NODE_PRECHECK_URL" node-precheck.sh; then
        run_status=0
    else
        run_status=$?
        error "Node Precheck завершился с ошибкой."
    fi

    pause
    return "$run_status"
}
