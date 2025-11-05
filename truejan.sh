#!/bin/bash
set -euo pipefail

# Troja n Installer (Debian) - Force apt install trojan + menu + expiry
TROJAN_PORT=2443
TROJAN_DIR="/usr/local/etc/trojan"
USERS_FILE="$TROJAN_DIR/users.json"
CONFIG_FILE="$TROJAN_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/trojan.service"
MENU_PATH="/usr/local/bin/trojan-menu"
SUDOERS_FILE="/etc/sudoers.d/trojan-menu-nopasswd"

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Run this script as root (sudo).${RESET}"
  exit 1
fi

echo -e "${CYAN}${BOLD}=== Trojan Installer (Force apt, expiration + menu) ===${RESET}"

# 1) stop/remove previous installation if exists
echo -e "${YELLOW}Cleaning previous Trojan installation (if any)...${RESET}"
systemctl stop trojan.service >/dev/null 2>&1 || true
systemctl disable trojan.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/trojan.service
rm -f "$MENU_PATH" "$SUDOERS_FILE"
# Do not remove users.json automatically; remove directories to be safe only if present and user confirms later

# 2) install required packages and trojan via apt (force)
echo -e "${YELLOW}Updating apt and installing packages (this may prompt)...${RESET}"
apt update -y
apt install -y wget curl xz-utils tar ca-certificates openssl python3 jq ufw qrencode sudo

echo -e "${YELLOW}Installing trojan via apt (forced)...${RESET}"
if ! apt-get install -y trojan; then
  echo -e "${RED}apt install trojan failed. Aborting. If your Debian repo doesn't have trojan, install it manually or add appropriate repo.${RESET}"
  exit 1
fi

# 3) detect trojan binary
TROJAN_BIN=$(command -v trojan || true)
if [ -z "$TROJAN_BIN" ]; then
  echo -e "${RED}Trojan binary not found after apt install. Aborting.${RESET}"
  exit 1
fi
echo -e "${GREEN}Trojan binary detected at: ${TROJAN_BIN}${RESET}"

# 4) create directories
mkdir -p "$TROJAN_DIR"
chmod 755 "$TROJAN_DIR"

# 5) generate self-signed certificate (IP SAN)
IP=$(curl -s --max-time 10 ifconfig.me || hostname -I | awk '{print $1}')
if [ -z "$IP" ]; then
  echo -e "${RED}Cannot detect public IP. Set IP manually in script or ensure network access.${RESET}"
  exit 1
fi
echo -e "${YELLOW}Generating self-signed certificate for IP ${IP} ...${RESET}"
openssl req -new -x509 -days 3650 -nodes \
  -out "$TROJAN_DIR/server.crt" \
  -keyout "$TROJAN_DIR/server.key" \
  -subj "/CN=trojan-server" -addext "subjectAltName=IP:${IP}"
chmod 600 "$TROJAN_DIR/server.key"
chmod 644 "$TROJAN_DIR/server.crt"

# 6) initialize users.json and config.json if missing
if [ ! -f "$USERS_FILE" ]; then
  echo -e "${YELLOW}No users file found. Creating initial user...${RESET}"
  read -p "Enter initial password: " INIT_PASS
  read -p "Expire in how many days? " INIT_DAYS
  EXP_DATE=$(date -d "+$INIT_DAYS days" "+%Y-%m-%d")
  cat > "$USERS_FILE" <<EOF
[
  {
    "password": "$INIT_PASS",
    "expire": "$EXP_DATE"
  }
]
EOF
  echo -e "${GREEN}Created $USERS_FILE with initial user.${RESET}"
fi

# Helper: rebuild trojan config.json from users.json (password array)
rebuild_config() {
  python3 - "$USERS_FILE" "$CONFIG_FILE" "$TROJAN_DIR" "$TROJAN_PORT" <<'PY'
import json,sys
users_file=sys.argv[1]; conf_file=sys.argv[2]; trojan_dir=sys.argv[3]; port=int(sys.argv[4])
try:
    with open(users_file,'r') as f:
        users=json.load(f)
except:
    users=[]
passwords=[u.get("password") for u in users if "password" in u]
cfg = {
  "run_type":"server",
  "local_addr":"0.0.0.0",
  "local_port": port,
  "remote_addr":"127.0.0.1",
  "remote_port":80,
  "password": passwords,
  "log_level":1,
  "ssl":{
    "cert": f"{trojan_dir}/server.crt",
    "key": f"{trojan_dir}/server.key",
    "verify": False
  },
  "udp": True
}
with open(conf_file,'w') as f:
    json.dump(cfg,f,indent=2)
PY
}

rebuild_config

# 7) create systemd service using detected binary
echo -e "${YELLOW}Creating systemd service (using detected trojan binary)...${RESET}"
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

# 8) open firewall port
ufw allow "$TROJAN_PORT"/tcp || true

# 9) create trojan-menu (manages users.json then rebuilds config.json)
cat > "$MENU_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
TROJAN_DIR="/usr/local/etc/trojan"
USERS_FILE="$TROJAN_DIR/users.json"
CONFIG_FILE="$TROJAN_DIR/config.json"
TROJAN_PORT=2443
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

