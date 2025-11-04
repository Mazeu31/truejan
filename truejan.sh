#!/bin/bash
set -euo pipefail

# ========================
# Trojan Debian Auto Installer (Panel-ready, Expiration Support)
# ========================

TROJAN_PORT=2443
TROJAN_BIN_CANDIDATES=("/usr/bin/trojan" "/usr/local/bin/trojan" "/bin/trojan")
TROJAN_BIN=""
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
PANEL_USERS="$TROJAN_DIR/panel_users.json"
SERVICE_FILE="/etc/systemd/system/trojan.service"
MENU_PATH="/usr/local/bin/trojan-menu"

# Colors
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

[ "$(id -u)" -ne 0 ] && echo -e "${RED}Please run as root.${RESET}" && exit 1

echo -e "${CYAN}${BOLD}=== Trojan Debian Installer (Panel-ready) ===${RESET}"

# -------------------------
# Remove existing Trojan if found
# -------------------------
if command -v trojan >/dev/null 2>&1 || systemctl list-units --full -all | grep -q "trojan.service"; then
    echo -e "${YELLOW}Existing Trojan installation found. Removing...${RESET}"
    systemctl stop trojan || true
    systemctl disable trojan || true
    rm -f /etc/systemd/system/trojan.service
    rm -rf "$TROJAN_DIR" /usr/local/bin/trojan /usr/local/bin/trojan-menu
    systemctl daemon-reload
    echo -e "${GREEN}Old Trojan removed.${RESET}"
fi

# Install base packages
echo -e "${YELLOW}Installing base packages...${RESET}"
apt update -y
apt install -y wget curl xz-utils tar ca-certificates openssl python3 python3-pip ufw qrencode sudo jq sshpass || true
mkdir -p "$TROJAN_DIR"
chmod 755 "$TROJAN_DIR"

# Install trojan binary
for candidate in "${TROJAN_BIN_CANDIDATES[@]}"; do
  [ -x "$candidate" ] && TROJAN_BIN="$candidate" && break
done
[ -z "$TROJAN_BIN" ] && TROJAN_BIN=$(command -v trojan || true)

if [ -z "$TROJAN_BIN" ]; then
  echo -e "${YELLOW}Binary not found, downloading latest release...${RESET}"
  tmpfile="/tmp/trojan.tar.xz"
  LATEST_URL=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest \
    | grep browser_download_url | grep linux-amd64 | cut -d '"' -f4)
  curl -fsSL "$LATEST_URL" -o "$tmpfile"
  TMPDIR=$(mktemp -d)
  tar -xJf "$tmpfile" -C "$TMPDIR"
  cp "$TMPDIR/trojan" /usr/local/bin/trojan
  chmod +x /usr/local/bin/trojan
  TROJAN_BIN="/usr/local/bin/trojan"
  rm -rf "$TMPDIR" "$tmpfile"
  echo -e "${GREEN}Trojan binary installed.${RESET}"
else
  echo -e "${GREEN}Using trojan binary at $TROJAN_BIN${RESET}"
fi

# Generate self-signed certificate
IP=$(curl -s --max-time 10 ifconfig.me || hostname -I | awk '{print $1}')
[ -z "$IP" ] && echo -e "${RED}Cannot determine server IP.${RESET}" && exit 1
echo -e "${YELLOW}Generating self-signed certificate...${RESET}"
openssl req -new -x509 -days 3650 -nodes \
  -out "$TROJAN_DIR/server.crt" \
  -keyout "$TROJAN_DIR/server.key" \
  -subj "/CN=trojan-server" -addext "subjectAltName=IP:${IP}"
chmod 600 "$TROJAN_DIR/server.key"
chmod 644 "$TROJAN_DIR/server.crt"

# Create initial config & panel users file
mkdir -p "$(dirname "$PANEL_USERS")"
[ ! -f "$PANEL_USERS" ] && echo "{}" > "$PANEL_USERS"

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
  jq --arg p "$INIT_PASS" --arg e "$EXP_DATE" '. + {($p): {password:$p, expire:$e}}' "$PANEL_USERS" > "${PANEL_USERS}.tmp" && mv "${PANEL_USERS}.tmp" "$PANEL_USERS"
  echo -e "${GREEN}Initial user created.${RESET}"
fi

# Create systemd service
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
systemctl enable --now trojan || systemctl start trojan || true
ufw allow "$TROJAN_PORT"/tcp || true

# Trojan-menu (with panel_users.json update)
cat > "$MENU_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
CONFIG_FILE="/usr/local/etc/trojan/config.json"
PANEL_USERS="/usr/local/etc/trojan/panel_users.json"
TROJAN_PORT=2443

[ "$(id -u)" -ne 0 ] && exec sudo "$0" "$@"

add_user() {
  read -p "Enter new password: " NEWPASS
  read -p "Expire in how many days? " DAYS
  EXP_DATE=$(date -d "+$DAYS days" "+%Y-%m-%d")
  # Update config.json
  python3 - <<PY
import json
cfg="$CONFIG_FILE"
p="$NEWPASS"
exp="$EXP_DATE"
with open(cfg,'r') as f: j=json.load(f)
if "password" not in j: j["password"]=[]
if p not in j["password"]: j["password"].append(p)
with open(cfg,'w') as f: json.dump(j,f,indent=2)
PY
  # Update panel_users.json
  python3 - <<PY
import json
cfg="$PANEL_USERS"
p="$NEWPASS"
exp="$EXP_DATE"
try: u=json.load(open(cfg))
except: u={}
u[p]={"password":p,"expire":exp}
with open(cfg,'w') as f: json.dump(u,f,indent=2)
PY
  systemctl restart trojan
  echo -e "✅ User added: $NEWPASS (expires $EXP_DATE)"
}

list_users() {
  python3 - <<PY
import json,datetime
cfg="$PANEL_USERS"
today=datetime.date.today()
try: users=json.load(open(cfg))
except: users={}
for u,v in users.items():
    exp=datetime.datetime.strptime(v["expire"], "%Y-%m-%d").date()
    days_left=(exp-today).days
    status="expired" if days_left<0 else "active"
    print(f"{u} | {v['expire']} | {days_left if days_left>=0 else 0} days left | {status}")
PY
}

show_info() {
  echo -e "Server IP: $(curl -s ifconfig.me || hostname -I | awk '{print $1}')"
  echo -e "Port: $TROJAN_PORT"
  list_users
}

while true; do
  echo "1) Add user"
  echo "2) List users"
  echo "3) Show info"
  echo "0) Exit"
  read -p "Option: " opt
  case "$opt" in
    1) add_user ;;
    2) list_users ;;
    3) show_info ;;
    0) exit 0 ;;
  esac
done
EOF

chmod +x "$MENU_PATH"
CURRENT_USER=$(logname 2>/dev/null || echo root)
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: $MENU_PATH" > /etc/sudoers.d/trojan-menu-nopasswd
chmod 0440 /etc/sudoers.d
