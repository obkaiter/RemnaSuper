#!/usr/bin/env bash

show_ssh_key_commands() {
    local login="$1" host="$2" port="$3" transfer_dir="$4" key_folder="$5"
    local local_dir="\$HOME/.ssh/$key_folder"
    local scp_host="$host" remote_key proof_command
    local proof_options="-F none -T -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o PreferredAuthentications=publickey"

    [[ "$host" == *:* ]] && scp_host="[$host]"
    remote_key="$login@$scp_host:$transfer_dir/id_ed25519"
    proof_command="printenv SSH_CONNECTION > $transfer_dir/verified"

    info "Выполните блок для своей ОС на компьютере. Для SCP используйте текущие данные входа."
    section "Windows (PowerShell)"
    cat <<EOF
& {
    \$dir = "$local_dir"
    \$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    New-Item -ItemType Directory -Path "\$dir" -ErrorAction Stop | Out-Null
    icacls.exe "\$dir" /inheritance:r /grant:r "*\${sid}:(OI)(CI)F" | Out-Null
    if (\$LASTEXITCODE -ne 0) { return }
    scp.exe -P $port '$remote_key' "\$dir/id_ed25519"
    if (\$LASTEXITCODE -eq 0) {
        ssh.exe $proof_options -p $port -i "\$dir/id_ed25519" -l '$login' '$host' '$proof_command'
    }
}
EOF

    section "Linux"
    cat <<EOF
mkdir -p -m 700 -- "\$HOME/.ssh" &&
    mkdir -m 700 -- "$local_dir" &&
    (umask 077; scp -P $port '$remote_key' "$local_dir/id_ed25519") &&
    chmod 600 -- "$local_dir/id_ed25519" &&
    ssh $proof_options -p $port -i "$local_dir/id_ed25519" -l '$login' '$host' '$proof_command'
EOF

    section "Команда для последующих подключений (PowerShell и Linux)"
    printf 'ssh -o IdentitiesOnly=yes -p %s -i "%s/id_ed25519" -l %s %s\n' \
        "$port" "$local_dir" "$login" "$host"
}

