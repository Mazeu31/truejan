#!/bin/bash
set -euo pipefail

# ========================
# Trojan Panel Auto Installer (Update/Remove Old)
# ========================

ADMIN_USER="admin"
ADMIN_PASS="admin123"
WWW_DIR="/var/www/html"
ADMIN_DIR="$WWW_DIR/admin"
PUBLIC_DIR="$WWW_DIR"

echo -e "=== Trojan Panel Installer ==="

# Remove existing panel if exists
if [ -d "$WWW_DIR" ]; then
    echo "Existing panel detected. Removing..."
    rm -rf "$WWW_DIR"
    echo "Old panel removed."
fi

# Install PHP + dependencies
apt update -y
apt install -y php-fpm php-cli jq curl sshpass git wget unzip

# Create directories
mkdir -p "$ADMIN_DIR"
mkdir -p "$PUBLIC_DIR"

# ----------------------
# Admin Panel
# ----------------------
cat > "$ADMIN_DIR/index.php" <<'EOF'
<?php
session_start();
$creds_file='admin_credentials.json';
if(!file_exists($creds_file)){ file_put_contents($creds_file,json_encode(["user"=>"admin","pass"=>"admin123"])); }
$creds=json_decode(file_get_contents($creds_file),true);

if(isset($_POST['login'])){
    if($_POST['username']==$creds['user'] && $_POST['password']==$creds['pass']){
        $_SESSION['admin']=true;
    } else { $error="Invalid credentials"; }
}
if(isset($_GET['logout'])){ session_destroy(); header("Location:index.php"); exit;}
if(!isset($_SESSION['admin'])){
?>
<!DOCTYPE html>
<html><head><title>Admin Login</title>
<link href="https://cdn.jsdelivr.net/npm/tailwindcss@3.3.3/dist/tailwind.min.css" rel="stylesheet">
</head><body class="bg-gray-100 flex items-center justify-center h-screen">
<form method="post" class="bg-white p-6 rounded shadow-md w-96">
<h2 class="text-2xl mb-4">Admin Login</h2>
<?php if(isset($error)){echo "<p class='text-red-500'>$error</p>";} ?>
<input type="text" name="username" placeholder="Username" class="w-full p-2 mb-2 border rounded">
<input type="password" name="password" placeholder="Password" class="w-full p-2 mb-2 border rounded">
<button type="submit" name="login" class="w-full bg-blue-500 text-white p-2 rounded">Login</button>
</form>
</body></html>
<?php exit;} ?>

<!DOCTYPE html>
<html><head><title>Admin Panel</title>
<link href="https://cdn.jsdelivr.net/npm/tailwindcss@3.3.3/dist/tailwind.min.css" rel="stylesheet">
</head><body class="p-4 bg-gray-100">
<h1 class="text-3xl font-bold mb-4">Trojan Admin Panel</h1>
<a href="?logout=1" class="text-red-500">Logout</a>

<h2 class="text-xl mt-4 mb-2">Servers</h2>
<div id="servers"></div>
<button onclick="addServer()" class="bg-green-500 text-white px-2 py-1 rounded mt-2">Add Server</button>

<script>
const serversFile='servers.json';

function loadServers(){
    fetch(serversFile).then(r=>r.json()).then(data=>{
        const div=document.getElementById('servers');
        div.innerHTML='';
        for(const s in data){
            const d=document.createElement('div');
            d.className='p-2 mb-1 bg-white rounded shadow';
            d.innerHTML=`<b>${s}</b> - IP: ${data[s].ip} PORT: ${data[s].port} 
            <button onclick="editServer('${s}')">Edit</button> 
            <button onclick="createUser('${s}')">Create User</button>`;
            div.appendChild(d);
        }
    });
}

function addServer(){
    const name=prompt("Server Name:");
    const ip=prompt("Server IP:");
    const port=prompt("Port:");
    const expireDays=prompt("Default Expire Days:");
    const user=prompt("SSH user:");
    const pass=prompt("SSH pass:");
    fetch(serversFile).then(r=>r.json()).then(data=>{
        data[name]={ip,port,expireDays,user,pass};
        fetch(serversFile,{
            method:'POST',
            headers:{'Content-Type':'application/json'},
            body:JSON.stringify(data)
        }).then(()=>loadServers());
    });
}

function editServer(name){ alert('Editing server: '+name); }

function createUser(name){
    fetch(serversFile).then(r=>r.json()).then(data=>{
        const s=data[name];
        const username=prompt("Enter username for user:");
        const password=prompt("Enter password for user:");
        alert('Creating user '+username+' on '+name+' ...');
        // call server trojan-menu via ssh
        fetch(`create_user.php?server=${name}&username=${username}&password=${password}`).then(r=>r.text()).then(res=>{
            alert(res);
        });
    });
}

loadServers();
</script>
</body></html>
EOF

# ----------------------
# Public Panel
# ----------------------
cat > "$PUBLIC_DIR/index.php" <<'EOF'
<?php
$serversFile='admin/servers.json';
$servers=json_decode(file_get_contents($serversFile),true);
?>
<!DOCTYPE html>
<html><head><title>Trojan Public Panel</title>
<link href="https://cdn.jsdelivr.net/npm/tailwindcss@3.3.3/dist/tailwind.min.css" rel="stylesheet">
</head><body class="p-4 bg-gray-100">
<h1 class="text-3xl font-bold mb-4">Trojan Public Panel</h1>
<?php foreach($servers as $name=>$s): ?>
<div class="p-4 mb-2 bg-white rounded shadow">
<h2 class="text-xl font-semibold"><?= $name ?></h2>
<p>IP: <?= $s['ip'] ?> PORT: <?= $s['port'] ?></p>
<button onclick="alert('Create account for <?= $name ?>')"
 class="bg-blue-500 text-white px-2 py-1 rounded">Create Account</button>
</div>
<?php endforeach; ?>
</body></html>
EOF

# ----------------------
# Servers JSON
# ----------------------
[ ! -f "$ADMIN_DIR/servers.json" ] && echo "{}" > "$ADMIN_DIR/servers.json"

# ----------------------
# PHP create_user.php to SSH into server and run trojan-menu
# ----------------------
cat > "$ADMIN_DIR/create_user.php" <<'EOF'
<?php
$servers=json_decode(file_get_contents('servers.json'),true);
$server=$_GET['server']??'';
$username=$_GET['username']??'';
$password=$_GET['password']??'';
if(!isset($servers[$server])){ echo "Server not found"; exit; }
$s=$servers[$server];
$cmd="sshpass -p '{$s['pass']}' ssh -o StrictHostKeyChecking=no {$s['user']}@{$s['ip']} 'echo \"{$password}\" | /usr/local/bin/trojan-menu'";
$output=shell_exec($cmd);
echo "User {$username} created on {$server}\nOutput:\n".$output;
?>
EOF

chown -R www-data:www-data "$WWW_DIR"
systemctl restart php8.2-fpm || true

echo "✅ Trojan panel installed! Admin: /admin (admin/admin123), Public panel: /"
