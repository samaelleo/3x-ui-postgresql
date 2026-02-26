#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

base_dir="/opt/3x-ui"
selected_panel=""
selected_panel_dir=""

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n " && exit 1

function LOGD() { echo -e "${yellow}[DEG] $* ${plain}"; }
function LOGE() { echo -e "${red}[ERR] $* ${plain}"; }
function LOGI() { echo -e "${green}[INF] $* ${plain}"; }

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [Default $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}Press enter to return to the main menu: ${plain}" && read -r temp
    show_menu
}

select_panel() {
    if [ ! -d "$base_dir" ]; then
        echo -e "${red}No installed panels found. Please run the installer first.${plain}"
        exit 1
    fi

    # Read subdirectories directly into an array
    local panels=()
    while IFS= read -r -d '' dir; do
        panels+=("$(basename "$dir")")
    done < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d -print0)

    local count=${#panels[@]}

    if [ "$count" -eq 0 ]; then
        echo -e "${red}No panel installations found in $base_dir.${plain}"
        exit 1
    fi

    if [ "$count" -eq 1 ]; then
        selected_panel="${panels[0]}"
        selected_panel_dir="${base_dir}/${selected_panel}"
        return 0
    fi

    echo -e "${green}Found multiple panel installations. Please select one to manage:${plain}"
    local i=1
    for p in "${panels[@]}"; do
        echo -e "  ${green}$i.${plain} $p"
        ((i++))
    done

    local selection=""
    while true; do
        read -rp "Enter your choice [1-$count]: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$count" ]; then
            break
        fi
        echo -e "${red}Invalid selection. Please try again.${plain}"
    done

    selected_panel="${panels[$((selection-1))]}"
    selected_panel_dir="${base_dir}/${selected_panel}"
    echo -e "${green}Selected panel: $selected_panel${plain}"
}

