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
    local color="${3:-$'\e[0;37m'}"
    local label
    printf -v label '    %b%s%b' "$color" "$2" "$NC"
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
    local output_variable="$1" menu_selection
    shift

    {
        menu_selection="$(_select_menu "$@" 3>&1 >&4)" || return
    } 4>&1
    printf -v "$output_variable" '%s' "${menu_selection%.}"
}

_select_menu() (
    local default_value="$1" render_menu="$2"
    shift 2

    local -a menu_rows=() menu_positions=() menu_values=()
    local key terminal_state terminal_size terminal_height visible_rows selected_row row frame
    local rendered_size rendered_selected_row previous_offset selected_offset
    local selected=0 first_row=0 rendered_first_row=-1 rendered_rows=0

    if [[ ! -t 0 || ! -t 1 ]]; then
        error "Для выбора пункта меню нужен интерактивный терминал." >&2
        return 1
    fi
    check_command stty || return 1
    terminal_state="$(stty -g)" || return 1
    trap 'stty "$terminal_state" || exit 1' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stty -echo -icanon min 1 time 0 || return 1
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
        if (( first_row == rendered_first_row )) && [[ "$terminal_size" == "$rendered_size" ]]; then
            if (( selected_row != rendered_selected_row )); then
                previous_offset=$((rendered_rows - (rendered_selected_row - first_row)))
                selected_offset=$((rendered_rows - (selected_row - first_row)))
                printf -v frame '\r\e[%dA    \r\e[%dB' "$previous_offset" "$previous_offset"
                printf -v frame '%s\e[%dA  %b→%b \r\e[%dB' "$frame" "$selected_offset" "$GREEN" "$NC" "$selected_offset"
            fi
        else
            if (( rendered_rows )); then
                printf -v frame '\r\e[%dA' "$rendered_rows"
            fi
            for ((row = first_row; row < first_row + visible_rows && row < ${#menu_rows[@]}; row++)); do
                if (( row == selected_row )); then
                    printf -v frame '%s\e[2K  %b→%b %s\r\n' "$frame" "$GREEN" "$NC" "${menu_rows[row]:4}"
                else
                    frame+=$'\e[2K'"${menu_rows[row]}"$'\r\n'
                fi
            done
            if (( row - first_row < rendered_rows )); then
                frame+=$'\e[J'
            fi
            rendered_rows=$((row - first_row))
            rendered_first_row=$first_row
            rendered_size=$terminal_size
            printf -v frame '%s\e[2K%b↑/↓ — перемещение, Enter — выбрать%b' "$frame" "$DIM" "$NC"
        fi
        rendered_selected_row=$selected_row
        if [[ -n "$frame" ]]; then
            printf '\e[?7l%s\e[?7h' "$frame"
        fi

        while true; do
            if ! IFS= read -rn1 key; then
                printf '\n'
                return 1
            fi
            case "$key" in
                ''|$'\r')
                    printf '\n'
                    printf '%s.' "${menu_values[selected]}" >&3
                    return
                    ;;
                $'\004')
                    printf '\n'
                    return 1
                    ;;
                $'\e')
                    IFS= read -rn1 -t 0.2 key || continue
                    [[ "$key" == '[' || "$key" == O ]] || continue
                    while IFS= read -rn1 -t 0.2 key && [[ "$key" == [\ -\?] ]]; do
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
)

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
