#!/bin/bash
set -euo pipefail

# ---------------- CONFIG ----------------
TROJAN_PORT=2443
TROJAN_BIN_CANDIDATES=("/usr/bin/trojan" "/usr/local/bin/trojan" "/bin/trojan")
TROJAN_BIN=""
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/trojan.service"
MENU_PATH="/usr/local/bin/trojan-menu"
PANEL_DIR="/var/www/html"
ADMIN_DIR="$PANEL_DIR/admin"
SERVERS_FILE="$ADMIN_DIR/servers.json"
API_FILE="$ADMIN_DIR/api.php"
CREDS_FILE="$ADMIN_DIR/admin_credentials.json"

# ---------------- COLORS ----------------
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

# ---------------- ROOT CHECK ----------------
[ "$(id -u)" -ne 0 ] && echo -e "${RED}Please run as root${RESET}" && exit 1

echo -e "${CYAN}${BOLD}=== Trojan + Panel Installer ===${RESET}"

# ---------------- REMOVE OLD TROJAN ----------------
if command -v trojan >/dev/null 2>&1 || systemctl list-units --full -all | grep -q "trojan.service"; then
    echo -e "${YELLOW}Removing old Trojan...${RESET}"
    systemctl stop trojan || true
    systemctl disable trojan || true
    rm -f /etc/systemd/system/trojan.service
    rm -rf "$TROJAN_DIR" /usr/local/bin/trojan /usr/local/bin/trojan-menu
    systemctl daemon-reload
    echo -e "${GREEN}Old Trojan removed${RESET}"
fi

# ---------------- INSTALL DEPENDENCIES ----------------
apt update -y
apt install -y wget curl xz-utils tar ca-certificates openssl python3 python3-pip ufw qrencode sudo sshpass || true
mkdir -p "$TROJAN_DIR" "$ADMIN_DIR"
chmod 755 "$TROJAN_DIR" "$ADMIN_DIR"

# ---------------- INSTALL TROJAN ----------------
if apt-get -qq install -y trojan >/dev/null 2>&1; then
    echo -e "${GREEN}Trojan installed via apt${RESET}"
fi

# Locate binary
for candidate in "${TROJAN_BIN_CANDIDATES[@]}"; do [ -x "$candidate" ] && TROJAN_BIN="$candidate" && break; done
[ -z "$TROJAN_BIN" ] && TROJAN_BIN=$(command -v trojan || true)

if [ -z "$TROJAN_BIN" ]; then
    echo -e "${YELLOW}Downloading Trojan binary...${RESET}"
    tmpfile="/tmp/trojan.tar.xz"; rm -f "$tmpfile"
    LATEST_URL=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest | grep browser_download_url | grep linux-amd64 | cut -d '"' -f4)
    curl -fsSL "$LATEST_URL" -o "$tmpfile"
    TMPDIR=$(mktemp -d)
    tar -xJf "$tmpfile" -C "$TMPDIR"
    cp "$TMPDIR/trojan" /usr/local/bin/trojan
    chmod +x /usr/local/bin/trojan
    TROJAN_BIN="/usr/local/bin/trojan"
    rm -rf "$TMPDIR" "$tmpfile"
    echo -e "${GREEN}Trojan binary installed at $TROJAN_BIN${RESET}"
fi

# ---------------- TROJAN CONFIG ----------------
IP=$(curl -s --max-time 10 ifconfig.me || hostname -I | awk '{print $1}')
[ -z "$IP" ] && echo -e "${RED}Cannot detect server IP${RESET}" && exit 1

if [ ! -f "$CONFIG_FILE" ]; then
    read -p "Enter password for first user: " INIT_PASS
    read -p "Expire in how many days? " INIT_DAYS
    EXP_DATE=$(date -d "+$INIT_DAYS days" "+%Y-%m-%d")
    cat > "$CONFIG_FILE" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": $TROJAN_PORT,
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "users": [{"password":"$INIT_PASS","expire":"$EXP_DATE"}],
  "log_level":1,
  "ssl":{"cert":"$TROJAN_DIR/server.crt","key":"$TROJAN_DIR/server.key","verify":false},
  "udp":true
}
EOF
fi

# Self-signed cert
openssl req -new -x509 -days 3650 -nodes -out "$TROJAN_DIR/server.crt" -keyout "$TROJAN_DIR/server.key" -subj "/CN=trojan-server" -addext "subjectAltName=IP:${IP}"
chmod 600 "$TROJAN_DIR/server.key" && chmod 644 "$TROJAN_DIR/server.crt"

# ---------------- SYSTEMD SERVICE ----------------
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Trojan Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$TROJAN_BIN -c $CONFIG_FILE
Restart=on-failure
RestartSec=3s
LimitNOFILE=65536
ProtectSystem=full
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now trojan || systemctl start trojan
ufw allow "$TROJAN_PORT"/tcp || true

# ---------------- TROJAN-MENU ----------------
cat > "$MENU_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
TROJAN_PORT=2443

add_user(){
    read -p "Enter new password: " P
    read -p "Expire in how many days: " D
    python3 - <<PY
import json,datetime
cfg="$CONFIG_FILE"
p="$P"; days=int("$D")
exp=(datetime.date.today()+datetime.timedelta(days=days)).strftime("%Y-%m-%d")
with open(cfg,'r') as f: j=json.load(f)
if "users" not in j: j["users"]=[]
j["users"].append({"password":p,"expire":exp})
with open(cfg,'w') as f: json.dump(j,f,indent=2)
PY
    systemctl restart trojan
    echo "User added: $P, expires in $D days"
}

while true; do
echo "1) Add user"; echo "2) Exit"
read -p "Select: " o
case $o in
1) add_user ;;
2) exit 0 ;;
*) echo "Invalid" ;;
esac
done
EOF
chmod +x "$MENU_PATH"
echo "root ALL=(ALL) NOPASSWD: $MENU_PATH" > /etc/sudoers.d/trojan-menu-nopasswd
chmod 0440 /etc/sudoers.d/trojan-menu-nopasswd

# ---------------- REMOVE OLD PANEL ----------------
rm -rf "$ADMIN_DIR" "$PANEL_DIR/index.php"
mkdir -p "$ADMIN_DIR"
[ ! -f "$SERVERS_FILE" ] && echo '{}' > "$SERVERS_FILE"
[ ! -f "$CREDS_FILE" ] && echo '{"user":"admin","pass":"admin123"}' > "$CREDS_FILE"

# ---------------- END ----------------
echo -e "${GREEN}✅ Installation script syntax fixed!${RESET}"
echo -e "Run 'trojan-menu' to manage users manually."
echo -e "Admin panel: http://<YOUR-IP>/admin/"
echo -e "Public panel: http://<YOUR-IP>/"
echo -e "Default login: admin / admin123"
