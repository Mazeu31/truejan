#!/bin/bash
# =========================================================
# Trojan (trojan-gfw) Manager - No Domain version
# Compatible with Debian/Ubuntu
# =========================================================

# --- Auto elevate to root ---
if [ "$EUID" -ne 0 ]; then
  sudo "$0" "$@"
  exit $?
fi

# --- Colors ---
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

TROJAN_DIR="/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/trojan.service"
TROJAN_BIN="/usr/local/bin/trojan"
TROJAN_PORT=443

# =========================================================
# Functions
# =========================================================
function banner() {
    clear
    echo -e "${CYAN}==============================================${RESET}"
    echo -e "${BOLD}${YELLOW}        TROJAN SERVER MANAGER (No Domain)     ${RESET}"
    echo -e "${CYAN}==============================================${RESET}"
    echo
}

function install_trojan() {
    banner
    echo -e "${BOLD}${GREEN}Installing Trojan...${RESET}"
    apt update -y
    apt install -y wget curl openssl xz-utils unzip ufw

    echo -e "${YELLOW}Downloading Trojan binary...${RESET}"
    LATEST_URL=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest | grep browser_download_url | grep linux-amd64 | cut -d '"' -f 4)
    wget -O /tmp/trojan.tar.xz $LATEST_URL
    tar -xJf /tmp/trojan.tar.xz -C /tmp
    cp /tmp/trojan/trojan $TROJAN_BIN
    chmod +x $TROJAN_BIN

    mkdir -p $TROJAN_DIR

    echo -e "${YELLOW}Generating self-signed certificate...${RESET}"
    openssl req -new -x509 -days 3650 -nodes \
      -out $TROJAN_DIR/server.crt \
      -keyout $TROJAN_DIR/server.key \
      -subj "/CN=trojan-server" -addext "subjectAltName=IP:$(curl -s ifconfig.me)"

    echo
    read -p "Enter initial password: " INIT_PASS

    cat > $CONFIG_FILE <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": $TROJAN_PORT,
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["$INIT_PASS"],
  "log_level": 1,
  "ssl": {
    "cert": "$TROJAN_DIR/server.crt",
    "key": "$TROJAN_DIR/server.key",
    "verify": false
  },
  "udp": true
}
EOF

    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Trojan Service
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=$TROJAN_BIN -c $CONFIG_FILE
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now trojan
    ufw allow ${TROJAN_PORT}/tcp || true

    echo
    echo -e "${GREEN}Trojan installed successfully!${RESET}"
    echo -e "${YELLOW}------------------------------------------${RESET}"
    echo -e "${BOLD}Server IP:${RESET} $(curl -s ifconfig.me)"
    echo -e "${BOLD}Port:${RESET} $TROJAN_PORT"
    echo -e "${BOLD}Password:${RESET} $INIT_PASS"
    echo -e "${YELLOW}------------------------------------------${RESET}"
    echo -e "Use these settings in Passwall (Trojan):"
    echo -e "  ${BOLD}Address:${RESET} Your server IP"
    echo -e "  ${BOLD}Port:${RESET} 443"
    echo -e "  ${BOLD}Password:${RESET} $INIT_PASS"
    echo -e "  ${BOLD}Skip TLS Verify:${RESET} ENABLED"
    echo
    read -p "Press Enter to return to menu..."
}

function list_users() {
    banner
    echo -e "${BOLD}${CYAN}Current Trojan Users:${RESET}"
    grep -oP '"\K[^"]+(?=")' $CONFIG_FILE | tail -n +2 | nl -w2 -s". "
    echo
    read -p "Press Enter to return..."
}

function add_user() {
    banner
    read -p "Enter new password to add: " NEWPASS
    sed -i "s/\(\"password\": \[\)/\1\"$NEWPASS\", /" $CONFIG_FILE
    systemctl restart trojan
    echo -e "${GREEN}User added successfully:${RESET} $NEWPASS"
    read -p "Press Enter to return..."
}

function remove_user() {
    banner
    read -p "Enter password to remove: " REMPASS
    sed -i "/\"$REMPASS\"/d" $CONFIG_FILE
    systemctl restart trojan
    echo -e "${RED}User removed:${RESET} $REMPASS"
    read -p "Press Enter to return..."
}

function restart_trojan() {
    banner
    systemctl restart trojan
    echo -e "${GREEN}Trojan service restarted.${RESET}"
    read -p "Press Enter to return..."
}

function uninstall_trojan() {
    banner
    echo -e "${RED}Uninstalling Trojan...${RESET}"
    systemctl stop trojan
    systemctl disable trojan
    rm -f $SERVICE_FILE
    rm -rf $TROJAN_DIR
    rm -f $TROJAN_BIN
    systemctl daemon-reload
    echo -e "${RED}Trojan has been completely removed.${RESET}"
    read -p "Press Enter to exit..."
    exit 0
}

function show_info() {
    banner
    echo -e "${BOLD}Server Info:${RESET}"
    echo -e "${YELLOW}------------------------------------${RESET}"
    echo -e "IP Address : ${CYAN}$(curl -s ifconfig.me)${RESET}"
    echo -e "Port       : ${CYAN}$TROJAN_PORT${RESET}"
    echo -e "Users: ${CYAN}"
    grep -oP '"\K[^"]+(?=")' $CONFIG_FILE | tail -n +2 | nl -w2 -s". "
    echo -e "${RESET}${YELLOW}------------------------------------${RESET}"
    read -p "Press Enter to return..."
}

# =========================================================
# Menu loop
# =========================================================
while true; do
    banner
    echo -e "${BOLD}${GREEN}1)${RESET} Install Trojan"
    echo -e "${BOLD}${GREEN}2)${RESET} Add new user"
    echo -e "${BOLD}${GREEN}3)${RESET} Remove user"
    echo -e "${BOLD}${GREEN}4)${RESET} List users"
    echo -e "${BOLD}${GREEN}5)${RESET} Show server info"
    echo -e "${BOLD}${GREEN}6)${RESET} Restart Trojan"
    echo -e "${BOLD}${RED}7)${RESET} Uninstall Trojan"
    echo -e "${BOLD}${CYAN}0)${RESET} Exit"
    echo
    read -p "Select option: " opt
    case $opt in
        1) install_trojan ;;
        2) add_user ;;
        3) remove_user ;;
        4) list_users ;;
        5) show_info ;;
        6) restart_trojan ;;
        7) uninstall_trojan ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Invalid option!${RESET}"; sleep 1 ;;
    esac
done
