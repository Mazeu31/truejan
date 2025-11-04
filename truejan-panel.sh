#!/bin/bash
set -euo pipefail

PANEL_DIR="/var/www/html"
ADMIN_DIR="$PANEL_DIR/admin"
SERVERS_FILE="$ADMIN_DIR/servers.json"

# Remove existing panel
rm -rf "$ADMIN_DIR" "$PANEL_DIR/index.php"

# Create directories
mkdir -p "$ADMIN_DIR"
touch "$SERVERS_FILE"
echo '{}' > "$SERVERS_FILE"

# ------------------- Admin Panel -------------------
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
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Admin Login</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-100 flex items-center justify-center h-screen">
<form method="post" class="bg-white p-8 rounded-xl shadow-lg w-full max-w-md">
<h2 class="text-3xl font-bold mb-6 text-center">Admin Login</h2>
<?php if(isset($error)){echo "<p class='text-red-500 mb-4'>$error</p>";} ?>
<input type="text" name="username" placeholder="Username" class="w-full p-3 mb-4 border rounded-lg" required>
<input type="password" name="password" placeholder="Password" class="w-full p-3 mb-6 border rounded-lg" required>
<button type="submit" name="login" class="w-full bg-blue-600 hover:bg-blue-700 text-white p-3 rounded-lg font-semibold">Login</button>
</form>
</body></html>
<?php exit;} ?>

<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Trojan Admin Panel</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-100 min-h-screen p-4">
<div class="container mx-auto">
<header class="flex justify-between items-center mb-6">
<h1 class="text-3xl font-bold">Trojan Admin Panel</h1>
<a href="?logout=1" class="bg-red-500 hover:bg-red-600 text-white px-4 py-2 rounded-lg">Logout</a>
</header>

<section class="mb-6">
<h2 class="text-xl font-semibold mb-2">Servers</h2>
<div id="servers" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"></div>
<button onclick="openAddServerModal()" class="mt-4 bg-green-500 hover:bg-green-600 text-white px-4 py-2 rounded-lg">Add Server</button>
</section>
</div>

<!-- Add Server Modal -->
<div id="addServerModal" class="fixed inset-0 bg-black bg-opacity-50 hidden items-center justify-center z-50">
  <div class="bg-white p-6 rounded-xl shadow-lg w-full max-w-md">
    <h2 class="text-2xl font-bold mb-4">Add New Server</h2>
    <form id="addServerForm">
      <input type="text" id="serverName" placeholder="Server Name" class="w-full p-3 mb-2 border rounded-lg" required>
      <input type="text" id="serverIP" placeholder="Server IP" class="w-full p-3 mb-2 border rounded-lg" required>
      <input type="number" id="serverPort" placeholder="Port" class="w-full p-3 mb-2 border rounded-lg" required>
      <input type="number" id="expireDays" placeholder="Default Expire Days" class="w-full p-3 mb-2 border rounded-lg" required>
      <input type="text" id="sshUser" placeholder="SSH User" class="w-full p-3 mb-2 border rounded-lg" required>
      <input type="password" id="sshPass" placeholder="SSH Password" class="w-full p-3 mb-4 border rounded-lg" required>
      <div class="flex justify-end gap-2">
        <button type="button" onclick="closeAddServerModal()" class="bg-gray-400 hover:bg-gray-500 text-white px-4 py-2 rounded-lg">Cancel</button>
        <button type="submit" class="bg-green-500 hover:bg-green-600 text-white px-4 py-2 rounded-lg">Add</button>
      </div>
    </form>
  </div>
</div>

<script>
const serversFile='servers.json';

// Load servers
function loadServers(){
    fetch(serversFile).then(r=>r.json()).then(data=>{
        const div=document.getElementById('servers'); div.innerHTML='';
        for(const s in data){
            const d=document.createElement('div');
            d.className='bg-white p-4 rounded-xl shadow flex flex-col justify-between';
            let usersList='';
            if(data[s].users){ for(const u of data[s].users){ usersList+=`${u.username} (${u.expire})<br>`; } }
            d.innerHTML=`<div><b>${s}</b><br>IP: ${data[s].ip}<br>Port: ${data[s].port}<br>Users:<br>${usersList}</div>
            <div class="mt-2 flex gap-2">
                <button onclick="editServer('${s}')" class="bg-yellow-500 hover:bg-yellow-600 text-white px-2 py-1 rounded-lg">Edit</button>
                <button onclick="addUser('${s}')" class="bg-blue-500 hover:bg-blue-600 text-white px-2 py-1 rounded-lg">Add User</button>
            </div>`;
            div.appendChild(d);
        }
    });
}

// Modal functions
function openAddServerModal(){document.getElementById('addServerModal').classList.remove('hidden');document.getElementById('addServerModal').classList.add('flex');}
function closeAddServerModal(){document.getElementById('addServerModal').classList.add('hidden');document.getElementById('addServerModal').classList.remove('flex');}

// Add Server Submit
document.getElementById('addServerForm').addEventListener('submit', function(e){
    e.preventDefault();
    const name=document.getElementById('serverName').value;
    const ip=document.getElementById('serverIP').value;
    const port=document.getElementById('serverPort').value;
    const expireDays=document.getElementById('expireDays').value;
    const user=document.getElementById('sshUser').value;
    const pass=document.getElementById('sshPass').value;

    fetch(serversFile).then(r=>r.json()).then(data=>{
        data[name]={ip,port,expireDays,user,pass,users:[]};
        fetch(serversFile,{
            method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(data)
        }).then(()=>{ loadServers(); closeAddServerModal(); alert('Server added successfully'); });
    });
});

// Dummy add user function (can be replaced with modal later)
function addUser(server){ alert('Add user on '+server); }
function editServer(server){ alert('Edit server '+server); }

loadServers();
</script>
EOF

# ------------------- Public Panel -------------------
cat > "$PANEL_DIR/index.php" <<'EOF'
<?php
$serversFile='admin/servers.json';
$servers=json_decode(file_get_contents($serversFile),true);
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Trojan Public Panel</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-100 min-h-screen p-4">
<div class="container mx-auto">
<h1 class="text-3xl font-bold mb-6">Trojan Public Panel</h1>
<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
<?php foreach($servers as $name=>$s): ?>
<div class="bg-white p-4 rounded-xl shadow flex flex-col justify-between">
<h2 class="text-xl font-semibold mb-2"><?= htmlspecialchars($name) ?></h2>
<p>IP: <?= htmlspecialchars($s['ip']) ?><br>Port: <?= htmlspecialchars($s['port']) ?></p>
<button onclick="alert('Create account for <?= htmlspecialchars($name) ?>')" class="mt-2 bg-blue-500 hover:bg-blue-600 text-white px-2 py-1 rounded-lg">Create Account</button>
</div>
<?php endforeach; ?>
</div>
</div>
</body>
</html>
EOF

echo "✅ Trojan Panel installed/updated. Admin panel: /admin, Public panel: /index.php"
