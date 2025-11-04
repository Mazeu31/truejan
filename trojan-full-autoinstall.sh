#!/bin/bash
# =========================================================
# Trojan-GFW Auto Installer (No Domain)
# With Menu + Auto Command Shortcut
# By ChatGPT Edition
# =========================================================

set -e

# Colors
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

echo -e "${CYAN}=============================================${RESET}"
echo -e "${BOLD}${YELLOW}     TROJAN AUTO INSTALLER (No Domain)       ${RESET}"
echo -e "${CYAN}=============================================${RESET}"
echo

# Check root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo su)${RESET}"
  exit 1
fi

# Install dependencies
echo -e "${YELLOW}Installing dependencies...${RESET}"
apt update -y
apt install -y wget curl openssl xz-utils unzip ufw qrencode sudo

# Set vars
TROJAN_DIR="/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/trojan.service"
TROJAN_BIN="/usr/local/bin/trojan"
TROJAN_PORT=443
IP=$(curl -s ifconfig.me)

# Install Trojan binary
echo -e "${YELLOW}Installing Trojan binary...${RESET}"
LATEST_URL=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest | grep browser_download_url | grep linux-amd64 | cut -d '"' -f 4)
wget -O /tmp/trojan.tar.xz $LATEST_URL
tar -xJf /tmp/trojan.tar.xz -C /tmp
cp /tmp/trojan/trojan $TROJAN_BIN
chmod +x $TROJAN_BIN
mkdir -p $TROJAN_DIR

# Generate cert
echo -e "${YELLOW}Generating self-signed certificate...${RESET}"
openssl req -new -x509 -days 3650 -nodes \
  -out $TROJAN_DIR/server.crt \
  -keyout $TROJAN_DIR/server.key \
  -subj "/CN=trojan-server" -addext "subjectAltName=IP:${IP}"

# First user
echo
read -p "Enter initial password for first user: " INIT_PASS

# Config file
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

# Service file
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

# Create /usr/local/bin/trojan-menu
cat > /usr/local/bin/trojan-menu <<'MENU'
#!/bin/bash
# Trojan Menu

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"
TROJAN_DIR="/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
TROJAN_PORT=443

function banner() {
    clear
    echo -e "${CYAN}==============================================${RESET}"
    echo -e "${BOLD}${YELLOW}        TROJAN SERVER MANAGER (No Domain)     ${RESET}"
    echo -e "${CYAN}==============================================${RESET}"
    echo
}

function show_connection_info() {
    local password="$1"
    local ip=$(curl -s ifconfig.me)
    local link="trojan://${password}@${ip}:${TROJAN_PORT}?security=tls&type=tcp&allowInsecure=1"
    echo
    echo -e "${BOLD}${GREEN}✅ User Added:${RESET} ${CYAN}${password}${RESET}"
    echo -e "${YELLOW}------------------------------------------${RESET}"
    echo -e "Server IP : ${CYAN}${ip}${RESET}"
    echo -e "Port      : ${CYAN}${TROJAN_PORT}${RESET}"
    echo -e "Password  : ${CYAN}${password}${RESET}"
    echo -e "${YELLOW}------------------------------------------${RESET}"
    echo -e "${BOLD}Trojan Link:${RESET}"
    echo -e "${MAGENTA}${link}${RESET}"
    echo
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "${link}"
    fi
}

function add_user() {
    banner
    read -p "Enter new password to add: " NEWPASS
    sed -i "s/\(\"password\": \[\)/\1\"$NEWPASS\", /" $CONFIG_FILE
    systemctl restart trojan
    show_connection_info "$NEWPASS"
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

function list_users() {
    banner
    echo -e "${BOLD}${CYAN}Current Trojan Users:${RESET}"
    grep -oP '"\K[^"]+(?=")' $CONFIG_FILE | tail -n +2
    echo
    read -p "Press Enter to return..."
}

function show_info() {
    banner
    echo -e "${BOLD}Server Info:${RESET}"
    echo -e "IP Address: $(curl -s ifconfig.me)"
    echo -e "Port: ${TROJAN_PORT}"
    echo
    list_users
}

function restart_trojan() {
    systemctl restart trojan
    echo -e "${GREEN}Trojan restarted.${RESET}"
    sleep 1
}

function uninstall_trojan() {
    banner
    echo -e "${RED}Uninstalling Trojan...${RESET}"
    systemctl stop trojan
    systemctl disable trojan
    rm -rf /etc/trojan /usr/local/bin/trojan /etc/systemd/system/trojan.service
    systemctl daemon-reload
    echo -e "${RED}Removed.${RESET}"
    exit 0
}

while true; do
    banner
    echo -e "${BOLD}${GREEN}1)${RESET} Add user"
    echo -e "${BOLD}${GREEN}2)${RESET} Remove user"
    echo -e "${BOLD}${GREEN}3)${RESET} List users"
    echo -e "${BOLD}${GREEN}4)${RESET} Show server info"
    echo -e "${BOLD}${GREEN}5)${RESET} Restart Trojan"
    echo -e "${BOLD}${RED}6)${RESET} Uninstall Trojan"
    echo -e "${BOLD}${CYAN}0)${RESET} Exit"
    echo
    read -p "Select option: " opt
    case $opt in
        1) add_user ;;
        2) remove_user ;;
        3) list_users ;;
        4) show_info ;;
        5) restart_trojan ;;
        6) uninstall_trojan ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Invalid option!${RESET}"; sleep 1 ;;
    esac
done
MENU

chmod +x /usr/local/bin/trojan-menu

# Allow user to run trojan-menu without password
USERNAME=$(logname)
echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/local/bin/trojan-menu" > /etc/sudoers.d/trojan-menu-nopasswd

clear
echo -e "${GREEN}✅ Trojan installed successfully!${RESET}"
echo
echo -e "${YELLOW}You can now type:${RESET} ${BOLD}trojan-menu${RESET}"
echo -e "No sudo required — manage users and configs easily."
echo
