#!/bin/bash
set -euo pipefail

PANEL_DIR="/var/www/html"
ADMIN_DIR="$PANEL_DIR/admin"
SERVERS_FILE="$ADMIN_DIR/servers.json"

# Remove existing panel
rm -rf "$ADMIN_DIR" "$PANEL_DIR/index.php"
mkdir -p "$ADMIN_DIR"

# Initialize servers JSON
touch "$SERVERS_FILE"
echo '{}' > "$SERVERS_FILE"

# ---------------- Admin Panel ----------------
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
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
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

<!-- Add/Edit User Modal -->
<div id="userModal" class="fixed inset-0 bg-black bg-opacity-50 hidden items-center justify-center z-50">
  <div class="bg-white p-6 rounded-xl shadow-lg w-full max-w-md">
    <h2 id="userModalTitle" class="text-2xl font-bold mb-4">Add User</h2>
    <form id="userForm">
      <input type="text" id="username" placeholder="Username" class="w-full p-3 mb-2 border rounded-lg" required>
      <input type="text" id="password" placeholder="Password" class="w-full p-3 mb-2 border rounded-lg" required>
      <input type="number" id="expire" placeholder="Expire in days" class="w-full p-3 mb-4 border rounded-lg" required>
      <div class="flex justify-end gap-2">
        <button type="button" onclick="closeUserModal()" class="bg-gray-400 hover:bg-gray-500 text-white px-4 py-2 rounded-lg">Cancel</button>
        <button type="submit" class="bg-green-500 hover:bg-green-600 text-white px-4 py-2 rounded-lg">Save</button>
      </div>
    </form>
  </div>
</div>

<script>
const serversFile='servers.json';
let currentEditServer='';
let editUserIndex=-1;

// Load servers
function loadServers(){
    fetch(serversFile).then(r=>r.json()).then(data=>{
        const div=document.getElementById('servers'); div.innerHTML='';
        for(const s in data){
            const d=document.createElement('div');
            d.className='bg-white p-4 rounded-xl shadow flex flex-col justify-between';
            let usersList='';
            if(data[s].users){ for(const [i,u] of data[s].users.entries()){ 
                usersList+=`${u.username} (${u.expire}) <button onclick="editUser('${s}',${i})" class="bg-yellow-500 px-1 rounded text-white ml-1">Edit</button><br>`; 
            } }
            d.innerHTML=`<div><b>${s}</b><br>IP: ${data[s].ip}<br>Port: ${data[s].port}<br>Users:<br>${usersList}</div>
            <div class="mt-2 flex gap-2">
                <button onclick="editServer('${s}')" class="bg-yellow-500 hover:bg-yellow-600 text-white px-2 py-1 rounded-lg">Edit Server</button>
                <button onclick="addUser('${s}')" class="bg-blue-500 hover:bg-blue-600 text-white px-2 py-1 rounded-lg">Add User</button>
            </div>`;
            div.appendChild(d);
        }
    });
}

// Modal functions
function openAddServerModal(){document.getElementById('addServerModal').classList.remove('hidden');document.getElementById('addServerModal').classList.add('flex');}
function closeAddServerModal(){document.getElementById('addServerModal').classList.add('hidden');document.getElementById('addServerModal').classList.remove('flex');}
function openUserModal(){document.getElementById('userModal').classList.remove('hidden');document.getElementById('userModal').classList.add('flex');}
function closeUserModal(){document.getElementById('userModal').classList.add('hidden');document.getElementById('userModal').classList.remove('flex');}

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

// Add User
function addUser(server){
    currentEditServer=server; editUserIndex=-1;
    document.getElementById('userModalTitle').innerText="Add User for "+server;
    document.getElementById('username').value='';
    document.getElementById('password').value='';
    document.getElementById('expire').value='';
    openUserModal();
}

// Edit User
function editUser(server,index){
    currentEditServer=server; editUserIndex=index;
    fetch(serversFile).then(r=>r.json()).then(data=>{
        const u=data[server].users[index];
        document.getElementById('userModalTitle').innerText="Edit User for "+server;
        document.getElementById('username').value=u.username;
        document.getElementById('password').value=u.password;
        document.getElementById('expire').value=u.expire;
        openUserModal();
    });
}

// User form submit
document.getElementById('userForm').addEventListener('submit',function(e){
    e.preventDefault();
    const username=document.getElementById('username').value;
    const password=document.getElementById('password').value;
    const expire=document.getElementById('expire').value;

    fetch(serversFile).then(r=>r.json()).then(data=>{
        if(!data[currentEditServer].users) data[currentEditServer].users=[];
        if(editUserIndex>=0){ // edit
            data[currentEditServer].users[editUserIndex]={username,password,expire};
        } else { // add
            data[currentEditServer].users.push({username,password,expire});
        }
        fetch(serversFile,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)})
        .then(()=>{ loadServers(); closeUserModal(); alert('User saved successfully'); });
    });
});

// Dummy edit server (can add modal later)
function editServer(server){ alert("Edit server: "+server+" (modal can be added)"); }

loadServers();
</script>
EOF

# ---------------- Public Panel ----------------
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
<body class="bg-gray-100 p-4 min-h-screen">
<div class="container mx-auto">
<h1 class="text-3xl font-bold mb-6">Trojan Public Panel</h1>
<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
<?php foreach($servers as $sname=>$s){ ?>
<div class="bg-white p-4 rounded-xl shadow flex flex-col justify-between">
<b><?php echo $sname;?></b><br>IP: <?php echo $s['ip'];?><br>Port: <?php echo $s['port'];?>
<button onclick="createAccount('<?php echo $sname;?>')" class="mt-2 bg-blue-500 hover:bg-blue-600 text-white px-2 py-1 rounded-lg">Create Account</button>
</div>
<?php } ?>
</div>
</div>

<script>
function createAccount(server){
    let username='user'+Math.floor(Math.random()*10000);
    let password=Math.random().toString(36).slice(-8);
    alert("Created on "+server+"\nUsername:"+username+"\nPassword:"+password+"\nExpiration depends on server default");
    // Here you can implement AJAX POST to server via PHP to update servers.json if needed
}
</script>
</body>
</html>
EOF

echo "=== Trojan Admin/Public Panel Installed ==="
echo "Admin panel: http://<YOUR-IP>/admin/"
echo "Public panel: http://<YOUR-IP>/"
echo "Default login: admin / admin123"
