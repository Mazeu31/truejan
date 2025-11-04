#!/usr/bin/env bash
# trojan-full-autoinstall.sh
# Installs: trojan (no-domain, self-signed), trojan-manager (python), trojan-panel (Laravel)
# For Debian/Ubuntu systems. Run as root.
set -euo pipefail

# ---------- Configuration (tweak if desired) ----------
TROJAN_PORT=443
TROJAN_DIR=/etc/trojan
TROJAN_BIN=/usr/local/bin/trojan
TROJAN_SERVICE=/etc/systemd/system/trojan.service
MENU_PATH=/usr/local/bin/trojan-menu
TM_DIR=/opt/trojan-manager
PANEL_DIR=/var/www/trojan-panel
NGINX_SITE=/etc/nginx/sites-available/trojan-panel
DB_NAME=trojan
DB_USER=trojan
# admin for panel - will prompt later
# -----------------------------------------------------

echog(){ echo -e "\\e[1;32m$*\\e[0m"; }
echow(){ echo -e "\\e[1;33m$*\\e[0m"; }
echor(){ echo -e "\\e[1;31m$*\\e[0m"; }

if [ "$(id -u)" -ne 0 ]; then
  echor "Run as root (sudo). Aborting."
  exit 1
fi

echog "1) Installing system packages..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  wget curl git unzip xz-utils openssl software-properties-common \
  python3 python3-pip python3-venv \
  mariadb-server mariadb-client \
  nginx php-fpm php-cli php-mbstring php-xml php-mysql php-curl php-zip php-gd php-bcmath composer \
  qrencode ufw ca-certificates

