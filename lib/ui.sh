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
    printf "\n"
    show_brand "$1"
}

section() {
    printf "\n${BOLD}%s${NC}\n" "$1"
}

menu_item() {
    local number="$1"
    local title="$2"
    printf "  ${GREEN}%2s${NC}  %s\n" "$number" "$title"
}

menu_danger_item() {
    local number="$1"
    local title="$2"
    printf "  ${RED}%2s${NC}  %s\n" "$number" "$title"
}

menu_back_item() {
    printf "  ${BLUE}%2s${NC}  %s\n" "0" "Назад"
}

menu_exit_item() {
    printf "  ${RED}%2s${NC}  %s\n" "0" "Выход"
}

prompt_choice() {
    local range="$1"
    printf "\n${CYAN}Выбор [%s]:${NC} " "$range"
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