[ "$(id -u)" -ne 0 ] && exec sudo "$0" "$@"

banner() { clear; echo -e "${CYAN}=== TROJAN SERVER MANAGER ===${RESET}"; echo; }

rebuild_config() {
  python3 - "$USERS_FILE" "$CONFIG_FILE" "$TROJAN_DIR" "$TROJAN_PORT" <<'PY'
import json,sys
users_file=sys.argv[1]; conf_file=sys.argv[2]; trojan_dir=sys.argv[3]; port=int(sys.argv[4])
try:
    with open(users_file,'r') as f:
        users=json.load(f)
except:
    users=[]
passwords=[u.get("password") for u in users if "password" in u]
cfg = {
  "run_type":"server",
  "local_addr":"0.0.0.0",
  "local_port": port,
  "remote_addr":"127.0.0.1",
  "remote_port":80,
  "password": passwords,
  "log_level":1,
  "ssl":{
    "cert": f"{trojan_dir}/server.crt",
    "key": f"{trojan_dir}/server.key",
    "verify": False
  },
  "udp": True
}
with open(conf_file,'w') as f:
    json.dump(cfg,f,indent=2)
PY
}

add_user() {
  read -p "Enter new password: " NEWPASS
  read -p "Expire in how many days? " DAYS
  python3 - "$USERS_FILE" "$NEWPASS" "$DAYS" <<'PY'
import json,sys,datetime
users_file=sys.argv[1]; p=sys.argv[2]; days=int(sys.argv[3])
try:
    with open(users_file,'r') as f:
        users=json.load(f)
except:
    users=[]
exp_date=(datetime.date.today()+datetime.timedelta(days=days)).strftime("%Y-%m-%d")
users.append({"password":p,"expire":exp_date})
with open(users_file,'w') as f:
    json.dump(users,f,indent=2)
print(p,exp_date)
PY
  rebuild_config
  systemctl restart trojan
  IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
  link="trojan://${NEWPASS}@${IP}:${TROJAN_PORT}?security=tls&type=tcp&allowInsecure=1"
  echo -e "${GREEN}User added:${RESET} ${CYAN}${NEWPASS}${RESET} (expires in ${DAYS} days)"
  echo -e "Link: ${link}"
  if command -v qrencode >/dev/null 2>&1; then qrencode -t ANSIUTF8 "${link}"; fi
  read -p "Press Enter to return..."
}

list_users() {
  python3 - <<'PY'
import json,datetime,sys
users_file="/usr/local/etc/trojan/users.json"
today=datetime.date.today()
try:
    with open(users_file,'r') as f:
        users=json.load(f)
except:
    users=[]
if not users:
    print("No users found.")
else:
    for u in users:
        pw=u.get("password","")
        exp=u.get("expire","1970-01-01")
        try:
            ed=datetime.datetime.strptime(exp,"%Y-%m-%d").date()
            days_left=(ed-today).days
            if days_left < 0:
                days_left=0
                status="expired"
            else:
                status="active"
        except:
            days_left="?"
            status="unknown"
        print(f"{pw} | {exp} | {days_left} days left | {status}")
PY
  read -p "Press Enter to return..."
}

remove_user() {
  read -p "Enter password to remove: " REMPASS
  python3 - "$USERS_FILE" "$REMPASS" <<'PY'
import json,sys
users_file=sys.argv[1]; p=sys.argv[2]
try:
    with open(users_file,'r') as f:
        users=json.load(f)
except:
    users=[]
new=[u for u in users if u.get("password")!=p]
with open(users_file,'w') as f:
    json.dump(new,f,indent=2)
print("done")
PY
  rebuild_config
  systemctl restart trojan
  echo -e "${RED}Removed (if existed): ${REMPASS}${RESET}"
  read -p "Press Enter to return..."
}

show_info() {
  echo -e "Server IP: $(curl -s ifconfig.me || hostname -I | awk '{print $1}')"
  echo -e "Port: ${TROJAN_PORT}"
  echo -e "Users:"
  list_users
}

restart_trojan() {
  systemctl restart trojan
  echo -e "${GREEN}Trojan restarted.${RESET}"
  sleep 1
}

uninstall() {
  read -p "Uninstall trojan and remove configs? (yes/NO): " ans
  [ "$ans" = "yes" ] || return
  systemctl stop trojan || true
  systemctl disable trojan || true
  rm -f /etc/systemd/system/trojan.service
  rm -rf /usr/local/etc/trojan $(command -v trojan || true) /usr/local/bin/trojan-menu
  systemctl daemon-reload
  echo -e "${RED}Trojan removed.${RESET}"
  exit 0
}

# Menu loop
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

# 10) make menu executable and allow nopass sudo
chmod +x "$MENU_PATH"
CURRENT_USER=$(logname 2>/dev/null || echo root)
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: $MENU_PATH" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"

echo -e "${GREEN}=== Installation complete ===${RESET}"
echo -e "Run '${BOLD}trojan-menu${RESET}' to manage users (add/list/remove with expiry)."
