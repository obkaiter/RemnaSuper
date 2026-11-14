#!/usr/bin/env bash

RED='\e[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[1;33m'
BLUE='\e[0;34m'
CYAN='\e[0;36m'
WHITE='\e[1;37m'
DIM='\e[2m'
NC='\e[0m'
BOLD='\e[1m'

info()    { printf "${BLUE}[i]${NC} %s\n" "$1"; }
success() { printf "${GREEN}[ok]${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error()   { printf "${RED}[x]${NC} %s\n" "$1"; }
step()    { printf "${WHITE}[>]${NC} %s\n" "$1"; }

divider() {
    printf "${CYAN}................................................${NC}\n"
}

show_brand() {
    local subtitle="${1:-}"

    printf "${BOLD}${CYAN}%s${NC} ${WHITE}v%s${NC}\n" "$REMNASUPER_NAME" "$REMNASUPER_VERSION"
    printf "${DIM}Автор: github.com/obkaiter${NC}\n"
    [ -n "$subtitle" ] && printf "%s\n\n" "$subtitle"
}

show_startup() {
    clear
    show_brand "Проверка окружения и версии..."
}

header() {
    case "${remnasuper_action_header_state:-}" in
        first)
            remnasuper_action_header_state=following
            printf "\n"
            return
            ;;
        following)
            section "$1"
            return
            ;;
    esac

    printf "\n"
    show_brand "$1"
}

section() {
    printf "\n${BOLD}%s${NC}\n" "$1"
}

menu_section() {
    local title
    printf -v title "${BOLD}%s${NC}" "$1"
    menu_rows+=("" "$title")
}

menu_item() {
    local label
    printf -v label '    %b%s%b' "${3:-}" "$2" "${3:+$NC}"
    menu_positions+=("${#menu_rows[@]}")
    menu_values+=("$1")
    menu_rows+=("$label")
}

menu_danger_item() {
    menu_item "$1" "$2" "$RED"
}

menu_back_item() {
    menu_item 0 "Назад" "$BLUE"
}

show_menu_options() {
    menu_section "$1"
    shift
    while (( $# )); do
        menu_item "$1" "$2"
        shift 2 || return
    done
}

select_menu() {
    local output_variable="$1"
    local default_value="$2"
    local render_menu="$3"
    shift 3

    local -a menu_rows=() menu_positions=() menu_values=()
    local key terminal_size terminal_height visible_rows selected_row row frame
    local selected=0 first_row=0 rendered_rows=0

    if [[ ! -t 0 || ! -t 1 ]]; then
        error "Для выбора пункта меню нужен интерактивный терминал." >&2
        return 1
    fi
    check_command stty || return 1
    "$render_menu" "$@" || return
    (( ${#menu_values[@]} )) || return 1
    for row in "${!menu_values[@]}"; do
        if [[ "${menu_values[row]}" == "$default_value" ]]; then
            selected=$row
            break
        fi
    done

    while true; do
        terminal_size="$(stty size 2>/dev/null)" || terminal_size=
        terminal_height="${terminal_size%% *}"
        if [[ ! "$terminal_height" =~ ^[1-9][0-9]*$ ]]; then
            terminal_height=24
        fi
        visible_rows=$((terminal_height > 1 ? terminal_height - 1 : 1))
        selected_row=${menu_positions[selected]}
        if (( selected_row < first_row )); then
            first_row=$selected_row
        elif (( selected_row >= first_row + visible_rows )); then
            first_row=$((selected_row - visible_rows + 1))
        fi
        if (( first_row + visible_rows > ${#menu_rows[@]} )); then
            first_row=$(( ${#menu_rows[@]} > visible_rows ? ${#menu_rows[@]} - visible_rows : 0 ))
        fi

        frame=
        if (( rendered_rows )); then
            printf -v frame '\r\e[%dA\e[J' "$rendered_rows"
        fi
        for ((row = first_row; row < first_row + visible_rows && row < ${#menu_rows[@]}; row++)); do
            if (( row == selected_row )); then
                printf -v frame '%s  %b>%b %s\n' "$frame" "$GREEN" "$NC" "${menu_rows[row]:4}"
            else
                frame+="${menu_rows[row]}"$'\n'
            fi
        done
        rendered_rows=$((row - first_row))
        printf '\e[?7l%s%b↑/↓ — перемещение, Enter — выбрать%b\e[?7h' "$frame" "$DIM" "$NC"

        while true; do
            if ! IFS= read -rsn1 key; then
                printf '\n'
                return 1
            fi
            case "$key" in
                ''|$'\r')
                    printf '\n'
                    printf -v "$output_variable" '%s' "${menu_values[selected]}"
                    return
                    ;;
                $'\004')
                    printf '\n'
                    return 1
                    ;;
                $'\e')
                    IFS= read -rsn1 -t 0.2 key || continue
                    [[ "$key" == '[' || "$key" == O ]] || continue
                    while IFS= read -rsn1 -t 0.2 key && [[ "$key" == [\ -\?] ]]; do
                        :
                    done
                    case "$key" in
                        A) selected=$(( (selected + ${#menu_values[@]} - 1) % ${#menu_values[@]} )) ;;
                        B) selected=$(( (selected + 1) % ${#menu_values[@]} )) ;;
                        *) continue ;;
                    esac
                    break
                    ;;
            esac
        done
    done
}

pause() {
    printf "\n${DIM}Enter - вернуться в меню${NC}"
    read -r
}

confirm() {
    local message="$1"
    local reply

    read -rp "$message (y/N): " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}
