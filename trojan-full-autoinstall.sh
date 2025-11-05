#!/bin/bash
# trojan-autoinstall-safe.sh
# Safe Trojan autoscript (No domain, self-signed)
# Installs trojan binary, creates /etc/trojan, systemd service, and trojan-menu
# Run once as root: sudo bash trojan-autoinstall-safe.sh

set -euo pipefail

# --- CONFIG ---
TROJAN_PORT=443
TROJAN_DIR=/etc/trojan
TROJAN_BIN=/usr/local/bin/trojan
MENU_PATH=/usr/local/bin/trojan-menu
SERVICE_PATH=/etc/systemd/system/trojan.service

# --- helper ---
echog() { echo -e "\e[1;32m$*\e[0m"; }
echow() { echo -e "\e[1;33m$*\e[0m"; }
echor() { echo -e "\e[1;31m$*\e[0m"; }

if [ "$(id -u)" -ne 0 ]; then
  echor "Please run as root (sudo)."
  exit 1
fi

echog "1) Installing packages (apt)..."
apt-get update -y
apt-get install -y curl wget openssl xz-utils unzip ufw qrencode sudo ca-certificates gnupg

echog "2) Downloading latest Trojan linux-amd64 release from GitHub..."
# Query GitHub API and pick linux-amd64 tar.xz asset (works without auth for public repos)
LATEST_URL=$(curl -sSf "https://api.github.com/repos/trojan-gfw/trojan/releases/latest" \
  | awk -F\" '/browser_download_url/ && /linux-amd64/ {print $4; exit}')
if [ -z "$LATEST_URL" ]; then
  echor "Could not find linux-amd64 release URL. Aborting."
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

wget -qO "$TMPDIR/trojan.tar.xz" "$LATEST_URL"
tar -xJf "$TMPDIR/trojan.tar.xz" -C "$TMPDIR"
if [ ! -f "$TMPDIR/trojan" ]; then
  echor "Trojan binary not found in archive. Aborting."
  exit 1
fi
cp "$TMPDIR/trojan" "$TROJAN_BIN"
chmod +x "$TROJAN_BIN"

echog "3) Creating trojan dir and self-signed certificate..."
mkdir -p "$TROJAN_DIR"
SERVER_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
openssl req -new -x509 -days 3650 -nodes \
  -out "$TROJAN_DIR/server.crt" -keyout "$TROJAN_DIR/server.key" \
  -subj "/CN=trojan-server" -addext "subjectAltName=IP:${SERVER_IP}"

# --- ask initial password ---
read -rp "Enter initial password for the first client: " INIT_PASS
if [ -z "$INIT_PASS" ]; then
  echor "Password cannot be empty. Aborting."
  exit 1
fi

echog "4) Writing config to $TROJAN_DIR/config.json..."
cat > "$TROJAN_DIR/config.json" <<EOF
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
chmod 640 "$TROJAN_DIR/config.json"
chown root:root "$TROJAN_DIR/config.json"

echog "5) Creating systemd service..."
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Trojan Service
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=$TROJAN_BIN -c $TROJAN_DIR/config.json
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now trojan

echog "6) Open firewall port $TROJAN_PORT (ufw)"
ufw allow ${TROJAN_PORT}/tcp || true

echog "7) Installing trojan-menu command to $MENU_PATH ..."
cat > "$MENU_PATH" <<'MENU_EOF'
#!/bin/bash
# trojan-menu - simple manager (must be run as normal user)
if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi
TROJAN_DIR=/etc/trojan
CONFIG_FILE=$TROJAN_DIR/config.json
TROJAN_PORT=443
COLOR_G="\e[1;32m"; COLOR_Y="\e[1;33m"; COLOR_R="\e[1;31m"; COLOR_C="\e[1;36m"; RESET="\e[0m"

banner() {
  clear
  echo -e "${COLOR_C}================ Trojan Manager ===============${RESET}"
}

list_users() {
  grep -oP '"\K[^"]+(?=")' "$CONFIG_FILE" | tail -n +2
}

show_info() {
  echo "Server IP : $(curl -s ifconfig.me || echo '127.0.0.1')"
  echo "Port      : $TROJAN_PORT"
  echo "Users:"
  list_users
}

add_user_flow() {
  read -p "Enter new password: " NP
  if [ -z "$NP" ]; then echo "empty"; return; fi
  sed -i "s/\(\"password\": \[\)/\1\"$NP\", /" "$CONFIG_FILE"
  systemctl restart trojan
  IP=$(curl -s ifconfig.me || echo 127.0.0.1)
  LINK="trojan://${NP}@${IP}:${TROJAN_PORT}?security=tls&type=tcp&allowInsecure=1"
  echo -e "Added user: $NP"
  echo -e "Link: $LINK"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$LINK"
  fi
}

remove_user_flow() {
  read -p "Enter password to remove: " RP
  if [ -z "$RP" ]; then echo "empty"; return; fi
  sed -i "/\"$RP\"/d" "$CONFIG_FILE"
  systemctl restart trojan
  echo "Removed: $RP"
}

while true; do
  banner
  echo "1) Add user"
  echo "2) Remove user"
  echo "3) List users"
  echo "4) Show server info"
  echo "5) Restart trojan"
  echo "6) Uninstall trojan"
  echo "0) Exit"
  read -rp "Select: " opt
  case $opt in
    1) add_user_flow; read -p "Enter to continue...";;
    2) remove_user_flow; read -p "Enter to continue...";;
    3) list_users; read -p "Enter to continue...";;
    4) show_info; read -p "Enter to continue...";;
    5) systemctl restart trojan; echo "restarted"; read -p "Enter to continue...";;
    6) echo "Uninstalling..."; systemctl stop trojan; systemctl disable trojan; rm -f /etc/trojan/* /usr/local/bin/trojan /etc/systemd/system/trojan.service; systemctl daemon-reload; echo "done"; exit 0;;
    0) exit 0;;
    *) echo "invalid"; sleep 1;;
  esac
done
MENU_EOF

chmod +x "$MENU_PATH"

echog "8) Allow current login user to run trojan-menu without sudo password"
# get login user (fall back)
LOGIN_USER=$(logname 2>/dev/null || echo "$SUDO_USER" || echo root)
echo "$LOGIN_USER ALL=(ALL) NOPASSWD: $MENU_PATH" > /etc/sudoers.d/trojan-menu-nopasswd
chmod 0440 /etc/sudoers.d/trojan-menu-nopasswd

echog "Summary"
echow " - Server IP: $SERVER_IP"
echow " - Troj an port: $TROJAN_PORT"
echow " - First user password: $INIT_PASS"
echow " - Run 'trojan-menu' as the login user to manage users (no sudo prompt)."
echog "Done. To test: trojan-menu"
