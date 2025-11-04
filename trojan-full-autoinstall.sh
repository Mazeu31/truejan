#!/bin/bash
set -euo pipefail

# Troja n autoscript for Debian
# - standard config dir: /usr/local/etc/trojan
# - port: 2443
# - creates /usr/local/bin/trojan-menu and sudoers NOPASSWD entry
# - edits config safely using python3 json

TROJAN_PORT=2443
TROJAN_BIN="/usr/local/bin/trojan"
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/trojan.service"
MENU_PATH="/usr/local/bin/trojan-menu"

# Colors
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Please run this script as root (sudo).${RESET}"
  exit 1
fi

echo -e "${CYAN}${BOLD}=== Trojan Debian Auto Installer ===${RESET}"
echo

# Install packages
echo -e "${YELLOW}Installing packages...${RESET}"
apt update -y
apt install -y wget curl xz-utils tar ca-certificates openssl python3 python3-pip ufw qrencode sudo || true

# Create needed dirs
mkdir -p "$TROJAN_DIR"
chmod 755 "$TROJAN_DIR"

# Fetch latest trojan linux-amd64 release (with retries)
echo -e "${YELLOW}Downloading latest Trojan release...${RESET}"
attempt=0
max_attempts=4
tmpfile="/tmp/trojan.tar.xz"
rm -f "$tmpfile"
while [ $attempt -lt $max_attempts ]; do
  attempt=$((attempt+1))
  echo "  try #$attempt..."
  LATEST_URL=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest \
    | grep browser_download_url \
    | grep linux-amd64 \
    | cut -d '"' -f 4 || true)
  if [ -z "$LATEST_URL" ]; then
    echo "  Could not find release URL (API may be rate-limited). Retrying..."
    sleep 2
    continue
  fi

  # Use curl -L to follow redirects
  curl -fsSL "$LATEST_URL" -o "$tmpfile" && break
  echo "  download failed or archive corrupt; retrying..."
  rm -f "$tmpfile"
  sleep 2
done

if [ ! -f "$tmpfile" ]; then
  echo -e "${RED}Failed to download trojan release after $max_attempts attempts.${RESET}"
  exit 1
fi

# Extract and install binary
echo -e "${YELLOW}Extracting trojan binary...${RESET}"
# create temp dir
TMPDIR=$(mktemp -d)
tar -xJf "$tmpfile" -C "$TMPDIR"
if [ ! -f "$TMPDIR/trojan" ]; then
  echo -e "${RED}Trojan binary not found in archive. Aborting.${RESET}"
  rm -rf "$TMPDIR" "$tmpfile"
  exit 1
fi
cp "$TMPDIR/trojan" "$TROJAN_BIN"
chmod +x "$TROJAN_BIN"
rm -rf "$TMPDIR" "$tmpfile"

# Generate self-signed cert (with IP SAN)
IP=$(curl -s --max-time 10 ifconfig.me || true)
if [ -z "$IP" ]; then
  # fallback to first public address
  IP=$(hostname -I | awk '{print $1}')
fi
if [ -z "$IP" ]; then
  echo -e "${RED}Unable to determine public IP. Please ensure network access.${RESET}"
  exit 1
fi

echo -e "${YELLOW}Generating self-signed certificate for IP ${IP} ...${RESET}"
openssl req -new -x509 -days 3650 -nodes \
  -out "$TROJAN_DIR/server.crt" \
  -keyout "$TROJAN_DIR/server.key" \
  -subj "/CN=trojan-server" -addext "subjectAltName=IP:${IP}"

chmod 600 "$TROJAN_DIR/server.key"
chmod 644 "$TROJAN_DIR/server.crt"

# If config doesn't exist, create initial config (ask user for initial password)
if [ ! -f "$CONFIG_FILE" ]; then
  echo
  read -p "Enter initial password for first user: " INIT_PASS
  cat > "$CONFIG_FILE" <<EOF
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
  echo -e "${GREEN}Created initial config with one user.${RESET}"
fi

# Create systemd service (points to /usr/local/etc config)
cat > "$SERVICE_FILE" <<EOF
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
systemctl enable --now trojan || systemctl start trojan || true

# Open firewall port
ufw allow "$TROJAN_PORT"/tcp || true

# Create trojan-menu (uses python3 to manipulate JSON safely)
cat > "$MENU_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail

TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
TROJAN_PORT=2443

# Colors
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

# Ensure script re-exec as root with sudo if not root (this will not prompt if sudoers NOPASSWD set)
if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

function banner() {
  clear
  echo -e "${CYAN}==============================================${RESET}"
  echo -e "${BOLD}${YELLOW}        TROJAN SERVER MANAGER (No Domain)     ${RESET}"
  echo -e "${CYAN}==============================================${RESET}"
  echo
}