setup_ssh_key_login() (
    local login account home auth_keys host port default_port default_host
    local key_folder default_folder folder_stem
    local command_name lock_fd transfer_dir key_comment public_key candidate backup_file restore_file policy_candidate
    local connection client_addr client_port server_addr server_port connection_spec effective_config
    local deadline key_added=0 config_changed=0 committed=0 keep_key=0

    cleanup_ssh_key_setup() {
        local status=$?
        trap '' INT HUP TERM

        if (( config_changed && ! committed )); then
            if mv -fT -- "$restore_file" "$SSHD_CONFIG"; then
                config_changed=0
                if ! systemctl reload ssh.service; then
                    keep_key=1
                    error "Исходный файл восстановлен. Не удалось перечитать его через ssh.service. Новый ключ сохранён для доступа."
                fi
            else
                error "Не удалось восстановить SSH автоматически. Резервная копия: $backup_file"
            fi
        fi
        if (( ! committed && ! config_changed )) && [[ "$policy_candidate" -ef "$SSHD_KEY_ONLY_CONFIG" ]]; then
            rm -f -- "$SSHD_KEY_ONLY_CONFIG" || error "Не удалось удалить $SSHD_KEY_ONLY_CONFIG."
        fi
        if (( key_added && ! committed && ! config_changed && ! keep_key )) && [[ -f "$auth_keys" && ! -L "$auth_keys" ]]; then
            runuser -u "$login" -- sed -i "\|^$public_key\$|d" "$auth_keys" ||
                error "Не удалось удалить открытый ключ с меткой $key_comment из $auth_keys."
        fi
        if [[ -n "$transfer_dir" ]]; then
            rm -f -- "$transfer_dir"/{id_ed25519,id_ed25519.pub,verified} &&
                rmdir -- "$transfer_dir" || error "Не удалось очистить временный каталог $transfer_dir."
        fi
        rm -f -- "${candidate:-}" "${restore_file:-}" "${policy_candidate:-}" ||
            error "Не удалось удалить временные файлы конфигурации SSH."
        return "$status"
    }

    for command_name in sshd ssh-keygen systemctl runuser getent flock; do
        check_command "$command_name" || return 1
    done
    if ! systemctl is-active --quiet ssh.service; then
        error "Для настройки требуется работающий OpenSSH (ssh.service)."
        return 1
    fi
    umask 077
    if ! { exec {lock_fd}>/run/remnasuper-ssh.lock; } || ! flock -n "$lock_fd"; then
        error "Не удалось получить блокировку. Возможно, уже выполняется настройка SSH."
        return 1
    fi
    if [[ -e "$SSHD_KEY_ONLY_CONFIG" || -L "$SSHD_KEY_ONLY_CONFIG" ]]; then
        warn "Файл $SSHD_KEY_ONLY_CONFIG уже существует. Повторная настройка остановлена."
        return 1
    fi
    if [[ ! -f "$SSHD_CONFIG" || -L "$SSHD_CONFIG" ]] || ! sshd -t -f "$SSHD_CONFIG"; then
        error "Требуется корректный файл конфигурации $SSHD_CONFIG."
        return 1
    fi

    read -rp "Пользователь SSH [${SUDO_USER:-root}]: " login || return 1
    login="${login:-${SUDO_USER:-root}}"
    if [[ ! "$login" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || ! account="$(getent passwd "$login")"; then
        error "Пользователь SSH не найден."
        return 1
    fi
    IFS=: read -r _ _ _ _ _ home _ <<< "$account"
    if [[ "$home" != /* || "$home" == / || ! -d "$home" ]]; then
        error "У пользователя $login отсутствует домашний каталог."
        return 1
    fi
    auth_keys="$home/.ssh/authorized_keys"

    read -r _ _ default_host default_port <<< "${SSH_CONNECTION:-}"
    read -rp "Адрес сервера, доступный с вашего компьютера [${default_host:-IP или домен}]: " host || return 1
    read -rp "Порт SSH [${default_port:-22}]: " port || return 1
    host="${host:-$default_host}"
    port="${port:-${default_port:-22}}"
    if [[ ! "$host" =~ ^[a-zA-Z0-9:][a-zA-Z0-9.:%_-]*$ ||
          ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        error "Укажите корректный IP-адрес или домен и порт SSH от 1 до 65535."
        return 1
    fi
    default_folder="ssh-${host//[^a-zA-Z0-9._-]/-}"
    default_folder="${default_folder:0:64}"
    [[ "$default_folder" == *. ]] && default_folder="${default_folder%.}-"
    while true; do
        read -rp "Имя новой папки для ключа внутри ~/.ssh [$default_folder]: " key_folder || return 1
        key_folder="${key_folder:-$default_folder}"
        folder_stem="${key_folder%%.*}"
        if [[ ! "$key_folder" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ || "$key_folder" == *. ]]; then
            warn "Введите от 1 до 64 латинских букв, цифр, дефисов, подчёркиваний или точек. Начните с буквы или цифры и не ставьте точку в конце."
        elif [[ "${folder_stem^^}" =~ ^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$ ]]; then
            warn "Это имя зарезервировано в Windows. Выберите другое."
        else
            break
        fi
    done

    trap cleanup_ssh_key_setup EXIT
    trap 'exit 130' INT
    trap 'exit 1' HUP TERM
    backup_config_file "$SSHD_CONFIG" backup_file || return 1
    if ! transfer_dir="$(mktemp -d /run/remnasuper-ssh.XXXXXXXXXX)"; then
        error "Не удалось создать временный каталог для передачи ключа."
        return 1
    fi
    key_comment="${transfer_dir##*/}"
    if ! ssh-keygen -q -t ed25519 -N '' -C "$key_comment" -f "$transfer_dir/id_ed25519" ||
        ! public_key="$(cat -- "$transfer_dir/id_ed25519.pub")" ||
        ! touch -- "$transfer_dir/verified" ||
        ! chown -- "$login" "$transfer_dir"/{id_ed25519,verified} ||
        ! chmod 0711 -- "$transfer_dir"; then
        error "Не удалось подготовить ключ SSH для передачи."
        return 1
    fi
    # Меняем пользовательский файл от имени его владельца.
    key_added=1
    if ! runuser -u "$login" -- bash -c '
        umask 077
        mkdir -p -- "${1%/*}" || exit 1
        [[ ! -L "$1" && ( ! -e "$1" || ( -f "$1" && -r "$1" ) ) ]] || exit 1
        if [[ -s "$1" && -n "$(tail -c 1 -- "$1")" ]]; then
            printf "\n" >> "$1" || exit 1
        fi
        printf "%s\n" "$2" >> "$1"
    ' bash "$auth_keys" "$public_key"; then
        error "Не удалось добавить открытый ключ в $auth_keys."
        return 1
    fi
    show_ssh_key_commands "$login" "$host" "$port" "$transfer_dir" "$key_folder"
    info "Ожидаю проверку нового ключа до 5 минут. Для отмены нажмите Ctrl+C."
    deadline=$((SECONDS + 300))
    until IFS= read -r -n 256 connection < "$transfer_dir/verified"; do
        if (( SECONDS >= deadline )); then
            warn "Время ожидания истекло. Настройка SSH отменена."
            return 1
        fi
        sleep 1
    done
    read -r client_addr client_port server_addr server_port <<< "$connection"
    if [[ ! "$client_addr" =~ ^[a-fA-F0-9:.]+$ || ! "$server_addr" =~ ^[a-fA-F0-9:.]+$ ||
          ! "$client_port" =~ ^[0-9]+$ || ! "$server_port" =~ ^[0-9]+$ ]]; then
        error "Не удалось определить параметры проверочного подключения."
        return 1
    fi
    if ! rm -f -- "$transfer_dir/id_ed25519"; then
        error "Не удалось удалить временную копию закрытого ключа."
        return 1
    fi

    connection_spec="user=$login,host=$client_addr,addr=$client_addr,laddr=$server_addr,lport=$server_port"
    if ! effective_config="$(LC_ALL=C sshd -T -f "$SSHD_CONFIG" -C "$connection_spec")" ||
        ! grep -qx 'permitemptypasswords no' <<< "$effective_config"; then
        error "Для проверки нового ключа требуется PermitEmptyPasswords no в текущей конфигурации SSH."
        return 1
    fi
    if ! candidate="$(mktemp "${SSHD_CONFIG}.remnasuper.XXXXXX")" ||
        ! restore_file="$(mktemp "${SSHD_CONFIG}.remnasuper.XXXXXX")" ||
        ! policy_candidate="$(mktemp "${SSHD_KEY_ONLY_CONFIG}.XXXXXX")" ||
        ! cp -p -- "$backup_file" "$restore_file"; then
        error "Не удалось подготовить файлы для обновления конфигурации SSH."
        return 1
    fi

    # Первый Include задаёт приоритет и сохраняет область действия исходных Match.
    if ! cat > "$policy_candidate" <<'EOF'
# RemnaSuper
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no

Match all
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitEmptyPasswords no
EOF
    then
        error "Не удалось подготовить конфигурацию отключения пароля."
        return 1
    fi
    if ! ln -T -- "$policy_candidate" "$SSHD_KEY_ONLY_CONFIG"; then
        error "Не удалось создать $SSHD_KEY_ONLY_CONFIG."
        return 1
    fi
    if ! { printf 'Include %s\n' "$SSHD_KEY_ONLY_CONFIG" && cat -- "$restore_file"; } > "$candidate" ||
        ! chmod --reference="$restore_file" -- "$candidate" ||
        ! chown --reference="$restore_file" -- "$candidate" ||
        ! sshd -t -f "$candidate" ||
        ! effective_config="$(LC_ALL=C sshd -T -f "$candidate" -C "$connection_spec")" ||
        ! grep -qx 'passwordauthentication no' <<< "$effective_config" ||
        ! grep -qx 'kbdinteractiveauthentication no' <<< "$effective_config" ||
        ! grep -qx 'pubkeyauthentication yes' <<< "$effective_config"; then
        error "Проверка новой конфигурации SSH не прошла."
        return 1
    fi
    if ! cmp -s -- "$restore_file" "$SSHD_CONFIG"; then
        error "Конфигурация SSH была изменена во время настройки. Попробуйте ещё раз."
        return 1
    fi
    config_changed=1
    if ! mv -fT -- "$candidate" "$SSHD_CONFIG"; then
        config_changed=0
        error "Не удалось заменить конфигурацию SSH."
        return 1
    fi
    if ! systemctl reload ssh.service; then
        error "Не удалось применить новую конфигурацию SSH."
        return 1
    fi
    committed=1
    success "Вход с новым ключом проверен. Вход по паролю отключён."
)

configure_ssh_key_login() {
    local status

    setup_ssh_key_login
    status=$?
    pause
    return "$status"
}
