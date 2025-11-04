#!/bin/bash
set -euo pipefail

# install-panel.sh
# Usage: run as root. Installs PHP & panel files (admin + public) and an API endpoint that updates servers.json.
# The API can create users on remote trojan servers via ssh (uses sshpass by default).

PANEL_DIR="/var/www/html"
ADMIN_DIR="$PANEL_DIR/admin"
SERVERS_FILE="$ADMIN_DIR/servers.json"
API_FILE="$ADMIN_DIR/api.php"
CREDS_FILE="$ADMIN_DIR/admin_credentials.json"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

apt update -y
apt install -y php-fpm php-cli php-json nginx sshpass jq curl || true

# Ensure web root exists
mkdir -p "$ADMIN_DIR"
chown -R www-data:www-data "$PANEL_DIR"

# init json and creds
[ -f "$SERVERS_FILE" ] || echo '{}' > "$SERVERS_FILE"
[ -f "$CREDS_FILE" ] || echo '{"user":"admin","pass":"admin123"}' > "$CREDS_FILE"

# ---------- API ----------
cat > "$API_FILE" <<'EOF'
<?php
// admin/api.php
header('Content-Type: application/json; charset=utf-8');
$servers_file = __DIR__ . '/servers.json';
if (!file_exists($servers_file)) file_put_contents($servers_file, '{}');
$data = json_decode(file_get_contents($servers_file), true);
$raw = file_get_contents('php://input');
$post = json_decode($raw, true) ?: [];
$action = $_GET['action'] ?? ($post['action'] ?? 'list');

if ($action === 'list') {
    echo json_encode($data);
    exit;
}

if ($action === 'addServer') {
    $name = $post['name'] ?? '';
    if ($name === '') { echo json_encode(['error'=>'no name']); exit; }
    $data[$name] = [
        'ip' => $post['ip'] ?? '',
        'port' => intval($post['port'] ?? 2443),
        'expireDays' => intval($post['expireDays'] ?? 7),
        'sshUser' => $post['sshUser'] ?? '',
        'sshPass' => $post['sshPass'] ?? '',
        'users' => []
    ];
    file_put_contents($servers_file, json_encode($data, JSON_PRETTY_PRINT));
    echo json_encode(['status'=>'ok']);
    exit;
}

if ($action === 'editServer') {
    $old = $post['oldName'] ?? '';
    $new = $post['newName'] ?? $old;
    if (isset($data[$old])) {
        $data[$new] = $data[$old];
        unset($data[$old]);
        $data[$new]['ip'] = $post['ip'] ?? $data[$new]['ip'];
        $data[$new]['port'] = intval($post['port'] ?? $data[$new]['port']);
        $data[$new]['expireDays'] = intval($post['expireDays'] ?? $data[$new]['expireDays']);
        $data[$new]['sshUser'] = $post['sshUser'] ?? $data[$new]['sshUser'];
        $data[$new]['sshPass'] = $post['sshPass'] ?? $data[$new]['sshPass'];
        file_put_contents($servers_file, json_encode($data, JSON_PRETTY_PRINT));
    }
    echo json_encode(['status'=>'ok']);
    exit;
}

if ($action === 'addUser') {
    $server = $post['server'] ?? '';
    $username = $post['username'] ?? '';
    $password = $post['password'] ?? '';
    $expire = $post['expire'] ?? '';
    $index = isset($post['index']) ? intval($post['index']) : -1;
    if (!isset($data[$server])) { echo json_encode(['error'=>'server not found']); exit; }
    if (!isset($data[$server]['users'])) $data[$server]['users'] = [];
    $u = ['username'=>$username, 'password'=>$password, 'expire'=>$expire];
    if ($index >= 0) $data[$server]['users'][$index] = $u; else $data[$server]['users'][] = $u;
    file_put_contents($servers_file, json_encode($data, JSON_PRETTY_PRINT));
    echo json_encode(['status'=>'ok']);
    exit;
}

