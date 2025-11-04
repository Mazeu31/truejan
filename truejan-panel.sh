#!/bin/bash
set -euo pipefail

# ---------------- CONFIG ----------------
TROJAN_PORT=2443
TROJAN_BIN_CANDIDATES=("/usr/bin/trojan" "/usr/local/bin/trojan" "/bin/trojan")
TROJAN_BIN=""
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/trojan.service"
MENU_PATH="/usr/local/bin/trojan-menu"
PANEL_DIR="/var/www/html"
ADMIN_DIR="$PANEL_DIR/admin"
SERVERS_FILE="$ADMIN_DIR/servers.json"
API_FILE="$ADMIN_DIR/api.php"
CREDS_FILE="$ADMIN_DIR/admin_credentials.json"

# ---------------- COLORS ----------------
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

# ---------------- ROOT CHECK ----------------
[ "$(id -u)" -ne 0 ] && echo -e "${RED}Please run as root${RESET}" && exit 1

echo -e "${CYAN}${BOLD}=== Trojan + Panel Installer ===${RESET}"

# ---------------- REMOVE OLD TROJAN ----------------
if command -v trojan >/dev/null 2>&1 || systemctl list-units --full -all | grep -q "trojan.service"; then
    echo -e "${YELLOW}Removing old Trojan...${RESET}"
    systemctl stop trojan || true
    systemctl disable trojan || true
    rm -f /etc/systemd/system/trojan.service
    rm -rf "$TROJAN_DIR" /usr/local/bin/trojan /usr/local/bin/trojan-menu
    systemctl daemon-reload
    echo -e "${GREEN}Old Trojan removed${RESET}"
fi

# ---------------- INSTALL DEPENDENCIES ----------------
apt update -y
apt install -y wget curl xz-utils tar ca-certificates openssl python3 python3-pip ufw qrencode sudo sshpass || true
mkdir -p "$TROJAN_DIR" "$ADMIN_DIR"
chmod 755 "$TROJAN_DIR" "$ADMIN_DIR"

# ---------------- INSTALL TROJAN ----------------
if apt-get -qq install -y trojan >/dev/null 2>&1; then
    echo -e "${GREEN}Trojan installed via apt${RESET}"
fi

# Locate binary
for candidate in "${TROJAN_BIN_CANDIDATES[@]}"; do [ -x "$candidate" ] && TROJAN_BIN="$candidate" && break; done
[ -z "$TROJAN_BIN" ] && TROJAN_BIN=$(command -v trojan || true)

if [ -z "$TROJAN_BIN" ]; then
    echo -e "${YELLOW}Downloading Trojan binary...${RESET}"
    tmpfile="/tmp/trojan.tar.xz"; rm -f "$tmpfile"
    LATEST_URL=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest | grep browser_download_url | grep linux-amd64 | cut -d '"' -f4)
    curl -fsSL "$LATEST_URL" -o "$tmpfile"
    TMPDIR=$(mktemp -d)
    tar -xJf "$tmpfile" -C "$TMPDIR"
    cp "$TMPDIR/trojan" /usr/local/bin/trojan
    chmod +x /usr/local/bin/trojan
    TROJAN_BIN="/usr/local/bin/trojan"
    rm -rf "$TMPDIR" "$tmpfile"
    echo -e "${GREEN}Trojan binary installed at $TROJAN_BIN${RESET}"
fi

# ---------------- TROJAN CONFIG ----------------
IP=$(curl -s --max-time 10 ifconfig.me || hostname -I | awk '{print $1}')
[ -z "$IP" ] && echo -e "${RED}Cannot detect server IP${RESET}" && exit 1

[ ! -f "$CONFIG_FILE" ] && {
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
  "users": [{"password":"$INIT_PASS","expire":"$EXP_DATE"}],
  "log_level":1,
  "ssl":{"cert":"$TROJAN_DIR/server.crt","key":"$TROJAN_DIR/server.key","verify":false},
  "udp":true
}
EOF
fi

