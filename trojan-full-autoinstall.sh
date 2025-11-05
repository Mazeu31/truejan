#!/usr/bin/env bash
# trojan-manager.sh - Debian 12 Fresh Install + User Management + Passwall snippet
# Freshly removes existing Trojan installations and services.

set -euo pipefail
TROJAN_BIN="/usr/local/bin/trojan"
TROJAN_CONFIG_DIR="/etc/trojan"
TROJAN_CONFIG_FILE="${TROJAN_CONFIG_DIR}/config.json"
TROJAN_USERS_FILE="${TROJAN_CONFIG_DIR}/users.json"
TROJAN_SERVICE_FILE="/etc/systemd/system/trojan.service"
DEFAULT_PORT=2443
DEFAULT_REMOTE_PORT=80
CERT_KEY="${TROJAN_CONFIG_DIR}/server.key"
CERT_CRT="${TROJAN_CONFIG_DIR}/server.crt"
QUICKSTART_URL="https://raw.githubusercontent.com/trojan-gfw/trojan-quickstart/master/trojan-quickstart.sh"

# Color helpers
info(){ echo -e "\e[1;34m[INFO]\e[0m $*"; }
err(){ echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; }
ok(){ echo -e "\e[1;32m[OK]\e[0m $*"; }

# Ensure root
if [ "$(id -u)" -ne 0 ]; then
  err "Run with sudo/root"
  exit 1
fi

# -------------------------------
# Fresh uninstall of existing trojan
# -------------------------------
fresh_uninstall() {
  info "Removing existing Trojan installations/services (if any)..."
  systemctl stop trojan 2>/dev/null || true
  systemctl disable trojan 2>/dev/null || true
  rm -f /etc/systemd/system/trojan.service
  systemctl daemon-reload
  rm -f "${TROJAN_BIN}"
  rm -rf "${TROJAN_CONFIG_DIR}"
  ok "Removed previous Trojan installation."
}

# -------------------------------
# Install prerequisites
# -------------------------------
install_prereqs() {
  info "Installing prerequisites..."
  apt update -y
  apt install -y wget curl xz-utils openssl net-tools ufw jq || {
    err "APT install failed"
    exit 1
  }
  ok "Prerequisites installed."
}

# -------------------------------
# Install trojan
# -------------------------------
install_quickstart_trojan() {
  info "Installing Trojan..."
  if curl -fsSL "${QUICKSTART_URL}" -o /tmp/trojan-quickstart.sh; then
    chmod +x /tmp/trojan-quickstart.sh
    bash /tmp/trojan-quickstart.sh || {
      err "Quickstart failed"
      exit 1
    }
    rm -f /tmp/trojan-quickstart.sh
  else
    err "Failed to download quickstart script"
    exit 1
  fi

  if ! command -v "${TROJAN_BIN}" >/dev/null 2>&1; then
    err "Trojan binary not found"
    exit 1
  fi
  ok "Trojan installed successfully."
}

# -------------------------------
# Generate self-signed certificate
# -------------------------------
generate_self_signed_cert_if_missing() {
  mkdir -p "${TROJAN_CONFIG_DIR}"
  info "Generating self-signed certificate..."
  SERVER_IP=$(hostname -I | awk '{print $1}' || echo "127.0.0.1")
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${CERT_KEY}" -out "${CERT_CRT}" \
    -subj "/CN=${SERVER_IP}" >/dev/null 2>&1
  chmod 600 "${CERT_KEY}"
  ok "Certificate created with CN=${SERVER_IP}"
}

# -------------------------------
# User management functions
# -------------------------------
ensure_users_file() {
  mkdir -p "${TROJAN_CONFIG_DIR}"
  [ -f "${TROJAN_USERS_FILE}" ] || echo '[]' > "${TROJAN_USERS_FILE}"
  chmod 600 "${TROJAN_USERS_FILE}"
}

prune_expired_users() {
  ensure_users_file
  NOW=$(date +%s)
  tmp=$(mktemp)
  jq --argjson now "$NOW" 'map(select(.expire_on > $now))' "${TROJAN_USERS_FILE}" > "$tmp"
  mv "$tmp" "${TROJAN_USERS_FILE}"
  chmod 600 "${TROJAN_USERS_FILE}"
}

build_config() {
  ensure_users_file
  prune_expired_users >/dev/null || true
  PASSWORDS=$(jq -r '[.[] | .password] | @json' "${TROJAN_USERS_FILE}")
  [ -z "$PASSWORDS" ] && PASSWORDS='[]'

  cat > "${TROJAN_CONFIG_FILE}" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": ${DEFAULT_PORT},
  "remote_addr": "127.0.0.1",
  "remote_port": ${DEFAULT_REMOTE_PORT},
  "password": ${PASSWORDS},
  "log_level": 1,
  "ssl": {
    "cert": "${CERT_CRT}",
    "key": "${CERT_KEY}",
    "sni": "127.0.0.1"
  },
  "udp": true
}
EOF
  chmod 640 "${TROJAN_CONFIG_FILE}"
  ok "Config.json updated."
}

