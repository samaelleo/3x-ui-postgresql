#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)
base_dir="/opt/3x-ui"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n " && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
    elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "The OS release is: $release"

# Simple helpers
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# Port helpers
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    return 1
}

install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q curl tar tzdata socat ca-certificates
        ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update && dnf install -y -q curl tar tzdata socat ca-certificates
        ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update && yum install -y curl tar tzdata socat ca-certificates
            else
                dnf -y update && dnf install -y -q curl tar tzdata socat ca-certificates
            fi
        ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm curl tar tzdata socat ca-certificates
        ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh && zypper -q install -y curl tar timezone socat ca-certificates
        ;;
        alpine)
            apk update && apk add curl tar tzdata socat ca-certificates
        ;;
        *)
            apt-get update && apt-get install -y -q curl tar tzdata socat ca-certificates
        ;;
    esac
}

install_docker() {
    if command -v docker &>/dev/null && command -v docker-compose &>/dev/null; then
        echo -e "${green}Docker and Docker Compose are already installed.${plain}"
        return
    fi

    echo -e "${yellow}Installing Docker and Docker Compose...${plain}"
    curl -fsSL https://get.docker.com | bash -s docker
    if [ $? -ne 0 ]; then
        echo -e "${red}Failed to install Docker. Please install it manually.${plain}"
        exit 1
    fi

    if ! command -v docker-compose &>/dev/null; then
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi

    systemctl enable docker
    systemctl start docker
    echo -e "${green}Docker and Docker Compose installed successfully.${plain}"
}

gen_random_string() {
    local length="$1"
    local random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1)
    echo "$random_string"
}