# Self-signed cert
openssl req -new -x509 -days 3650 -nodes -out "$TROJAN_DIR/server.crt" -keyout "$TROJAN_DIR/server.key" -subj "/CN=trojan-server" -addext "subjectAltName=IP:${IP}"
chmod 600 "$TROJAN_DIR/server.key" && chmod 644 "$TROJAN_DIR/server.crt"

# ---------------- SYSTEMD SERVICE ----------------
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
systemctl enable --now trojan || systemctl start trojan
ufw allow "$TROJAN_PORT"/tcp || true

# ---------------- TROJAN-MENU ----------------
cat > "$MENU_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
TROJAN_DIR="/usr/local/etc/trojan"
CONFIG_FILE="$TROJAN_DIR/config.json"
TROJAN_PORT=2443

add_user(){
    read -p "Enter new password: " P
    read -p "Expire in how many days: " D
    python3 - <<PY
import json,datetime
cfg="$CONFIG_FILE"
p="$P"; days=int("$D")
exp=(datetime.date.today()+datetime.timedelta(days=days)).strftime("%Y-%m-%d")
with open(cfg,'r') as f: j=json.load(f)
if "users" not in j: j["users"]=[]
j["users"].append({"password":p,"expire":exp})
with open(cfg,'w') as f: json.dump(j,f,indent=2)
PY
    systemctl restart trojan
    echo "User added: $P, expires in $D days"
}

while true; do
echo "1) Add user"; echo "2) Exit"
read -p "Select: " o
case $o in
1) add_user ;;
2) exit 0 ;;
*) echo "Invalid" ;;
esac
done
EOF
chmod +x "$MENU_PATH"
echo "root ALL=(ALL) NOPASSWD: $MENU_PATH" > /etc/sudoers.d/trojan-menu-nopasswd
chmod 0440 /etc/sudoers.d/trojan-menu-nopasswd

# ---------------- REMOVE OLD PANEL ----------------
rm -rf "$ADMIN_DIR" "$PANEL_DIR/index.php"
mkdir -p "$ADMIN_DIR"
[ ! -f "$SERVERS_FILE" ] && echo '{}' > "$SERVERS_FILE"
[ ! -f "$CREDS_FILE" ] && echo '{"user":"admin","pass":"admin123"}' > "$CREDS_FILE"

# ---------------- API ----------------
cat > "$API_FILE" <<'EOF'
<?php
$servers_file='servers.json';
$creds_file='admin_credentials.json';
$data=json_decode(file_get_contents($servers_file),true);
$post=json_decode(file_get_contents("php://input"),true);
$action=$_GET['action']??($post['action']??'list');
header('Content-Type: application/json');

if($action=='list'){ echo json_encode($data); exit; }

if($action=='addServer'){
  $data[$post['name']]=['ip'=>$post['ip'],'port'=>$post['port'],'expireDays'=>$post['expireDays'],'sshUser'=>$post['user'],'sshPass'=>$post['pass'],'users'=>[]];
  file_put_contents($servers_file,json_encode($data,JSON_PRETTY_PRINT));
  echo json_encode(['status'=>'ok']); exit;
}

if($action=='editServer'){
  $s=$post['oldName'];
  if(isset($data[$s])){
    $data[$post['newName']]=$data[$s]; unset($data[$s]);
    $data[$post['newName']]['ip']=$post['ip'];
    $data[$post['newName']]['port']=$post['port'];
    file_put_contents($servers_file,json_encode($data,JSON_PRETTY_PRINT));
  }
  echo json_encode(['status'=>'ok']); exit;
}

if($action=='addUser'){
  $s=$post['server']; $index=$post['index']??-1;
  if(!isset($data[$s]['users'])) $data[$s]['users']=[];
  $u=['username'=>$post['username'],'password'=>$post['password'],'expire'=>$post['expire']];
  if($index>=0) $data[$s]['users'][$index]=$u; else $data[$s]['users'][]=$u;
  file_put_contents($servers_file,json_encode($data,JSON_PRETTY_PRINT));
  echo json_encode(['status'=>'ok']); exit;
}