if ($action === 'createUserPublic') {
    $server = $post['server'] ?? '';
    if (!isset($data[$server])) { echo json_encode(['error'=>'server not found']); exit; }
    $sshUser = $data[$server]['sshUser'];
    $sshPass = $data[$server]['sshPass'];
    $sshIp = $data[$server]['ip'];
    $expireDays = intval($data[$server]['expireDays']);
    // generate credentials
    $username = 'user' . rand(1000,9999);
    $password = substr(bin2hex(random_bytes(4)),0,8);
    // Call remote trojan-menu add_remote via sshpass
    $cmd = "sshpass -p " . escapeshellarg($sshPass) . " ssh -o StrictHostKeyChecking=no " . escapeshellarg($sshUser . "@" . $sshIp) . " /usr/local/bin/trojan-menu add_remote " . escapeshellarg($username) . " " . escapeshellarg($password) . " " . escapeshellarg($expireDays) . " 2>&1";
    exec($cmd, $out, $rc);
    if ($rc === 0) {
        if (!isset($data[$server]['users'])) $data[$server]['users'] = [];
        $data[$server]['users'][] = ['username'=>$username,'password'=>$password,'expire'=>date('Y-m-d', strtotime("+$expireDays days"))];
        file_put_contents($servers_file, json_encode($data, JSON_PRETTY_PRINT));
        echo json_encode(['status'=>'ok','username'=>$username,'password'=>$password,'expire'=>$expireDays,'ip'=>$sshIp,'port'=>$data[$server]['port']]);
    } else {
        echo json_encode(['error'=>'remote command failed','output'=>implode("\n",$out)]);
    }
    exit;
}

echo json_encode(['error'=>'unknown action']);
EOF

# ---------- Admin panel (index.php) ----------
cat > "$ADMIN_DIR/index.php" <<'EOF'
<?php
// admin/index.php - simple admin UI that talks to api.php
session_start();
$creds = json_decode(file_get_contents(__DIR__ . '/admin_credentials.json'), true);
if(isset($_POST['login'])){
  if($_POST['username']==$creds['user'] && $_POST['password']==$creds['pass']) $_SESSION['admin']=true;
  else $err="Invalid";
}
if(isset($_GET['logout'])){ session_destroy(); header('Location:index.php'); exit; }
if(!isset($_SESSION['admin'])) {
?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><script src="https://cdn.tailwindcss.com"></script><title>Admin Login</title></head><body class="bg-gray-100 flex items-center justify-center h-screen">
<form method="post" class="bg-white p-6 rounded shadow w-full max-w-md">
<h2 class="text-2xl mb-4">Admin Login</h2>
<?php if(isset($err)) echo "<div class='text-red-500 mb-2'>$err</div>"; ?>
<input name="username" placeholder="username" class="border p-2 w-full mb-2">
<input name="password" type="password" placeholder="password" class="border p-2 w-full mb-4">
<button class="bg-blue-600 text-white p-2 w-full rounded" name="login">Login</button>
</form></body></html>
<?php exit; } ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><script src="https://cdn.tailwindcss.com"></script><title>Admin</title></head><body class="bg-gray-100 p-4">
<div class="max-w-6xl mx-auto">
<header class="flex justify-between items-center mb-4"><h1 class="text-2xl font-bold">Trojan Admin</h1><a href="?logout=1" class="text-red-600">Logout</a></header>

<div id="servers" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"></div>
<button onclick="openAddServer()" class="mt-4 bg-green-600 text-white px-3 py-2 rounded">Add Server</button>

<!-- server modal -->
<div id="serverModal" class="fixed inset-0 bg-black bg-opacity-40 hidden items-center justify-center">
  <div class="bg-white p-4 rounded w-full max-w-md">
    <h2 id="serverModalTitle" class="text-lg font-bold mb-2">Add Server</h2>
    <form id="serverForm">
      <input id="s_name" placeholder="Server name" class="border p-2 w-full mb-2" required>
      <input id="s_ip" placeholder="IP" class="border p-2 w-full mb-2" required>
      <input id="s_port" placeholder="Port" class="border p-2 w-full mb-2" required>
      <input id="s_expire" placeholder="Default expire days" class="border p-2 w-full mb-2" required>
      <input id="s_ssh_user" placeholder="SSH user" class="border p-2 w-full mb-2" required>
      <input id="s_ssh_pass" placeholder="SSH pass" class="border p-2 w-full mb-4" required>
      <div class="flex justify-end gap-2"><button type="button" onclick="closeServerModal()" class="px-3 py-1 bg-gray-300 rounded">Cancel</button><button class="px-3 py-1 bg-green-600 text-white rounded">Save</button></div>
    </form>
  </div>
