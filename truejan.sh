#!/bin/bash
set -euo pipefail

# Trojan Debian Auto Installer (APT primary, fixed systemd)
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
  echo -e "${RED}Please run this script as root (sudo).${RESET}"
  exit 1
fi

echo -e "${CYAN}${BOLD}=== Trojan Debian Auto Installer (APT primary, fixed systemd) ===${RESET}"
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
      echo "  Could not find release URL (API may be rate-limited). Retrying..."
      sleep 2
      continue
    fi
    curl -fsSL "$LATEST_URL" -o "$tmpfile" && break
    echo "  download failed or archive corrupt; retrying..."
    rm -f "$tmpfile"
    sleep 2
  done

  if [ ! -f "$tmpfile" ]; then
    echo -e "${RED}Failed to download trojan release after $max_attempts attempts.${RESET}"
    exit 1
  fi

  TMPDIR=$(mktemp -d)
  tar -xJf "$tmpfile" -C "$TMPDIR"
  if [ ! -f "$TMPDIR/trojan" ]; then
    echo -e "${RED}Trojan binary not found in archive. Aborting.${RESET}"
    rm -rf "$TMPDIR" "$tmpfile"
    exit 1
  fi
  cp "$TMPDIR/trojan" /usr/local/bin/trojan
  chmod +x /usr/local/bin/trojan
  TROJAN_BIN="/usr/local/bin/trojan"
  rm -rf "$TMPDIR" "$tmpfile"
  echo -e "${GREEN}Trojan binary installed to $TROJAN_BIN${RESET}"
else
  echo -e "${GREEN}Using trojan binary at: $TROJAN_BIN${RESET}"
fi

# Generate self-signed cert (with IP SAN)
IP=$(curl -s --max-time 10 ifconfig.me || true)
if [ -z "$IP" ]; then
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

# Create initial config if missing
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

# Create fixed systemd service (runs as root)
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

# Create trojan-menu (unchanged from previous)
cat > "$MENU_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail

TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
TROJAN_PORT=2443

# Colors
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; MAGENTA="\e[35m"; BOLD="\e[1m"; RESET="\e[0m"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

function banner() { clear; echo -e "${CYAN}=== TROJAN SERVER MANAGER ===${RESET}"; echo; }
function list_users() { python3 - <<PY
import json,sys
cfg="$CONFIG_FILE"
try:
    with open(cfg,'r') as f:
        j=json.load(f)
    pw=j.get("password",[])
    for p in pw: print(p)
except: sys.exit(0)
PY
}
function add_user() {
  read -p "Enter new password to add: " NEWPASS
  python3 - <<PY
import json,sys
cfg="$CONFIG_FILE";p="$NEWPASS"
with open(cfg,'r') as f: j=json.load(f)
pw=j.get("password",[])
if p not in pw: pw.append(p)
j["password"]=pw
with open(cfg,'w') as f: json.dump(j,f,indent=2)
PY
  systemctl restart trojan
  IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
  link="trojan://${NEWPASS}@${IP}:${TROJAN_PORT}?security=tls&type=tcp&allowInsecure=1"
  echo -e "${GREEN}User added:${RESET} ${CYAN}${NEWPASS}${RESET}"
  echo -e "${YELLOW}Link:${RESET} ${link}"
  if command -v qrencode >/dev/null 2>&1; then qrencode -t ANSIUTF8 "${link}"; fi
  read -p "Press Enter..."
}
function remove_user() {
  read -p "Enter password to remove: " REMPASS
  python3 - <<PY
import json
cfg="$CONFIG_FILE";p="$REMPASS"
with open(cfg,'r') as f: j=json.load(f)
pw=j.get("password",[])
if p in pw: pw=[x for x in pw if x!=p]; j["password"]=pw
with open(cfg,'w') as f: import json; json.dump(j,f,indent=2)
PY
  systemctl restart trojan
  echo -e "${RED}Removed (if existed):${RESET} ${REMPASS}"
  read -p "Press Enter..."
}
function show_info() { echo -e "Server IP: $(curl -s ifconfig.me || hostname -I | awk '{print $1}')\nPort: $TROJAN_PORT\nUsers:"; list_users; read -p "Enter to return..." ; }
function restart_trojan() { systemctl restart trojan; echo -e "${GREEN}Trojan restarted${RESET}"; sleep 1; }
function uninstall() {
  read -p "Uninstall Trojan? (yes/NO): " ans
  if [ "$ans" = "yes" ]; then
    systemctl stop trojan || true
    systemctl disable trojan || true
    rm -f /etc/systemd/system/trojan.service
    rm -rf /usr/local/etc/trojan /usr/local/bin/trojan /usr/local/bin/trojan-menu
    systemctl daemon-reload
    echo -e "${RED}Trojan removed${RESET}"; exit 0
  fi
}
while true; do
  banner
  echo -e "1) Add user\n2) Remove user\n3) List users\n4) Show info\n5) Restart trojan\n6) Uninstall\n0) Exit"
  read -p "Select: " opt
  case "$opt" in
    1) add_user ;; 2) remove_user ;; 3) list_users; read -p "" ;;
    4) show_info ;; 5) restart_trojan ;; 6) uninstall ;; 0) exit 0 ;;
    *) echo -e "${RED}Invalid${RESET}"; sleep 1 ;;
  esac
done
EOF

chmod +x "$MENU_PATH"
CURRENT_USER=$(logname 2>/dev/null || echo root)
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: $MENU_PATH" > /etc/sudoers.d/trojan-menu-nopasswd
chmod 0440 /etc/sudoers.d/trojan-menu-nopasswd

echo -e "${GREEN}=== Installation complete ===${RESET}"
echo -e "Run '${BOLD}trojan-menu${RESET}' to manage users."
