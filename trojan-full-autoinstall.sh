#!/bin/bash
set -euo pipefail

# ========================
# Trojan Debian Auto Installer (Idempotent, Expiration Support)
# ========================

TROJAN_PORT=2443
TROJAN_BIN_CANDIDATES=("/usr/bin/trojan" "/usr/local/bin/trojan" "/bin/trojan")
TROJAN_BIN=""
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/trojan.service"
MENU_PATH="/usr/local/bin/trojan-menu"

# Colors
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo).${RESET}"
  exit 1
fi

echo -e "${CYAN}${BOLD}=== Trojan Debian Installer (Idempotent) ===${RESET}"

# -------------------------
# Remove existing Trojan if found
# -------------------------
if command -v trojan >/dev/null 2>&1 || systemctl list-units --full -all | grep -q "trojan.service"; then
    echo -e "${YELLOW}Existing Trojan installation found. Removing...${RESET}"
    systemctl stop trojan || true
    systemctl disable trojan || true
    rm -f /etc/systemd/system/trojan.service
    rm -rf /usr/local/etc/trojan /usr/local/bin/trojan /usr/local/bin/trojan-menu
    systemctl daemon-reload
    echo -e "${GREEN}Old Trojan installation removed.${RESET}"
fi

# Install base packages
echo -e "${YELLOW}Installing base packages...${RESET}"
apt update -y
apt install -y wget curl xz-utils tar ca-certificates openssl python3 python3-pip ufw qrencode sudo || true
mkdir -p "$TROJAN_DIR"
chmod 755 "$TROJAN_DIR"

# Install trojan via apt
echo -e "${YELLOW}Attempting to install 'trojan' via apt...${RESET}"
if apt-get -qq install -y trojan >/dev/null 2>&1; then
  echo -e "${GREEN}Installed 'trojan' package via apt.${RESET}"
fi

# Locate binary
for candidate in "${TROJAN_BIN_CANDIDATES[@]}"; do
  [ -x "$candidate" ] && TROJAN_BIN="$candidate" && break
done
[ -z "$TROJAN_BIN" ] && TROJAN_BIN=$(command -v trojan || true)

# Fallback to GitHub release if binary not found
if [ -z "$TROJAN_BIN" ]; then
  echo -e "${YELLOW}Binary not found, downloading latest release...${RESET}"
  tmpfile="/tmp/trojan.tar.xz"
  attempt=0; max_attempts=4; rm -f "$tmpfile"
  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt+1))
    LATEST_URL=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest \
      | grep browser_download_url | grep linux-amd64 | cut -d '"' -f4 || true)
    [ -z "$LATEST_URL" ] && sleep 2 && continue
    curl -fsSL "$LATEST_URL" -o "$tmpfile" && break
    rm -f "$tmpfile"
    sleep 2
  done
  [ ! -f "$tmpfile" ] && echo -e "${RED}Failed to download trojan.${RESET}" && exit 1
  TMPDIR=$(mktemp -d)
  tar -xJf "$tmpfile" -C "$TMPDIR"
  cp "$TMPDIR/trojan" /usr/local/bin/trojan
  chmod +x /usr/local/bin/trojan
  TROJAN_BIN="/usr/local/bin/trojan"
  rm -rf "$TMPDIR" "$tmpfile"
  echo -e "${GREEN}Trojan binary installed to $TROJAN_BIN${RESET}"
else
  echo -e "${GREEN}Using trojan binary at $TROJAN_BIN${RESET}"
fi

# Generate self-signed cert
IP=$(curl -s --max-time 10 ifconfig.me || hostname -I | awk '{print $1}')
[ -z "$IP" ] && echo -e "${RED}Cannot determine server IP.${RESET}" && exit 1
echo -e "${YELLOW}Generating self-signed certificate for IP $IP ...${RESET}"
openssl req -new -x509 -days 3650 -nodes \
  -out "$TROJAN_DIR/server.crt" \
  -keyout "$TROJAN_DIR/server.key" \
  -subj "/CN=trojan-server" -addext "subjectAltName=IP:${IP}"
chmod 600 "$TROJAN_DIR/server.key"
chmod 644 "$TROJAN_DIR/server.crt"

# Create initial config with users list
if [ ! -f "$CONFIG_FILE" ]; then
  echo
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
  "users": [
    {
      "password": "$INIT_PASS",
      "expire": "$EXP_DATE"
    }
  ],
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

# Create systemd service (runs as root)
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