</div>

<!-- user modal -->
<div id="userModal" class="fixed inset-0 bg-black bg-opacity-40 hidden items-center justify-center">
  <div class="bg-white p-4 rounded w-full max-w-md">
    <h2 id="userModalTitle" class="text-lg font-bold mb-2">Add User</h2>
    <form id="userForm">
      <input id="u_server" readonly class="border p-2 w-full mb-2">
      <input id="u_username" placeholder="username or leave blank to auto" class="border p-2 w-full mb-2">
      <input id="u_password" placeholder="password or leave blank to auto" class="border p-2 w-full mb-2">
      <input id="u_expire" placeholder="expire days" class="border p-2 w-full mb-4" required>
      <div class="flex justify-end gap-2"><button type="button" onclick="closeUserModal()" class="px-3 py-1 bg-gray-300 rounded">Cancel</button><button class="px-3 py-1 bg-green-600 text-white rounded">Save</button></div>
    </form>
  </div>
</div>

</div>

<script>
const API='api.php';
function fetchServers(){
  return fetch(API+'?action=list').then(r=>r.json());
}
function renderServers(){
  fetchServers().then(data=>{
    const wrap=document.getElementById('servers'); wrap.innerHTML='';
    for(const name in data){
      const srv=data[name];
      const el=document.createElement('div');
      el.className='bg-white p-4 rounded shadow';
      let usersHtml='';
      if(Array.isArray(srv.users)){
        usersHtml=srv.users.map(u=>`<div class="flex justify-between"><div>${u.username} <small class="text-gray-500">(${u.expire})</small></div><div><button onclick="openEditUser('${name}','${u.username}')" class="text-yellow-600">Edit</button></div></div>`).join('');
      }
      el.innerHTML=`<h3 class="font-semibold">${name}</h3><div class="text-sm text-gray-600">${srv.ip}:${srv.port}</div><div class="mt-2">${usersHtml}</div><div class="mt-3"><button onclick="openAddUser('${name}')" class="bg-blue-600 text-white px-2 py-1 rounded">Add User</button> <button onclick="openEditServer('${name}')" class="bg-yellow-500 text-white px-2 py-1 rounded">Edit</button></div>`;
      wrap.appendChild(el);
    }
  })
}

function openAddServer(){ document.getElementById('serverModal').classList.remove('hidden'); document.getElementById('serverModal').classList.add('flex'); document.getElementById('serverModalTitle').innerText='Add Server'; document.getElementById('serverForm').onsubmit=submitAddServer; }
function closeServerModal(){ document.getElementById('serverModal').classList.add('hidden'); document.getElementById('serverModal').classList.remove('flex'); }
function submitAddServer(e){ e.preventDefault(); const name=document.getElementById('s_name').value; const ip=document.getElementById('s_ip').value; const port=document.getElementById('s_port').value; const expire=document.getElementById('s_expire').value; const sshUser=document.getElementById('s_ssh_user').value; const sshPass=document.getElementById('s_ssh_pass').value; fetch(API,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'addServer',name,ip,port,expireDays:expire,sshUser,sshPass})}).then(()=>{ closeServerModal(); renderServers(); }); }

function openAddUser(server){ document.getElementById('userModal').classList.remove('hidden'); document.getElementById('userModal').classList.add('flex'); document.getElementById('u_server').value=server; document.getElementById('userForm').onsubmit=submitAddUser; document.getElementById('userModalTitle').innerText='Add User for '+server; }
function closeUserModal(){ document.getElementById('userModal').classList.add('hidden'); document.getElementById('userModal').classList.remove('flex'); }
function submitAddUser(e){ e.preventDefault(); const server=document.getElementById('u_server').value; let username=document.getElementById('u_username').value; let password=document.getElementById('u_password').value; const expire=document.getElementById('u_expire').value; if(!username) username='user'+Math.floor(Math.random()*10000); if(!password) password=Math.random().toString(36).slice(-8); fetch(API,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'addUser',server,username,password,expire})}).then(()=>{ closeUserModal(); renderServers(); }); }

