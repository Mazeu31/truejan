#!/bin/bash
set -euo pipefail

# Trojan Debian Auto Installer (APT primary)
# - Trojan 1.16+ compatible with self-signed certs
# - standard config dir: /usr/local/etc/trojan
# - port: 2443
# - creates /usr/local/bin/trojan-menu and sudoers NOPASSWD entry
# - edits config safely using python3 json

TROJAN_PORT=2443
TROJAN_BIN_CANDIDATES=("/usr/bin/trojan" "/usr/local/bin/trojan" "/bin/trojan")
TROJAN_BIN=""
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/trojan.service"
MENU_PATH="/usr/local/bin/trojan-menu"

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Please run this script as root (sudo).${RESET}"
  exit 1
fi

echo -e "${CYAN}${BOLD}=== Trojan Debian Auto Installer (APT primary) ===${RESET}"
echo

# Install base packages
echo -e "${YELLOW}Installing base packages...${RESET}"
apt update -y
apt install -y wget curl xz-utils tar ca-certificates openssl python3 python3-pip ufw qrencode sudo || true

mkdir -p "$TROJAN_DIR"
chmod 755 "$TROJAN_DIR"

# Attempt to install trojan via apt first
echo -e "${YELLOW}Attempting to install 'trojan' package via apt...${RESET}"
if apt-get -qq install -y trojan >/dev/null 2>&1; then
  echo -e "${GREEN}Installed 'trojan' package via apt.${RESET}"
else
  echo -e "${YELLOW}Package 'trojan' not available via apt or install failed. Will fallback to release download.${RESET}"
fi

# Locate trojan binary
for candidate in "${TROJAN_BIN_CANDIDATES[@]}"; do
  if [ -x "$candidate" ]; then
    TROJAN_BIN="$candidate"
    break
  fi
done
if [ -z "$TROJAN_BIN" ]; then
  if command -v trojan >/dev/null 2>&1; then
    TROJAN_BIN="$(command -v trojan)"
  fi
fi

# Fallback: download latest release if binary not found
if [ -z "$TROJAN_BIN" ]; then
  echo -e "${YELLOW}Trojan binary not found after apt attempt. Downloading latest release...${RESET}"
  tmpfile="/tmp/trojan.tar.xz"
  attempt=0
  max_attempts=4
  rm -f "$tmpfile"
  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt+1))
    echo "  try #$attempt..."
    LATEST_URL=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest \
      | grep browser_download_url \
      | grep linux-amd64 \
      | cut -d '"' -f 4 || true)
    if [ -z "$LATEST_URL" ]; then
      echo "  Could not find release URL. Retrying..."
      sleep 2
      continue
    fi
    curl -fsSL "$LATEST_URL" -o "$tmpfile" && break
    echo "  download failed; retrying..."
    rm -f "$tmpfile"
    sleep 2
  done

  if [ ! -f "$tmpfile" ]; then
    echo -e "${RED}Failed to download trojan release after $max_attempts attempts.${RESET}"
    exit 1
  fi

  TMPDIR=$(mktemp -d)
  tar -xJf "$tmpfile" -C "$TMPDIR"
  cp "$TMPDIR/trojan" /usr/local/bin/trojan
  chmod +x /usr/local/bin/trojan
  TROJAN_BIN="/usr/local/bin/trojan"
  rm -rf "$TMPDIR" "$tmpfile"
  echo -e "${GREEN}Trojan binary installed to $TROJAN_BIN${RESET}"
else
  echo -e "${GREEN}Using trojan binary at: $TROJAN_BIN${RESET}"
fi

# Generate self-signed cert for IP (Trojan 1.16+ compatible)
IP=$(curl -s --max-time 10 ifconfig.me || hostname -I | awk '{print $1}')
if [ -z "$IP" ]; then
  echo -e "${RED}Unable to determine public IP.${RESET}"
  exit 1
fi

echo -e "${YELLOW}Generating self-signed certificate for IP ${IP} ...${RESET}"
openssl req -new -x509 -days 3650 -nodes \
  -out "$TROJAN_DIR/server.crt" \
  -keyout "$TROJAN_DIR/server.key" \
  -subj "/CN=$IP" \
  -addext "subjectAltName=IP:$IP"

chmod 644 "$TROJAN_DIR/server.crt"
chmod 600 "$TROJAN_DIR/server.key"
chown root:root "$TROJAN_DIR/server.crt" "$TROJAN_DIR/server.key"

# Create initial config if missing
if [ ! -f "$CONFIG_FILE" ]; then
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

# Create systemd service
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
systemctl enable --now trojan

# Open firewall
ufw allow "$TROJAN_PORT"/tcp || true

# Create trojan-menu
cat > "$MENU_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
TROJAN_PORT=2443
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

function list_users() {
  python3 - <<PY
import json
with open("$CONFIG_FILE") as f:
    j=json.load(f)
pw=j.get("password",[])
for p in pw: print(p)
PY
}

function add_user() {
  read -p "Enter new password to add: " NEWPASS
  python3 - <<PY
import json
cfg="$CONFIG_FILE"
p="$NEWPASS"
with open(cfg) as f:
    j=json.load(f)
pw=j.get("password",[])
if p not in pw:
    pw.append(p)
j["password"]=pw
with open(cfg,"w") as f:
    json.dump(j,f,indent=2)
PY
  systemctl restart trojan
  IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
  echo -e "${GREEN}Added user:${RESET} $NEWPASS"
  echo -e "${YELLOW}Link:${RESET} trojan://$NEWPASS@$IP:$TROJAN_PORT?security=tls&type=tcp&allowInsecure=1"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "trojan://$NEWPASS@$IP:$TROJAN_PORT?security=tls&type=tcp&allowInsecure=1"
  fi
}

function remove_user() {
  read -p "Enter password to remove: " REMPASS
  python3 - <<PY
import json
cfg="$CONFIG_FILE"
p="$REMPASS"
with open(cfg) as f:
    j=json.load(f)
pw=j.get("password",[])
pw=[x for x in pw if x!=p]
j["password"]=pw
with open(cfg,"w") as f:
    json.dump(j,f,indent=2)
PY
  systemctl restart trojan
  echo -e "${RED}Removed user (if existed):${RESET} $REMPASS"
}

function show_info() {
  echo -e "${YELLOW}Server IP:${RESET} $(curl -s ifconfig.me || hostname -I | awk '{print $1}')"
  echo -e "${YELLOW}Port:${RESET} $TROJAN_PORT"
  echo -e "${YELLOW}Users:${RESET}"
  list_users
}

while true; do
  echo -e "${CYAN}1) Add user\n2) Remove user\n3) List users\n4) Show info\n0) Exit${RESET}"
  read -p "Select option: " opt
  case "$opt" in
    1) add_user ;;
    2) remove_user ;;
    3) list_users ; read -p "Press Enter..." ;;
    4) show_info ; read -p "Press Enter..." ;;
    0) exit 0 ;;
    *) echo -e "${RED}Invalid${RESET}" ;;
  esac
done
EOF

chmod +x "$MENU_PATH"
CURRENT_USER=$(logname 2>/dev/null || echo root)
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: $MENU_PATH" > /etc/sudoers.d/trojan-menu-nopasswd
chmod 0440 /etc/sudoers.d/trojan-menu-nopasswd

echo -e "${GREEN}Installation complete!${RESET}"
echo -e "Run '${BOLD}trojan-menu${RESET}' to manage users."
echo -e "Server IP: $IP"
echo -e "Port: $TROJAN_PORT"