echog "2) Create trojan binary (download from GitHub releases)..."
LATEST_URL=$(curl -sSf "https://api.github.com/repos/trojan-gfw/trojan/releases/latest" \
  | awk -F\" '/browser_download_url/ && /linux-amd64/ {print $4; exit}')
if [ -z "$LATEST_URL" ]; then
  echor "Unable to find trojan linux-amd64 release on GitHub. Aborting."
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
echow "Downloading $LATEST_URL ..."
wget -qO "$TMPDIR/trojan.tar.xz" "$LATEST_URL"
tar -xJf "$TMPDIR/trojan.tar.xz" -C "$TMPDIR"
if [ ! -f "$TMPDIR/trojan" ]; then
  echor "trojan binary not found in archive. Aborting."
  exit 1
fi
cp "$TMPDIR/trojan" "$TROJAN_BIN"
chmod +x "$TROJAN_BIN"

echog "3) Create trojan directory and self-signed cert..."
mkdir -p "$TROJAN_DIR"
SERVER_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
openssl req -new -x509 -days 3650 -nodes \
  -out "$TROJAN_DIR/server.crt" -keyout "$TROJAN_DIR/server.key" \
  -subj "/CN=trojan-server" -addext "subjectAltName=IP:${SERVER_IP}"

read -rp "Enter initial trojan password for first client: " INIT_PASS
if [ -z "$INIT_PASS" ]; then
  echor "Password empty. Aborting."
  exit 1
fi

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

echog "4) Create systemd service for trojan..."
cat > "$TROJAN_SERVICE" <<EOF
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

echog "5) Open firewall port $TROJAN_PORT ..."
ufw allow ${TROJAN_PORT}/tcp || true

# ----------------- Trojan Manager (Python) -----------------
echog "6) Installing trojan-manager (Python) ..."
if [ -d "$TM_DIR" ]; then
  echow "Existing $TM_DIR found, skipping clone."
else
  git clone https://github.com/trojan-gfw/trojan-manager.git "$TM_DIR"
fi
# create python venv and install requirements
python3 -m venv "$TM_DIR/venv"
source "$TM_DIR/venv/bin/activate"
pip install --upgrade pip
if [ -f "$TM_DIR/requirements.txt" ]; then
  pip install -r "$TM_DIR/requirements.txt"
else
  echow "No requirements.txt found; trojan_manager.py is pure python - continuing."
fi
deactivate

# small convenience wrapper: /usr/local/bin/trojan-manager-run
cat > /usr/local/bin/trojan-manager-run <<'EOF'
#!/usr/bin/env bash
TM_DIR="/opt/trojan-manager"
if [ -d "$TM_DIR" ]; then
  cd "$TM_DIR"
  source "$TM_DIR/venv/bin/activate"
  python3 trojan_manager.py "$@"
  deactivate
else
  echo "trojan-manager not installed."
  exit 1
fi
EOF
chmod +x /usr/local/bin/trojan-manager-run

echog "7) Setup MariaDB (create database and user for panel & manager)..."
# Secure MariaDB minimally
MYSQL_ROOT_PASS=""
read -rp "Enter MariaDB root password to set (leave empty to generate random): " MYSQL_ROOT_PASS
if [ -z "$MYSQL_ROOT_PASS" ]; then
  MYSQL_ROOT_PASS=$(openssl rand -base64 18)
  echow "Generated root password: $MYSQL_ROOT_PASS"
fi

# Run secure setup tasks: set root password and secure
# Use mysql commands to create user/db
# Allow local socket root login first; then set password
mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

echog "8) Installing trojan-panel (Laravel)..."
if [ -d "$PANEL_DIR" ]; then
  echow "$PANEL_DIR exists, skipping clone"
else
  git clone https://github.com/trojan-gfw/trojan-panel.git "$PANEL_DIR"
fi
cd "$PANEL_DIR"
# composer install (composer installed via apt)
composer install --no-interaction --prefer-dist || echow "composer install had warnings"

# copy .env
if [ -f .env ]; then
  echow ".env exists, backing up to .env.bak"
  cp .env .env.bak
fi
if [ -f .env.example ]; then
  cp .env.example .env
else
  # create a minimal .env
  cat > .env <<ENV
APP_NAME=TrojanPanel
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=http://localhost

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD=$MYSQL_ROOT_PASS

CACHE_DRIVER=file
SESSION_DRIVER=file
QUEUE_DRIVER=sync
MAIL_DRIVER=smtp
ENV
fi

# set APP_KEY
php artisan key:generate --force || echow "artisan key generate failed; you can run manually."

# run migrations
php artisan migrate --force || echow "artisan migrate failed; check DB credentials and DB existence."

# set owner & permissions
chown -R www-data:www-data "$PANEL_DIR"
find "$PANEL_DIR" -type f -exec chmod 644 {} \;
find "$PANEL_DIR" -type d -exec chmod 755 {} \;
chmod -R 775 "$PANEL_DIR"/storage "$PANEL_DIR"/bootstrap/cache

echog "9) Configure nginx vhost for trojan-panel..."
cat > "$NGINX_SITE" <<NGINX
server {
    listen 80;
    server_name _;

    root $PANEL_DIR/public;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX

ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/trojan-panel
# disable default if exists
if [ -f /etc/nginx/sites-enabled/default ]; then
  rm -f /etc/nginx/sites-enabled/default
fi

systemctl reload nginx || echow "nginx reload warning"

# ----------------- trojan-menu (simple) -----------------
echog "10) Installing trojan-menu ..."

cat > "$MENU_PATH" <<'MENU'
#!/usr/bin/env bash
# trojan-menu: simple trojan user manager (edits /etc/trojan/config.json)
if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi
CFG=/etc/trojan/config.json
PORT=443

list_users(){ grep -oP '"\K[^"]+(?=")' "$CFG" | tail -n +2; }
show_info(){
  echo "IP: $(curl -s ifconfig.me || echo 127.0.0.1)"
  echo "Port: $PORT"
  echo "Users:"
  list_users
}
add_user(){
  read -p "New password: " P
  sed -i "s/\(\"password\": \[\)/\1\"$P\", /" "$CFG"
  systemctl restart trojan
  echo "Added: $P"
  echo "Link: trojan://${P}@$(curl -s ifconfig.me || echo 127.0.0.1):${PORT}?security=tls&type=tcp&allowInsecure=1"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "trojan://${P}@$(curl -s ifconfig.me || echo 127.0.0.1):${PORT}?security=tls&type=tcp&allowInsecure=1"
  fi
}
remove_user(){
  read -p "Password to remove: " P
  sed -i "/\"$P\"/d" "$CFG"
  systemctl restart trojan
  echo "Removed: $P"
}
while true; do
  echo "1) Add user"
  echo "2) Remove user"
  echo "3) List users"
  echo "4) Show info"
  echo "0) Exit"
  read -rp "Select: " o
  case $o in
    1) add_user;;
    2) remove_user;;
    3) list_users;;
    4) show_info;;
    0) exit 0;;
    *) echo "invalid";;
  esac
done
MENU

chmod +x "$MENU_PATH"
echo "$(logname) ALL=(ALL) NOPASSWD: $MENU_PATH" > /etc/sudoers.d/trojan-menu-nopasswd
chmod 0440 /etc/sudoers.d/trojan-menu-nopasswd

echog "11) Final summary"
echow " - Trojan IP: $SERVER_IP"
echow " - Port: $TROJAN_PORT"
echow " - First trojan user password: $INIT_PASS"
echow " - MariaDB root password: $MYSQL_ROOT_PASS"
echow " - trojan-manager CLI available as: trojan-manager-run (use: trojan-manager-run adduser username password)"
echow " - trojan-panel accessible at http://<server-ip>/ (nginx + php-fpm)."
echow " - Manage trojan users interactively with: trojan-menu (no sudo prompt)."

echog "Done. Check logs if anything failed:"
echow " - trojan logs: sudo journalctl -u trojan -n 200"
echow " - nginx logs: /var/log/nginx/error.log"
echow " - php-fpm logs: /var/log/php*-fpm.log"
echog "If trojan-panel migrations failed, go to $PANEL_DIR and run 'php artisan migrate' manually and check .env DB settings."