if($action=='createUserPublic'){
  $server=$post['server'];
  $username='user'.rand(1000,9999);
  $password=substr(bin2hex(random_bytes(4)),0,8);
  if(isset($data[$server])){
    $ssh_user=$data[$server]['sshUser']; $ssh_pass=$data[$server]['sshPass']; $ssh_ip=$data[$server]['ip']; $expire=$data[$server]['expireDays'];
    $cmd="sshpass -p '$ssh_pass' ssh -o StrictHostKeyChecking=no $ssh_user@$ssh_ip \"echo -e '$password\n$expire' | trojan-menu add_user\"";
    exec($cmd,$out,$ret);
    if($ret===0){
      $data[$server]['users'][]=['username'=>$username,'password'=>$password,'expire'=>$expire];
      file_put_contents($servers_file,json_encode($data,JSON_PRETTY_PRINT));
      echo json_encode(['status'=>'ok','username'=>$username,'password'=>$password,'expire'=>$expire,'ip'=>$ssh_ip,'port'=>$data[$server]['port']]);
      exit;
    } else { echo json_encode(['status'=>'error','msg'=>'Failed to create user']); exit; }
  } else { echo json_encode(['status'=>'error','msg'=>'Server not found']); exit; }
}
EOF

# ---------------- ADMIN PANEL ----------------
cat > "$ADMIN_DIR/index.php" <<'EOF'
<?php
$creds=json_decode(file_get_contents('admin_credentials.json'),true);
session_start();
if(isset($_POST['login'])){
  if($_POST['user']==$creds['user'] && $_POST['pass']==$creds['pass']){
    $_SESSION['admin']=true;
  } else { $err="Invalid credentials"; }
}
if(!isset($_SESSION['admin'])){
?>
<form method="POST" class="max-w-sm mx-auto mt-20 p-6 bg-white shadow rounded">
<h2 class="text-2xl font-bold mb-4">Admin Login</h2>
<?php if(isset($err)) echo "<p class='text-red-500'>$err</p>"; ?>
<input class="border p-2 w-full mb-2" name="user" placeholder="Username">
<input class="border p-2 w-full mb-2" type="password" name="pass" placeholder="Password">
<button class="bg-blue-500 hover:bg-blue-600 text-white p-2 rounded w-full" name="login">Login</button>
</form>
<?php exit; } ?>
<h1 class="text-3xl font-bold mb-4">Trojan Admin Panel</h1>
<p>Manage servers & users</p>
EOF

# ---------------- PUBLIC PANEL ----------------
cat > "$PANEL_DIR/index.php" <<'EOF'
<?php
$servers=json_decode(file_get_contents('admin/servers.json'),true);
?>
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Trojan Public Panel</title>
<script src="https://cdn.tailwindcss.com"></script>
</head><body class="bg-gray-100 p-4 min-h-screen">
<div class="container mx-auto"><h1 class="text-3xl font-bold mb-6">Trojan Public Panel</h1>
<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
<?php foreach($servers as $sname=>$s){ ?>
<div class="bg-white p-4 rounded-xl shadow flex flex-col justify-between">
<b><?php echo $sname;?></b><br>IP: <?php echo $s['ip'];?><br>Port: <?php echo $s['port'];?>
<button onclick="createAccount('<?php echo $sname;?>')" class="mt-2 bg-blue-500 hover:bg-blue-600 text-white px-2 py-1 rounded-lg">Create Account</button>
</div>
<?php } ?>
</div></div>
<script>
function createAccount(server){
    fetch('admin/api.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'createUserPublic',server})})
    .then(r=>r.json()).then(res=>{
        if(res.status=='ok') alert(`Created!\nUsername:${res.username}\nPassword:${res.password}\nIP:${res.ip}\nPort:${res.port}\nTrojan Link: trojan://${res.password}@${res.ip}:${res.port}`);
        else alert('Error: '+res.msg);
    });
}
</script>
</body></html>
EOF

# ---------------- PERMISSIONS ----------------
chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR"

echo -e "${GREEN}✅ Installation Complete!${RESET}"
echo -e "Admin Panel: http://<YOUR-IP>/admin/"
echo -e "Public Panel: http://<YOUR-IP>/"
echo -e "Default login: admin / admin123"