setup_docker_panel() {
    local panel_name=""
    read -rp "Please enter a name for this panel (e.g., panel1): " panel_name
    panel_name="${panel_name// /}"
    
    if [[ -z "$panel_name" ]]; then
        panel_name="panel-$(gen_random_string 4)"
    fi

    local panel_dir="${base_dir}/${panel_name}"
    if [ -d "$panel_dir" ]; then
        echo -e "${red}Panel directory ${panel_dir} already exists. Please choose a different name.${plain}"
        exit 1
    fi

    mkdir -p "$panel_dir"
    cd "$panel_dir" || exit 1

    echo -e "${green}Creating configuration for panel: ${panel_name} at ${panel_dir}${plain}"

    local config_webBasePath=$(gen_random_string 18)
    local config_username=$(gen_random_string 10)
    local config_password=$(gen_random_string 10)
    local config_port=$(shuf -i 1024-62000 -n 1)

    read -rp "Would you like to customize the Panel Port settings? (If not, a random port will be applied) [y/n]: " config_confirm
    if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
        read -rp "Please set up the panel port: " config_port
        while is_port_in_use "$config_port"; do
            echo -e "${red}Port $config_port is already in use.${plain}"
            read -rp "Please set up the panel port: " config_port
        done
        echo -e "${yellow}Your Panel Port is: ${config_port}${plain}"
    else
        while is_port_in_use "$config_port"; do
            config_port=$(shuf -i 1024-62000 -n 1)
        done
        echo -e "${yellow}Generated random port: ${config_port}${plain}"
    fi

    echo ""
    echo -e "${green}═══════════════════════════════════════════${plain}"
    echo -e "${green}         Database Configuration            ${plain}"
    echo -e "${green}═══════════════════════════════════════════${plain}"
    echo -e "You can choose between SQLite (default) and PostgreSQL for the panel database."
    read -rp "Do you want to use PostgreSQL instead of SQLite? [y/N]: " db_confirm
    
    local use_postgres="false"
    local config_db_uri=""
    local db_type="sqlite"
    
    if [[ "${db_confirm}" == "y" || "${db_confirm}" == "Y" ]]; then
        use_postgres="true"
        db_type="postgres"
        echo -e "${yellow}We will automatically spin up a PostgreSQL container alongside the panel.${plain}"
        local pg_password=$(gen_random_string 16)
        config_db_uri="postgres://3xui:${pg_password}@postgres:5432/3xui_db?sslmode=disable"
        
        # Create postgres env details
        cat <<EOF > postgres.env
POSTGRES_USER=3xui
POSTGRES_PASSWORD=${pg_password}
POSTGRES_DB=3xui_db
EOF
    else
        echo -e "${yellow}Continuing with SQLite as the default database.${plain}"
    fi

    # Create .env
    cat <<EOF > .env
XUI_DB_TYPE=${db_type}
XUI_DB_URI=${config_db_uri}
# XUI_LOG_FOLDER=/dev/null # Uncomment to disable logging
EOF

    # Create docker-compose.yml
    cat <<EOF > docker-compose.yml
services:
  ${panel_name}:
    image: ghcr.io/samaelleo/3x-ui-main:latest
    container_name: ${panel_name}
    volumes:
      - ./${db_type}:/etc/x-ui/
      - ./cert:/root/cert/
    environment:
      - XUI_DB_TYPE=\${XUI_DB_TYPE}
      - XUI_DB_URI=\${XUI_DB_URI}
    ports:
      - "${config_port}:${config_port}"
    network_mode: "host"
    restart: unless-stopped
EOF

    if [[ "$use_postgres" == "true" ]]; then
        # We need bridge networking to connect cleanly to postgres while still exposing the panel port
        cat <<EOF > docker-compose.yml
services:
  ${panel_name}:
    image: ghcr.io/samaelleo/3x-ui-main:latest
    container_name: ${panel_name}
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./cert:/root/cert/
    environment:
      - XUI_DB_TYPE=\${XUI_DB_TYPE}
      - XUI_DB_URI=\${XUI_DB_URI}
    ports:
      - "${config_port}:${config_port}"
    network_mode: "host"
    restart: unless-stopped
    extra_hosts:
      - "postgres:127.0.0.1"

  postgres:
    image: postgres:15-alpine
    container_name: ${panel_name}-postgres
    env_file:
      - postgres.env
    volumes:
      - ./pgdata:/var/lib/postgresql/data
    network_mode: "host"
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U 3xui -d 3xui_db"]
      interval: 5s
      timeout: 5s
      retries: 5
EOF
    fi

    echo -e "${green}docker-compose.yml created.${plain}"
    echo -e "${yellow}Starting panel container...${plain}"
    
    docker-compose up -d

    echo -e "${yellow}Waiting for panel to start...${plain}"
    sleep 5
    
    echo -e "${yellow}Setting up initial panel credentials...${plain}"
    docker exec -it ${panel_name} /x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"
    docker-compose restart ${panel_name}

    local server_ip=$(curl -s --max-time 3 -4 https://api.ipify.org)
    
    # Install CLI Manager Script
    curl -4fLRo /usr/local/bin/x-ui https://raw.githubusercontent.com/samaelleo/3x-ui-main/main/x-ui-docker.sh
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to download the new Docker CLI manager (x-ui.sh).${plain}"
    else
        chmod +x /usr/local/bin/x-ui
        echo -e "${green}x-ui CLI manager installed successfully.${plain}"
    fi

    echo ""
    echo -e "${green}═══════════════════════════════════════════${plain}"
    echo -e "${green}     Panel Installation Complete!         ${plain}"
    echo -e "${green}═══════════════════════════════════════════${plain}"
    echo -e "${green}Panel Name:  ${panel_name}${plain}"
    echo -e "${green}Directory:   ${panel_dir}${plain}"
    echo -e "${green}Username:    ${config_username}${plain}"
    echo -e "${green}Password:    ${config_password}${plain}"
    echo -e "${green}Port:        ${config_port}${plain}"
    echo -e "${green}WebBasePath: ${config_webBasePath}${plain}"
    echo -e "${green}Access URL:  http://${server_ip}:${config_port}/${config_webBasePath}${plain}"
    echo -e "${green}═══════════════════════════════════════════${plain}"
    echo -e "${yellow}⚠ IMPORTANT: Save these credentials securely!${plain}"
    echo -e "${yellow}⚠ SSL Certificate: Managed through the 'x-ui' command menu.${plain}"
    echo -e "${yellow}To manage your panels, type: ${green}x-ui${plain}"
}

echo -e "${green}Running Docker-based Multi-Panel Installation...${plain}"
install_base
install_docker
setup_docker_panel
