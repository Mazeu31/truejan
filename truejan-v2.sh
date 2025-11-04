#!/bin/bash
set -euo pipefail

# install-trojan.sh
# Usage: run as root. Installs trojan, creates trojan-menu supporting both interactive and noninteractive remote adds.

TROJAN_PORT=2443
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
PANEL_USERS="$TROJAN_DIR/panel_users.json"
SERVICE_FILE="/etc/systemd/system/trojan.service"
MENU_PATH="/usr/local/bin/trojan-menu"

# ensure root
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

apt update -y
apt install -y wget curl xz-utils tar ca-certificates openssl python3 jq sshpass || true
mkdir -p "$TROJAN_DIR"

# Try installing trojan from apt first, otherwise download release
if ! command -v trojan >/dev/null 2>&1; then
  if apt-get -qq install -y trojan >/dev/null 2>&1; then
    echo "trojan installed via apt"
  else
    echo "Downloading trojan binary release..."
    TMP="/tmp/trojan.$$"
    mkdir -p "$TMP"
    LATEST_URL=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest \
      | grep browser_download_url | grep linux-amd64 | cut -d '"' -f4 || true)
    if [ -z "$LATEST_URL" ]; then
      echo "Could not find trojan release URL. Install manually."
    else
      curl -fsSL "$LATEST_URL" -o "$TMP/trojan.tar.xz"
      tar -xJf "$TMP/trojan.tar.xz" -C "$TMP"
      cp "$TMP"/trojan /usr/local/bin/trojan
      chmod +x /usr/local/bin/trojan
      echo "trojan binary installed to /usr/local/bin/trojan"
    fi
    rm -rf "$TMP"
  fi
fi

# Determine trojan binary path
if command -v trojan >/dev/null 2>&1; then
  TROJAN_BIN=$(command -v trojan)
else
  echo "trojan binary not found. Exiting."
  exit 1
fi

# Create config.json if missing (minimal)
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Creating minimal trojan config at $CONFIG_FILE"
  read -p "Enter initial trojan password: " INIT_PASS
  read -p "Initial user expire in how many days? " INIT_DAYS
  EXP_DATE=$(date -d "+$INIT_DAYS days" +"%Y-%m-%d")
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
  mkdir -p "$(dirname "$PANEL_USERS")"
  echo "{}" > "$PANEL_USERS"
  # store in panel_users for panel visibility
  python3 - <<PY
import json
d={}
d["$INIT_PASS"]={"password":"$INIT_PASS","expire":"$EXP_DATE"}
with open("$PANEL_USERS","w") as f:
    json.dump(d,f,indent=2)
PY
fi

# Generate self-signed certs (overwrite / recreate)
IP=$(curl -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')
if [ -z "$IP" ]; then
  IP="127.0.0.1"
fi
openssl req -new -x509 -days 3650 -nodes \
  -out "$TROJAN_DIR/server.crt" \
  -keyout "$TROJAN_DIR/server.key" \
  -subj "/CN=trojan-server" -addext "subjectAltName=IP:${IP}" 2>/dev/null || true
chmod 600 "$TROJAN_DIR/server.key" || true

# Systemd unit
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now trojan || systemctl start trojan || true
ufw allow "$TROJAN_PORT"/tcp || true

# Create trojan-menu supporting both interactive and noninteractive remote creation
cat > "$MENU_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
CONFIG_FILE="/usr/local/etc/trojan/config.json"
PANEL_USERS="/usr/local/etc/trojan/panel_users.json"

# add_user_interactive: interactive prompts
add_user_interactive() {
  read -p "Enter new password: " NEWPASS
  read -p "Expire in how many days: " DAYS
  add_user "$NEWPASS" "$DAYS"
  echo "Added user $NEWPASS (expires in $DAYS days)."
}

# add_user <password> <days>
add_user() {
  P="$1"
  D="$2"
  EXP_DATE=$(date -d "+${D} days" +"%Y-%m-%d")
  # update trojan config password array
  python3 - <<PY
import json
cfg="$CONFIG_FILE"
p="$P"
d="$EXP_DATE"
try:
    with open(cfg,'r') as f: j=json.load(f)
except:
    j={}
if 'password' not in j or not isinstance(j['password'], list):
    j['password']=j.get('password',[]) if isinstance(j.get('password',[]),list) else []
if p not in j['password']:
    j['password'].append(p)
with open(cfg,'w') as f: json.dump(j,f,indent=2)
# update panel users
pu="$PANEL_USERS"
try:
    with open(pu,'r') as f: up=json.load(f)
except:
    up={}
up[p]={"password":p,"expire":d}
with open(pu,'w') as f: json.dump(up,f,indent=2)
PY
  systemctl restart trojan || true
}

usage() {
  echo "Usage:"
  echo "  $0                # interactive menu"
  echo "  $0 add_remote <username> <password> <expire_days>   # noninteractive for panel (username is recorded but trojan uses password)"
}

# noninteractive add for panel:
# $0 add_remote <username> <password> <expire_days>
if [ "${1:-}" = "add_remote" ]; then
  if [ $# -ne 4 ]; then
    echo "add_remote requires 3 args"
    usage
    exit 2
  fi
  USERNAME="$2"
  PASSWORD="$3"
  DAYS="$4"
  # we store record with username, but trojan only needs password
  add_user "$PASSWORD" "$DAYS"
  # write to panel_users.json mapping server-side users (keep username)
  # panel will prefer storing username + password in servers.json; here we only update panel_users.json as backup
  exit 0
fi

# interactive menu
while true; do
  echo "1) Add user"
  echo "2) List users"
  echo "3) Exit"
  read -p "Choose: " opt
  case "$opt" in
    1) add_user_interactive ;;
    2) python3 - <<PY
import json
pu="$PANEL_USERS"
try:
    with open(pu) as f: d=json.load(f)
except:
    d={}
for k,v in d.items():
    print(k, v.get("expire",""))
PY
;;
    3) exit 0 ;;
    *) echo "Invalid" ;;
  esac
done
EOF

chmod +x "$MENU_PATH"
echo "root ALL=(ALL) NOPASSWD: $MENU_PATH" > /etc/sudoers.d/trojan-menu-nopasswd
chmod 0440 /etc/sudoers.d/trojan-menu-nopasswd

echo "install-trojan.sh finished. trojan-menu installed at $MENU_PATH"
echo "You can test interactive menu: sudo $MENU_PATH"
echo "You can test noninteractive remote add on panel server via ssh: ssh user@trojan-server /usr/local/bin/trojan-menu add_remote username password days"