function list_users() {
  # Only print user passwords, one per line (no other info)
  python3 - <<PY
import json,sys
cfg="$CONFIG_FILE"
try:
    with open(cfg,'r') as f:
        j=json.load(f)
    pw=j.get("password",[])
    for p in pw:
        print(p)
except Exception as e:
    sys.exit(0)
PY
}

function add_user() {
  read -p "Enter new password to add: " NEWPASS
  python3 - <<PY
import json,sys
cfg="$CONFIG_FILE"
p="$NEWPASS"
with open(cfg,'r') as f:
    j=json.load(f)
pw=j.get("password",[])
if p in pw:
    print("Password already exists.")
    sys.exit(0)
pw.append(p)
j["password"]=pw
with open(cfg,'w') as f:
    json.dump(j,f,indent=2)
print(p)
PY
  systemctl restart trojan
  # show connection info
  IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
  link="trojan://${NEWPASS}@${IP}:${TROJAN_PORT}?security=tls&type=tcp&allowInsecure=1"
  echo
  echo -e "${GREEN}✅ User added:${RESET} ${CYAN}${NEWPASS}${RESET}"
  echo -e "${YELLOW}Server IP:${RESET} ${IP}"
  echo -e "${YELLOW}Port:${RESET} ${TROJAN_PORT}"
  echo -e "${YELLOW}Link:${RESET} ${link}"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "${link}"
  else
    echo -e "${RED}Install qrencode to show QR code (sudo apt install -y qrencode)${RESET}"
  fi
  read -p "Press Enter to return..."
}

function remove_user() {
  read -p "Enter password to remove: " REMPASS
  python3 - <<PY
import json,sys
cfg="$CONFIG_FILE"
p="$REMPASS"
with open(cfg,'r') as f:
    j=json.load(f)
pw=j.get("password",[])
if p in pw:
    pw=[x for x in pw if x!=p]
    j["password"]=pw
    with open(cfg,'w') as f:
        json.dump(j,f,indent=2)
    print("removed")
else:
    print("notfound")
PY
  systemctl restart trojan
  echo -e "${RED}Removed (if existed):${RESET} ${REMPASS}"
  read -p "Press Enter to return..."
}

function show_info() {
  echo
  echo -e "${YELLOW}Server IP:${RESET} $(curl -s ifconfig.me || hostname -I | awk '{print $1}')"
  echo -e "${YELLOW}Port:${RESET} ${TROJAN_PORT}"
  echo -e "${YELLOW}Users (passwords only):${RESET}"
  list_users
  echo
  read -p "Press Enter to return..."
}

function restart_trojan() {
  systemctl restart trojan
  echo -e "${GREEN}Trojan restarted.${RESET}"
  sleep 1
}

function uninstall() {
  read -p "Are you sure you want to uninstall trojan and remove configs? (yes/NO): " ans
  if [ "$ans" = "yes" ]; then
    systemctl stop trojan || true
    systemctl disable trojan || true
    rm -f /etc/systemd/system/trojan.service
    rm -rf /usr/local/etc/trojan /usr/local/bin/trojan /usr/local/bin/trojan-menu
    systemctl daemon-reload
    echo -e "${RED}Trojan and menu removed.${RESET}"
    exit 0
  fi
}

# Menu loop
while true; do
  banner
  echo -e "${GREEN}1)${RESET} Add user"
  echo -e "${GREEN}2)${RESET} Remove user"
  echo -e "${GREEN}3)${RESET} List users (passwords only)"
  echo -e "${GREEN}4)${RESET} Show server info"
  echo -e "${GREEN}5)${RESET} Restart trojan"
  echo -e "${RED}6)${RESET} Uninstall trojan"
  echo -e "${CYAN}0)${RESET} Exit"
  echo
  read -p "Select option: " opt
  case "$opt" in
    1) add_user ;;
    2) remove_user ;;
    3) list_users ; read -p "Press Enter to return..." ;;
    4) show_info ;;
    5) restart_trojan ;;
    6) uninstall ;;
    0) exit 0 ;;
    *) echo -e "${RED}Invalid option${RESET}"; sleep 1 ;;
  esac
done
EOF

chmod +x "$MENU_PATH"

# Add sudoers NOPASSWD entry for current login user to run trojan-menu
CURRENT_USER=$(logname 2>/dev/null || echo root)
SUDOERS_FILE="/etc/sudoers.d/trojan-menu-nopasswd"
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: $MENU_PATH" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"

echo
echo -e "${GREEN}=== Installation complete ===${RESET}"
echo -e "Command: ${BOLD}trojan-menu${RESET}"
echo -e "Config dir: ${TROJAN_DIR}"
echo -e "Port: ${TROJAN_PORT}"
echo -e "Server IP: ${IP}"
echo
echo "Run 'trojan-menu' to manage users."
