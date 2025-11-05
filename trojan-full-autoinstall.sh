#!/bin/bash
# Auto-install Trojan server on Debian/Ubuntu using self-signed TLS
# User and password: "emti"
# Default port: 2443

set -e

# --- Configuration ---
SERVER_IP=$(curl -s ifconfig.me)        # Detect your public IP automatically
USER_NAME="emti"
USER_PASSWORD="emti"
PORT=2443

CERT_DIR="/etc/trojan/cert"
CONFIG_FILE="/usr/local/etc/trojan/config.json"

# --- 1) Update system ---
echo "[*] Updating system..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget unzip socat git ufw

# --- 2) Install Trojan binary ---
echo "[*] Installing Trojan..."
sudo mkdir -p /usr/local/bin /usr/local/etc/trojan
curl -Lo trojan.tar.xz https://github.com/trojan-gfw/trojan/releases/download/v1.16.0/trojan-1.16.0-linux-amd64.tar.xz
tar xf trojan.tar.xz -C /usr/local/bin trojan
sudo chmod +x /usr/local/bin/trojan

# --- 3) Generate self-signed certificate ---
echo "[*] Generating self-signed TLS certificate..."
sudo mkdir -p $CERT_DIR
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout $CERT_DIR/trojan.key \
  -out $CERT_DIR/trojan.crt \
  -subj "/CN=$SERVER_IP"

# --- 4) Create Trojan config ---
echo "[*] Creating Trojan config..."
cat <<EOF | sudo tee $CONFIG_FILE
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": $PORT,
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["$USER_PASSWORD"],
  "ssl": {
    "cert": "$CERT_DIR/trojan.crt",
    "key": "$CERT_DIR/trojan.key",
    "cipher": "TLS_AES_128_GCM_SHA256",
    "sni": "$SERVER_IP"
  },
  "websocket": {
    "enabled": false
  },
  "tcp": {
    "prefer_ipv4": true
  }
}
EOF

# --- 5) Setup systemd service ---
echo "[*] Setting up systemd service..."
cat <<EOF | sudo tee /etc/systemd/system/trojan.service
[Unit]
Description=Trojan GFW Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/trojan -c $CONFIG_FILE
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable trojan
sudo systemctl start trojan

# --- 6) Open firewall port ---
echo "[*] Opening port $PORT..."
sudo ufw allow $PORT/tcp || true

# --- 7) Output user info ---
echo ""
echo "================ TROJAN SERVER INSTALLED ================"
echo "Server IP: $SERVER_IP"
echo "Port: $PORT"
echo "User: $USER_NAME"
echo "Password: $USER_PASSWORD"
echo "TLS: Self-signed certificate (import into client or disable SNI check)"
echo "========================================================"