# Open firewall port
ufw allow "$TROJAN_PORT"/tcp || true

# Create updated trojan-menu (password + expiration)
cat > "$MENU_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
TROJAN_PORT=2443
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

[ "$(id -u)" -ne 0 ] && exec sudo "$0" "$@"

banner() { clear; echo -e "${CYAN}=== TROJAN SERVER MANAGER ===${RESET}"; echo; }

add_user() {
  read -p "Enter new password: " NEWPASS
  read -p "Expire in how many days? " DAYS
  python3 - <<PY
import json,datetime
cfg="$CONFIG_FILE"
p="$NEWPASS"
days=int("$DAYS")
exp_date=(datetime.date.today() + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
try:
    with open(cfg,'r') as f: j=json.load(f)
except:
    j={}
if "users" not in j: j["users"]=[]
j["users"].append({"password": p, "expire": exp_date})
with open(cfg,'w') as f: json.dump(j,f,indent=2)
PY
  systemctl restart trojan
  echo -e "${GREEN}✅ User added: ${CYAN}${NEWPASS}${RESET}, expires in ${DAYS} days"
  read -p "Press Enter to return..."
}

list_users() {
  python3 - <<PY
import json,datetime
cfg="$CONFIG_FILE"
today=datetime.date.today()
try:
    with open(cfg,'r') as f: j=json.load(f)
    users=j.get("users",[])
except:
    users=[]
if not users:
    print("No users found.")
else:
    for u in users:
        exp=datetime.datetime.strptime(u["expire"], "%Y-%m-%d").date()
        days_left=(exp-today).days
        status="expired" if days_left<0 else "active"
        print(f"{u['password']} | {u['expire']} | {days_left if days_left>=0 else 0} days left | {status}")
PY
  read -p "Press Enter to return..."
}

remove_user() {
  read -p "Enter password to remove: " REMPASS
  python3 - <<PY
import json
cfg="$CONFIG_FILE";p="$REMPASS"
with open(cfg,'r') as f: j=json.load(f)
users=j.get("users",[])
users=[u for u in users if u["password"]!=p]
j["users"]=users
with open(cfg,'w') as f: import json; json.dump(j,f,indent=2)
PY
  systemctl restart trojan
  echo -e "${RED}Removed (if existed): ${REMPASS}${RESET}"
  read -p "Press Enter to return..."
}

show_info() {
  echo -e "Server IP: $(curl -s ifconfig.me || hostname -I | awk '{print $1}')"
  echo -e "Port: $TROJAN_PORT"
  echo -e "Users:"
  list_users
}

restart_trojan() {
  systemctl restart trojan
  echo -e "${GREEN}Trojan restarted.${RESET}"
  sleep 1
}

uninstall() {
  read -p "Uninstall trojan? (yes/NO): " ans
  [ "$ans" = "yes" ] || return
  systemctl stop trojan || true
  systemctl disable trojan || true
  rm -f /etc/systemd/system/trojan.service
  rm -rf /usr/local/etc/trojan /usr/local/bin/trojan /usr/local/bin/trojan-menu
  systemctl daemon-reload
  echo -e "${RED}Trojan removed.${RESET}"
  exit 0
}

while true; do
  banner
  echo -e "${GREEN}1)${RESET} Add user"
  echo -e "${GREEN}2)${RESET} Remove user"
  echo -e "${GREEN}3)${RESET} List users"
  echo -e "${GREEN}4)${RESET} Show server info"
  echo -e "${GREEN}5)${RESET} Restart trojan"
  echo -e "${RED}6)${RESET} Uninstall trojan"
  echo -e "${CYAN}0)${RESET} Exit"
  read -p "Select option: " opt
  case "$opt" in
    1) add_user ;;
    2) remove_user ;;
    3) list_users ;;
    4) show_info ;;
    5) restart_trojan ;;
    6) uninstall ;;
    0) exit 0 ;;
    *) echo -e "${RED}Invalid option${RESET}"; sleep 1 ;;
  esac
done
EOF

chmod +x "$MENU_PATH"
CURRENT_USER=$(logname 2>/dev/null || echo root)
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: $MENU_PATH" > /etc/sudoers.d/trojan-menu-nopasswd
chmod 0440 /etc/sudoers.d/trojan-menu-nopasswd

echo -e "${GREEN}=== Installation complete ===${RESET}"
echo -e "Run '${BOLD}trojan-menu${RESET}' to manage users with expiration."