# 0: running, 1: not running (or no container)
check_status() {
    local status=$(docker inspect -f '{{.State.Running}}' "${selected_panel}" 2>/dev/null)
    if [[ "$status" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

show_status() {
    check_status
    if [[ $? == 0 ]]; then
        echo -e "Panel state: ${green}Running${plain}"
    else
        echo -e "Panel state: ${yellow}Not Running${plain}"
    fi
}

start() {
    cd "${selected_panel_dir}" || return
    docker-compose up -d
    if [[ $# == 0 ]]; then before_show_menu; fi
}

stop() {
    cd "${selected_panel_dir}" || return
    docker-compose stop
    if [[ $# == 0 ]]; then before_show_menu; fi
}

restart() {
    cd "${selected_panel_dir}" || return
    docker-compose restart
    if [[ $# == 0 ]]; then before_show_menu; fi
}

show_log() {
    echo -e "${green}Showing logs for container ${selected_panel} (Press Ctrl+C to exit):${plain}"
    docker logs -f "${selected_panel}"
    if [[ $# == 0 ]]; then before_show_menu; fi
}

reset_user() {
    confirm "Are you sure to reset the username and password of the panel?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then show_menu; fi
        return 0
    fi
    
    read -rp "Please set the login username [default is a random username]: " config_account
    [[ -z $config_account ]] && config_account=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 10 | head -n 1)
    read -rp "Please set the login password [default is a random password]: " config_password
    [[ -z $config_password ]] && config_password=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 18 | head -n 1)

    read -rp "Do you want to disable currently configured two-factor authentication? (y/n): " twoFactorConfirm
    if [[ $twoFactorConfirm != "y" && $twoFactorConfirm != "Y" ]]; then
        docker exec -it "${selected_panel}" /x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor false >/dev/null 2>&1
    else
        docker exec -it "${selected_panel}" /x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor true >/dev/null 2>&1
        echo -e "Two factor authentication has been disabled."
    fi
    
    echo -e "Panel login username has been reset to: ${green} ${config_account} ${plain}"
    echo -e "Panel login password has been reset to: ${green} ${config_password} ${plain}"
    echo -e "${green} Please use the new login username and password to access the panel. Also remember them! ${plain}"
    restart
}

reset_webbasepath() {
    echo -e "${yellow}Resetting Web Base Path${plain}"
    read -rp "Are you sure you want to reset the web base path? (y/n): " confirm_path
    if [[ $confirm_path != "y" && $confirm_path != "Y" ]]; then
        echo -e "${yellow}Operation canceled.${plain}"
        return
    fi
    local config_webBasePath=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 18 | head -n 1)
    docker exec -it "${selected_panel}" /x-ui setting -webBasePath "${config_webBasePath}" >/dev/null 2>&1
    echo -e "Web base path has been reset to: ${green}${config_webBasePath}${plain}"
    restart
}

reset_config() {
    confirm "Are you sure you want to reset all panel settings? Account data will not be lost." "n"
    if [[ $? != 0 ]]; then return 0; fi
    docker exec -it "${selected_panel}" /x-ui setting -reset
    echo -e "All panel settings have been reset to default."
    restart
}

set_port() {
    echo -n "Enter port number[1-65535]: "
    read -r port
    if [[ -z "${port}" ]]; then
        LOGD "Cancelled"
    else
        # We need to update docker-compose.yml to expose the new port
        cd "${selected_panel_dir}" || return
        # Simple sed replacement for ports mapping "- "oldport:oldport""
        local old_port=$(grep -A 1 'ports:' docker-compose.yml | grep '-' | sed 's/.*"\(.*\)".*/\1/' | cut -d':' -f1)
        if [[ -n "$old_port" ]]; then
            sed -i "s/\"${old_port}:${old_port}\"/\"${port}:${port}\"/g" docker-compose.yml
        fi
        
        docker exec -it "${selected_panel}" /x-ui setting -port ${port}
        echo -e "The port is set to ${green}${port}${plain}. Recreating container to bind the new port..."
        docker-compose up -d
    fi
}

check_config() {
    local info=$(docker exec -it "${selected_panel}" /x-ui setting -show true)
    if [[ $? != 0 ]]; then
        LOGE "Failed to get current settings, is the container running?"
    else
        LOGI "${info}"
    fi
    if [[ $# == 0 ]]; then before_show_menu; fi
}

db_config() {
    cd "${selected_panel_dir}" || return
    local env_file=".env"
    
    echo -e "${yellow}Current Database Configuration:${plain}"
    if [ -f "$env_file" ] && grep -q "XUI_DB_TYPE=postgres" "$env_file"; then
        echo -e "Database Type: ${green}PostgreSQL${plain}"
        local current_uri=$(grep "XUI_DB_URI" "$env_file" | cut -d'=' -f2-)
        echo -e "Connection URI: ${green}${current_uri}${plain}"
    else
        echo -e "Database Type: ${green}SQLite${plain} (Default)"
    fi
    
    echo ""
    echo -e "${green}\t1.${plain} Use SQLite (Default)"
    echo -e "${green}\t2.${plain} Use PostgreSQL"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " choice
    
    case "$choice" in
        0) show_menu ;;
        1)
            confirm "Switch to SQLite? (PostgreSQL settings will be removed from .env)" "y"
            if [[ $? == 0 ]]; then
                echo "XUI_DB_TYPE=sqlite" > "$env_file"
                echo "XUI_DB_URI=" >> "$env_file"
                echo -e "${green}Switched to SQLite successfully. Restarting...${plain}"
                docker-compose up -d
            else
                db_config
            fi
            ;;
        2)
            read -rp "Please enter the PostgreSQL Connection URI: " config_db_uri
            if [[ -n "$config_db_uri" ]]; then
                echo "XUI_DB_TYPE=postgres" > "$env_file"
                echo "XUI_DB_URI=\"${config_db_uri}\"" >> "$env_file"
                echo -e "${green}Switched to PostgreSQL successfully. Restarting...${plain}"
                docker-compose up -d
            else
                echo -e "${red}Connection URI cannot be empty.${plain}"
                db_config
            fi
            ;;
        *)
            echo -e "${red}Invalid option.${plain}\n"
            db_config
            ;;
    esac
}

install_acme() {
    if command -v ~/.acme.sh/acme.sh &>/dev/null; then return 0; fi
    LOGI "Installing acme.sh..."
    cd ~ || return 1
    curl -s https://get.acme.sh | sh
    return $?
}

ssl_cert_issue_main() {
    echo -e "${yellow}SSL Configuration (Docker)${plain}"
    echo -e "${green}Because Let's Encrypt requires port 80 to be bound, the built-in standalone verifier conflicts when multiple panels are used.${plain}"
    echo -e "${green}Your volume is bound to ${selected_panel_dir}/cert/ . You can manually copy certificates here.${plain}"
    echo ""
    echo -e "${green}\t1.${plain} Apply manual SSL certificate mappings for this panel"
    echo -e "${green}\t0.${plain} Back to Main Menu"

    read -rp "Choose an option: " choice
    case "$choice" in
    0)
        show_menu
        ;;
    1)
        cd "${selected_panel_dir}" || return
        mkdir -p cert
        echo -e "${yellow}Please copy your fullchain.pem and privkey.pem into ${selected_panel_dir}/cert/${plain}"
        read -rp "Press Enter once you have copied the files in..."
        
        if [[ -f "cert/fullchain.pem" && -f "cert/privkey.pem" ]]; then
            docker exec -it "${selected_panel}" /x-ui cert -webCert "/root/cert/fullchain.pem" -webCertKey "/root/cert/privkey.pem"
            echo -e "${green}Certificates applied correctly! Restarting panel...${plain}"
            docker-compose restart "${selected_panel}"
        else
            echo -e "${red}Could not find cert/fullchain.pem or cert/privkey.pem in the directory.${plain}"
        fi
        ssl_cert_issue_main
        ;;
    *)
        ssl_cert_issue_main
        ;;
    esac
}

show_menu() {
    echo -e "
╔────────────────────────────────────────────────╗
│   ${green}3X-UI Docker Control Menu${plain}                │
│   ${yellow}Managing Panel: ${selected_panel}${plain}
│────────────────────────────────────────────────│
│   ${green}0.${plain} Exit Script                               │
│────────────────────────────────────────────────│
│   ${green}1.${plain} Restart Username & Password                 │
│   ${green}2.${plain} Reset Web Base Path                       │
│   ${green}3.${plain} Reset Settings                            │
│   ${green}4.${plain} Change Port                               │
│   ${green}5.${plain} View Current Settings                     │
│────────────────────────────────────────────────│
│   ${green}6.${plain} Start Panel Container                     │
│   ${green}7.${plain} Stop Panel Container                      │
│   ${green}8.${plain} Restart Panel Container                   │
│   ${green}9.${plain} Docker Logs                               │
│────────────────────────────────────────────────│
│  ${green}10.${plain} SSL Certificate Management                │
│  ${green}11.${plain} Configure Database Settings               │
╚────────────────────────────────────────────────╝
"
    show_status
    echo && read -rp "Please enter your selection [0-11]: " num

    case "${num}" in
    0) exit 0 ;;
    1) reset_user ;;
    2) reset_webbasepath ;;
    3) reset_config ;;
    4) set_port ;;
    5) check_config ;;
    6) start ;;
    7) stop ;;
    8) restart ;;
    9) show_log ;;
    10) ssl_cert_issue_main ;;
    11) db_config ;;
    *) LOGE "Please enter a valid number" ;;
    esac
}

# Require panel selection immediately
select_panel

if [[ $# > 0 ]]; then
    case $1 in
    "start") start 0 ;;
    "stop") stop 0 ;;
    "restart") restart 0 ;;
    "status") show_status ;;
    "settings") check_config 0 ;;
    "log") show_log 0 ;;
    *) echo "Invalid command for docker setup" ;;
    esac
else
    show_menu
fi