function openEditServer(name){ fetch(API+'?action=list').then(r=>r.json()).then(data=>{ const s=data[name]; document.getElementById('s_name').value=name; document.getElementById('s_ip').value=s.ip; document.getElementById('s_port').value=s.port; document.getElementById('s_expire').value=s.expireDays; document.getElementById('s_ssh_user').value=s.sshUser; document.getElementById('s_ssh_pass').value=s.sshPass; document.getElementById('serverModalTitle').innerText='Edit Server'; document.getElementById('serverModal').classList.remove('hidden'); document.getElementById('serverModal').classList.add('flex'); document.getElementById('serverForm').onsubmit=function(e){ e.preventDefault(); const newName=document.getElementById('s_name').value; const ip=document.getElementById('s_ip').value; const port=document.getElementById('s_port').value; const expire=document.getElementById('s_expire').value; const sshUser=document.getElementById('s_ssh_user').value; const sshPass=document.getElementById('s_ssh_pass').value; fetch(API,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'editServer',oldName:name,newName,newName,ip,port,expireDays:expire,sshUser:sshUser,sshPass:sshPass})}).then(()=>{ closeServerModal(); renderServers(); }); }; }); }

function openEditUser(server, username){ /* can implement edit UX; for now simple alert */ alert('Edit user:'+username+' on '+server); }

renderServers();
</script>
</body></html>
EOF

# ---------- Public panel ----------
cat > "$PANEL_DIR/index.php" <<'EOF'
<?php
$servers = json_decode(file_get_contents(__DIR__ . '/admin/servers.json'), true);
?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><script src="https://cdn.tailwindcss.com"></script><title>Public Panel</title></head><body class="bg-gray-100 p-4">
<div class="container mx-auto"><h1 class="text-3xl font-bold mb-6">Trojan Public Panel</h1>
<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
<?php foreach($servers as $name=>$s){ ?>
<div class="bg-white p-4 rounded shadow">
<h3 class="font-semibold"><?php echo htmlspecialchars($name);?></h3>
<div class="text-sm text-gray-600"><?php echo htmlspecialchars($s['ip']);?>:<?php echo intval($s['port']);?></div>
<button onclick="createAccount('<?php echo addslashes($name);?>')" class="mt-2 bg-blue-600 text-white px-3 py-1 rounded">Create Account</button>
<div id="res_<?php echo htmlspecialchars($name);?>"></div>
</div>
<?php } ?>
</div></div>
<script>
function createAccount(server){
  const box=document.getElementById('res_'+server);
  box.innerHTML='<div class="text-sm text-gray-500">Creating account...</div>';
  fetch('admin/api.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'createUserPublic',server})})
  .then(r=>r.json()).then(res=>{
    if(res.status=='ok'){
      const link='trojan://'+res.password+'@'+res.ip+':'+res.port;
      box.innerHTML='<div class="bg-green-50 p-2 rounded"><div><b>Username:</b> '+res.username+'</div><div><b>Password:</b> '+res.password+'</div><div><b>Expires in days:</b> '+res.expire+'</div><div><b>Link:</b> <input readonly class="border p-1" value="'+link+'"> <button onclick="navigator.clipboard.writeText(\''+link+'\')" class="ml-2 bg-green-600 text-white px-2 py-1 rounded">Copy</button></div></div>';
    } else {
      box.innerHTML='<div class="text-red-600">Error: '+(res.error||res.msg||'unknown')+'</div>';
    }
  }).catch(e=>box.innerHTML='<div class="text-red-600">Request failed</div>');
}
</script>
</body></html>
EOF

# Set permissions
chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR"

# Restart PHP-FPM and nginx
systemctl restart php*-fpm || true
systemctl restart nginx || true

echo "install-panel.sh finished."
echo "Admin: /admin (default admin/admin123)  Public: /"