create_systemd_service() {
  cat > "${TROJAN_SERVICE_FILE}" <<'EOF'
[Unit]
Description=Trojan Server
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/trojan -c /etc/trojan/config.json
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now trojan
  ok "Trojan service installed and started."
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${DEFAULT_PORT}"/tcp || true
    ufw reload || true
    ok "Firewall updated for port ${DEFAULT_PORT}"
  fi
}

reload_trojan() {
  systemctl restart trojan
  sleep 0.8
  systemctl is-active --quiet trojan && ok "Trojan running." || err "Trojan not running, check logs"
}

add_user() {
  ensure_users_file
  read -rp "Password (leave empty to auto-generate): " PW
  [ -z "$PW" ] && PW=$(openssl rand -base64 18 | tr -d "=+/") && echo "Generated password: $PW"
  read -rp "Days until expiry: " DAYS
  [[ ! "$DAYS" =~ ^[0-9]+$ ]] && err "Invalid days" && return 1
  ADDED_ON=$(date +%s)
  EXPIRE_ON=$((ADDED_ON + DAYS*86400))
  tmp=$(mktemp)
  jq --arg pw "$PW" --argjson added "$ADDED_ON" --argjson exp "$EXPIRE_ON" \
    '. += [{password:$pw, added_on:$added, expire_on:$exp}]' "${TROJAN_USERS_FILE}" > "$tmp"
  mv "$tmp" "${TROJAN_USERS_FILE}"
  chmod 600 "${TROJAN_USERS_FILE}"
  build_config
  reload_trojan
  SERVER_IP=$(hostname -I | awk '{print $1}')
  echo "Passwall snippet:"
  echo "Address: ${SERVER_IP}"
  echo "Port: ${DEFAULT_PORT}"
  echo "Password: ${PW}"
  echo "TLS: Enabled"
  echo "SNI: ${SERVER_IP}"
  echo "Skip certificate verification: Enabled"
}

remove_user() {
  ensure_users_file
  list_users
  read -rp "Password or index to remove: " KEY
  if [[ "$KEY" =~ ^[0-9]+$ ]]; then
    idx=$((KEY-1))
    tmp=$(mktemp)
    jq "del(.[${idx}])" "${TROJAN_USERS_FILE}" > "$tmp" && mv "$tmp" "${TROJAN_USERS_FILE}"
    ok "Removed user at index ${KEY}."
  else
    tmp=$(mktemp)
    jq --arg pw "$KEY" 'map(select(.password != $pw))' "${TROJAN_USERS_FILE}" > "$tmp" && mv "$tmp" "${TROJAN_USERS_FILE}"
    ok "Removed user(s) with matching password."
  fi
  chmod 600 "${TROJAN_USERS_FILE}"
  build_config
  reload_trojan
}

list_users() {
  ensure_users_file
  jq -r 'if length==0 then " (no users) " else to_entries[] | "\(.key+1). \(.value.password) — added: \(.value.added_on|tonumber|strftime("%Y-%m-%d")) expire: \(.value.expire_on|tonumber|strftime("%Y-%m-%d"))" end' "${TROJAN_USERS_FILE}" || echo " (no users)"
}

# -------------------------------
# Menu
# -------------------------------
menu() {
  while true; do
    echo "----------------------------------------"
    echo "Trojan Manager Menu (port ${DEFAULT_PORT})"
    echo "1) Add user"
    echo "2) Remove user"
    echo "3) List users"
    echo "4) Prune expired users"
    echo "5) Show trojan status & last logs"
    echo "6) Quit"
    echo "----------------------------------------"
    read -rp "Choice [1-6]: " CH
    case "$CH" in
      1) add_user ;;
      2) remove_user ;;
      3) list_users ;;
      4) prune_expired_users && build_config && reload_trojan && ok "Pruned expired users" ;;
      5)
        systemctl status trojan --no-pager -l -n 5 || true
        echo "---- last 20 logs ----"
        journalctl -u trojan -n 20 --no-pager || true
        ;;
      6) break ;;
      *) echo "Invalid option" ;;
    esac
  done
}

# -------------------------------
# Handle --prune mode for cron
# -------------------------------
if [[ "${1:-}" == "--prune" ]]; then
  prune_expired_users
  build_config
  reload_trojan
  echo "Expired users pruned."
  exit 0
fi

# -------------------------------
# Main installation
# -------------------------------
main() {
  fresh_uninstall
  install_prereqs
  install_quickstart_trojan
  generate_self_signed_cert_if_missing
  ensure_users_file
  prune_expired_users
  build_config
  create_systemd_service
  open_firewall
  reload_trojan
  info "Fresh install complete. Opening menu..."
  menu
}

main "$@"
