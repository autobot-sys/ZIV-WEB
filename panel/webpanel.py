#!/usr/bin/env python3
"""
NOOBS ZIVPN UDP Web Panel — with user limits & monitoring
Zero external dependencies — pure Python3 stdlib only
Default port : 8080
Config file  : /etc/zivpn/webpanel.conf
"""

import json, os, sys, subprocess, hashlib, secrets, time, socket, re, threading, urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from threading import Lock
from urllib.parse import urlparse

CONFIG_FILE = "/etc/zivpn/config.json"
META_FILE   = "/etc/zivpn/users_meta.json"
PANEL_CONF  = "/etc/zivpn/webpanel.conf"
sessions    = {}
SESS_TTL    = 3600

SESSION_LOCK = Lock()
STATUS_CACHE = {"data": None, "ts": 0.0}
LOGS_CACHE   = {"data": None, "ts": 0.0}
STATUS_CACHE_TTL = 2.0
LOGS_CACHE_TTL   = 3.0

# ========== METADATA HELPERS (per‑user limits) ==========
def load_meta():
    try:
        with open(META_FILE) as f:
            return json.load(f)
    except:
        return {}

def save_meta(meta):
    with open(META_FILE, "w") as f:
        json.dump(meta, f, indent=2)

def init_meta_for_user(pw, device_limit=0, data_limit_gb=0, validity_days=0):
    meta = load_meta()
    if pw in meta:
        return
    expiry = None
    if validity_days > 0:
        # Use TimeAPI to get accurate future timestamp
        expiry = get_future_timestamp(validity_days)
    meta[pw] = {
        "device_limit": device_limit,
        "data_limit_bytes": data_limit_gb * 1024**3 if data_limit_gb > 0 else 0,
        "data_used_bytes": 0,
        "expiry": expiry,
        "created_at": time.time()
    }
    save_meta(meta)
    # Create iptables quota chain for this user (if data limit > 0)
    if data_limit_gb > 0:
        setup_iptables_quota(pw, data_limit_gb)

def setup_iptables_quota(pw, limit_gb):
    """Create an iptables quota rule for this user's traffic.
       Since we can't match by password, we'll match by source IP
       after the first authentication. The monitor service will
       dynamically add IPs to this user's chain."""
    # Create a dedicated chain for this user
    subprocess.run(["iptables", "-N", f"ZIV_USER_{pw}"], stderr=subprocess.DEVNULL)
    # Add quota rule
    limit_bytes = int(limit_gb * 1024**3)
    subprocess.run([
        "iptables", "-A", f"ZIV_USER_{pw}",
        "-m", "quota", "--quota", str(limit_bytes),
        "-j", "RETURN"
    ], stderr=subprocess.DEVNULL)
    subprocess.run([
        "iptables", "-A", f"ZIV_USER_{pw}",
        "-j", "DROP"
    ], stderr=subprocess.DEVNULL)

def delete_iptables_chain(pw):
    subprocess.run(["iptables", "-F", f"ZIV_USER_{pw}"], stderr=subprocess.DEVNULL)
    subprocess.run(["iptables", "-X", f"ZIV_USER_{pw}"], stderr=subprocess.DEVNULL)

def update_bandwidth_usage(pw, additional_bytes):
    meta = load_meta()
    if pw in meta:
        meta[pw]["data_used_bytes"] = meta[pw].get("data_used_bytes", 0) + additional_bytes
        save_meta(meta)

def get_user_status(pw):
    """Returns dict with device_count, remaining_bytes, remaining_days, expired"""
    meta = load_meta()
    data = meta.get(pw, {})
    device_limit = data.get("device_limit", 0)
    data_limit = data.get("data_limit_bytes", 0)
    data_used = data.get("data_used_bytes", 0)
    expiry_ts = data.get("expiry", None)
    remaining_bytes = data_limit - data_used if data_limit > 0 else 0
    remaining_days = -1
    if expiry_ts:
        remaining_days = max(0, int((expiry_ts - time.time()) / 86400))
    devices = get_active_devices_for_user(pw)
    return {
        "devices": len(devices),
        "device_limit": device_limit,
        "remaining_bytes_gb": round(remaining_bytes / (1024**3), 2) if remaining_bytes > 0 else 0,
        "remaining_days": remaining_days,
        "expired": expiry_ts is not None and expiry_ts < time.time()
    }

def get_active_devices_for_user(pw):
    """Return list of source IPs currently using this password"""
    ip_user_map = {}
    try:
        lines = subprocess.run(["journalctl", "-u", "zivpn", "-n", "200", "--no-pager"],
                               capture_output=True, text=True, timeout=2).stdout
        for line in lines.splitlines():
            if "authenticated" in line and f"password={pw}" in line:
                m = re.search(r"from (\d+\.\d+\.\d+\.\d+)", line)
                if m:
                    ip_user_map[m.group(1)] = pw
    except: pass
    port = get_listen_port()
    conns = []
    try:
        r = subprocess.run(["ss", "-Hanu"], capture_output=True, text=True, timeout=2)
        for line in r.stdout.splitlines():
            if f":{port}" in line:
                parts = line.split()
                if len(parts) >= 6:
                    peer = parts[5]
                    if ":" in peer:
                        ip = peer.rsplit(":",1)[0].strip("[]")
                        if ip in ip_user_map and ip_user_map[ip] == pw:
                            conns.append(ip)
    except: pass
    return list(set(conns))

def get_future_timestamp(days):
    """Get accurate UTC timestamp `days` from now using TimeAPI"""
    try:
        url = "https://timeapi.io/api/Time/current/zone?timeZone=UTC"
        with urllib.request.urlopen(url, timeout=5) as resp:
            data = json.loads(resp.read().decode())
            now_epoch = data.get("epochTime", time.time())
        return now_epoch + days * 86400
    except:
        return time.time() + days * 86400

def enforce_expiry():
    """Remove expired users and restart service if any removed"""
    changed = False
    meta = load_meta()
    for pw, data in list(meta.items()):
        if data.get("expiry") and data["expiry"] < time.time():
            remove_user(pw)       # from config.json
            delete_iptables_chain(pw)
            del meta[pw]
            changed = True
    if changed:
        save_meta(meta)
        svc_action("restart")
    return changed

# ========== CONFIG & USER MANAGEMENT ==========
def load_panel_conf():
    try:
        with open(PANEL_CONF) as f:
            return json.load(f)
    except:
        return {"port": 8080, "pass_hash": hashlib.sha256(b"admin").hexdigest()}

def save_panel_conf(c):
    with open(PANEL_CONF, "w") as f:
        json.dump(c, f, indent=2)

def hash_pw(pw):
    return hashlib.sha256(pw.encode()).hexdigest()

def read_zivpn():
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except:
        return {"listen": ":5667", "auth": {"mode": "passwords", "config": []}}

def write_zivpn(d):
    with open(CONFIG_FILE, "w") as f:
        json.dump(d, f, indent=2)

def get_users():
    return read_zivpn().get("auth", {}).get("config", [])

def add_user(pw, device_limit=0, data_limit_gb=0, validity_days=0):
    d = read_zivpn()
    d.setdefault("auth", {"mode": "passwords", "config": []})
    d["auth"].setdefault("config", [])
    if pw not in d["auth"]["config"]:
        d["auth"]["config"].append(pw)
        write_zivpn(d)
        init_meta_for_user(pw, device_limit, data_limit_gb, validity_days)
        return True
    return False

def remove_user(pw):
    d = read_zivpn()
    cfg = d.get("auth", {}).get("config", [])
    if pw in cfg:
        cfg.remove(pw)
        write_zivpn(d)
        delete_iptables_chain(pw)
        meta = load_meta()
        if pw in meta:
            del meta[pw]
            save_meta(meta)
        return True
    return False

def clear_users():
    d = read_zivpn()
    d.setdefault("auth", {})["config"] = []
    write_zivpn(d)
    for pw in load_meta().keys():
        delete_iptables_chain(pw)
    save_meta({})

def get_listen_port():
    return read_zivpn().get("listen", ":5667").lstrip(":")

def svc_status():
    try:
        r = subprocess.run(["systemctl", "is-active", "zivpn"], capture_output=True, text=True, timeout=2)
        return r.stdout.strip() or "unknown"
    except:
        return "unknown"

def svc_action(action):
    try:
        r = subprocess.run(["systemctl", action, "zivpn"], capture_output=True, text=True, timeout=10)
        return r.returncode == 0
    except:
        return False

def get_logs(n=30):
    try:
        r = subprocess.run(["journalctl", "-u", "zivpn", f"-n{n}", "--no-pager", "--output=short-iso"],
                           capture_output=True, text=True, timeout=3)
        return r.stdout
    except:
        return ""

def server_ip():
    try:
        r = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=2)
        ips = (r.stdout or "").split()
        for ip in ips:
            if ip and not ip.startswith("127."):
                return ip
    except: pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(1.5)
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except:
        return "unknown"

def get_connections():
    port = get_listen_port()
    try:
        r = subprocess.run(["ss", "-Hanu"], capture_output=True, text=True, timeout=2)
        return [l for l in r.stdout.splitlines() if f":{port}" in l]
    except:
        return []

def get_status_snapshot():
    now = time.time()
    cached = STATUS_CACHE["data"]
    if cached and (now - STATUS_CACHE["ts"]) < STATUS_CACHE_TTL:
        return cached
    data = {
        "service": svc_status(),
        "users": len(get_users()),
        "port": get_listen_port(),
        "ip": server_ip(),
        "connection_count": len(get_connections()),
    }
    STATUS_CACHE["data"] = data
    STATUS_CACHE["ts"] = now
    return data

def get_logs_cached(n=30):
    now = time.time()
    cached = LOGS_CACHE["data"]
    if cached and (now - LOGS_CACHE["ts"]) < LOGS_CACHE_TTL:
        return cached
    data = get_logs(n)
    LOGS_CACHE["data"] = data
    LOGS_CACHE["ts"] = now
    return data

def new_session():
    tok = secrets.token_hex(32)
    sessions[tok] = time.time() + SESS_TTL
    return tok

def valid_session(tok):
    if tok and tok in sessions:
        if sessions[tok] > time.time():
            sessions[tok] = time.time() + SESS_TTL
            return True
        del sessions[tok]
    return False

def get_token(handler):
    for part in handler.headers.get("Cookie", "").split(";"):
        p = part.strip()
        if p.startswith("zivtoken="):
            return p[9:]
    return None

# ========== EMBEDDED HTML ==========
HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NOOBS ZIVPN Panel</title>
<style>
:root{
  --bg:#080d18;--bg2:#0e1525;--bg3:#141e30;
  --card:#111827;--border:#1f2d45;
  --cyan:#22d3ee;--green:#10b981;--red:#ef4444;
  --yellow:#f59e0b;--purple:#a78bfa;
  --text:#e2e8f0;--muted:#6b7280;--white:#f9fafb;
}
*{margin:0;padding:0;box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:'Courier New',monospace;min-height:100vh}
a{color:var(--cyan);text-decoration:none}

#login-screen{
  position:fixed;inset:0;background:var(--bg);
  display:flex;align-items:center;justify-content:center;z-index:999;
}
.login-box{
  background:var(--bg3);border:1px solid var(--border);
  border-radius:12px;padding:40px;width:360px;max-width:94vw;
}
.btn-cyan{background:var(--cyan);color:#000}
.btn-green{background:var(--green);color:#000}
.btn-red{background:var(--red);color:#fff}
.btn-yellow{background:var(--yellow);color:#000}
.btn-ghost{background:transparent;color:var(--muted);border:1px solid var(--border)}

#app{display:flex;min-height:100vh}
#sidebar{
  width:220px;background:var(--bg2);border-right:1px solid var(--border);
  display:flex;flex-direction:column;padding:20px 0;
}
.nav-item{
  display:flex;align-items:center;gap:10px;
  padding:10px 20px;cursor:pointer;color:var(--muted);
  font-size:.85rem;
}
.nav-item.active{color:var(--cyan);background:var(--bg3)}
#main{flex:1;padding:24px;overflow-y:auto}
.page{display:none}
.page.active{display:block}
.stats-grid{
  display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:14px;margin-bottom:24px
}
.stat-card{
  background:var(--card);border:1px solid var(--border);border-radius:10px;
  padding:18px;
}
.stat-label{color:var(--muted);font-size:.72rem}
.stat-value{font-size:1.4rem;font-weight:700}
.card{
  background:var(--card);border:1px solid var(--border);border-radius:10px;
  padding:20px;margin-bottom:18px;
}
.card-title{
  font-size:.85rem;font-weight:700;color:var(--cyan);margin-bottom:16px;
}
table{width:100%;border-collapse:collapse;font-size:.85rem}
th,td{padding:10px 12px;border-bottom:1px solid var(--border);text-align:left}
.badge-green{background:rgba(16,185,129,.15);color:var(--green)}
.badge-red{background:rgba(239,68,68,.15);color:var(--red)}
.input-row{display:flex;gap:10px;margin-bottom:14px;flex-wrap:wrap}
.input-row input,.input-row select{
  flex:1;background:var(--bg2);border:1px solid var(--border);
  color:var(--white);padding:10px;border-radius:8px;
}
#log-output{
  background:var(--bg);padding:16px;font-size:.75rem;line-height:1.7;
  max-height:500px;overflow-y:auto;white-space:pre-wrap;
}
.modal{
  display:none;position:fixed;top:0;left:0;width:100%;height:100%;
  background:rgba(0,0,0,0.8);justify-content:center;align-items:center;z-index:1000;
}
.modal-content{
  background:var(--bg3);border:1px solid var(--cyan);border-radius:12px;
  max-width:500px;width:90%;padding:20px;
}
@media(max-width:640px){
  #sidebar{width:100%;flex-direction:row;position:fixed;bottom:0;left:0;}
  .nav-item{flex-direction:column;gap:2px;padding:10px}
  #main{padding-bottom:80px}
}
</style>
</head>
<body>

<div id="login-screen">
  <div class="login-box">
    <div style="text-align:center;margin-bottom:20px">
      <div style="font-size:2rem;color:var(--cyan)">NOOBS</div>
      <div style="color:var(--muted)">ZIVPN UDP PANEL</div>
    </div>
    <input type="password" id="login-pw" placeholder="Panel password">
    <div id="login-err" style="color:var(--red);font-size:.8rem;margin-top:8px"></div>
    <button class="btn-cyan" style="width:100%;padding:12px;margin-top:14px" onclick="doLogin()">LOGIN</button>
  </div>
</div>

<div id="app" style="display:none">
  <div id="sidebar">
    <div class="nav-item active" onclick="show('dashboard')">📊 Dashboard</div>
    <div class="nav-item" onclick="show('users')">👥 Users</div>
    <div class="nav-item" onclick="show('service')">⚙️ Service</div>
    <div class="nav-item" onclick="show('logs')">📜 Logs</div>
    <div class="nav-item" onclick="doLogout()" style="margin-top:auto">🚪 Logout</div>
  </div>
  <div id="main">
    <!-- Dashboard -->
    <div class="page active" id="page-dashboard">
      <div class="card-title">📊 Dashboard</div>
      <div class="stats-grid" id="stats-grid">
        <div class="stat-card"><div class="stat-label">Service</div><div class="stat-value" id="s-svc">...</div></div>
        <div class="stat-card"><div class="stat-label">Server IP</div><div class="stat-value" id="s-ip">...</div></div>
        <div class="stat-card"><div class="stat-label">Port</div><div class="stat-value" id="s-port">...</div></div>
        <div class="stat-card"><div class="stat-label">Active Users</div><div class="stat-value" id="s-users">...</div></div>
        <div class="stat-card"><div class="stat-label">Connections</div><div class="stat-value" id="s-conns">...</div></div>
      </div>
      <div class="card">
        <div class="card-title">📡 Client Connection Info</div>
        <table><tr><td>Server IP</td><td id="ci-ip">...</td></tr>
        <tr><td>Port</td><td>Any 6000–19999</td></tr>
        <tr><td>Obfs</td><td>zivpn</td></tr></table>
      </div>
    </div>

    <!-- Users -->
    <div class="page" id="page-users">
      <div class="card-title">👥 User Management</div>
      <div class="card">
        <div class="card-title">➕ Add User</div>
        <div class="input-row">
          <input type="text" id="new-pw" placeholder="Password">
          <input type="number" id="dev-limit" placeholder="Device limit (0=unlimited)" value="0">
          <input type="number" id="data-gb" placeholder="Data limit GB (0=unlimited)" step="1" value="0">
          <input type="number" id="valid-days" placeholder="Validity days (0=unlimited)" value="0">
          <button class="btn-green" onclick="addUser()">Add</button>
        </div>
        <div class="card-title" style="justify-content:space-between">
          <span>📋 Active Users</span>
          <button class="btn-red" onclick="clearUsers()">Clear All</button>
        </div>
        <table id="users-table">
          <thead><tr><th>#</th><th>Password</th><th>Devices</th><th>Remaining GB</th><th>Expiry Days</th><th>Action</th></tr></thead>
          <tbody><tr><td colspan="6">Loading...</td></tr></tbody>
        </table>
      </div>
    </div>

    <!-- Service, Logs pages unchanged for brevity -->
    <div class="page" id="page-service">...</div>
    <div class="page" id="page-logs">...</div>
  </div>
</div>

<!-- Monitor Modal -->
<div id="monitorModal" class="modal">
  <div class="modal-content">
    <div style="display:flex;justify-content:space-between">
      <span class="card-title">🔍 User Monitor: <span id="monitor-user">-</span></span>
      <button onclick="closeModal()" style="background:none;color:var(--red);border:none;font-size:1.5rem">&times;</button>
    </div>
    <div><strong>Active devices:</strong> <span id="monitor-devices">0</span> / <span id="monitor-dev-limit">∞</span></div>
    <div><strong>Bandwidth remaining:</strong> <span id="monitor-remaining-gb">0</span> GB</div>
    <div><strong>Expiry:</strong> <span id="monitor-expiry-days">Never</span></div>
    <button class="btn-ghost" style="margin-top:16px" onclick="refreshMonitor()">⟳ Refresh</button>
  </div>
</div>

<script>
async function api(path, method='GET', body=null){
  const opts = {method, headers:{'Content-Type':'application/json'}};
  if(body) opts.body = JSON.stringify(body);
  const r = await fetch(path, opts);
  return r.json();
}
function toast(msg, type='ok'){ alert(msg); } // simplified

async function doLogin(){
  const pw = document.getElementById('login-pw').value;
  const r = await api('/api/login','POST',{password:pw});
  if(r.ok){
    document.getElementById('login-screen').style.display='none';
    document.getElementById('app').style.display='flex';
    loadStatus(); loadUsers();
  } else document.getElementById('login-err').innerText='Wrong password';
}

async function doLogout(){ await api('/api/logout','POST'); location.reload(); }

function show(page){
  document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n=>n.classList.remove('active'));
  document.getElementById('page-'+page).classList.add('active');
  event.currentTarget.classList.add('active');
  if(page==='dashboard') loadStatus();
  if(page==='users') loadUsers();
}

async function loadStatus(){
  const d = await api('/api/status');
  document.getElementById('s-svc').innerHTML = d.service === 'active' ? 'RUNNING' : 'STOPPED';
  document.getElementById('s-ip').innerText = d.ip;
  document.getElementById('s-port').innerText = d.port+'/udp';
  document.getElementById('s-users').innerText = d.users;
  document.getElementById('s-conns').innerText = d.connection_count;
  document.getElementById('ci-ip').innerText = d.ip;
}

async function loadUsers(){
  const d = await api('/api/users');
  if(!d.users) return;
  const tb = document.getElementById('users-table').querySelector('tbody');
  tb.innerHTML = d.users.map((u,i)=>`
    <tr>
      <td>${i+1}</td>
      <td style="cursor:pointer;color:var(--cyan)" onclick="showMonitor('${u.password}')">${u.password}</td>
      <td>${u.devices} / ${u.device_limit===0?'∞':u.device_limit}</td>
      <td>${u.remaining_bytes_gb} GB</td>
      <td>${u.remaining_days===-1?'Never':u.remaining_days}</td>
      <td><button class="btn-red" style="padding:5px 10px" onclick="removeUser('${u.password}')">Remove</button></td>
    </tr>
  `).join('');
}

let currentMonitorPw = '';
async function showMonitor(pw){
  currentMonitorPw = pw;
  document.getElementById('monitor-user').innerText = pw;
  await refreshMonitor();
  document.getElementById('monitorModal').style.display='flex';
}
async function refreshMonitor(){
  if(!currentMonitorPw) return;
  const st = await api(`/api/user/status/${currentMonitorPw}`);
  document.getElementById('monitor-devices').innerText = st.devices;
  document.getElementById('monitor-dev-limit').innerText = st.device_limit===0?'∞':st.device_limit;
  document.getElementById('monitor-remaining-gb').innerText = st.remaining_bytes_gb;
  document.getElementById('monitor-expiry-days').innerText = st.remaining_days===-1?'Never':st.remaining_days+' days';
}
function closeModal(){ document.getElementById('monitorModal').style.display='none'; }

async function addUser(){
  const pw = document.getElementById('new-pw').value.trim();
  if(!pw){ alert('Enter password'); return; }
  const dev = parseInt(document.getElementById('dev-limit').value) || 0;
  const data = parseFloat(document.getElementById('data-gb').value) || 0;
  const days = parseInt(document.getElementById('valid-days').value) || 0;
  const r = await api('/api/user/add','POST',{password:pw, device_limit:dev, data_limit_gb:data, validity_days:days});
  if(r.ok){ toast('User added'); loadUsers(); loadStatus(); }
  else alert('User exists or error');
}
async function removeUser(pw){
  if(!confirm(`Remove ${pw}?`)) return;
  await api('/api/user/remove','POST',{password:pw});
  loadUsers(); loadStatus();
}
async function clearUsers(){
  if(!confirm('Clear ALL users?')) return;
  await api('/api/user/clear','POST');
  loadUsers(); loadStatus();
}
setInterval(()=>{ if(document.getElementById('page-dashboard').classList.contains('active')) loadStatus(); }, 30000);
setInterval(()=>{ if(document.getElementById('page-users').classList.contains('active')) loadUsers(); }, 10000);

// Auto-login check
(async()=>{ const st = await api('/api/status'); if(!st.error){ document.getElementById('login-screen').style.display='none'; document.getElementById('app').style.display='flex'; loadStatus(); loadUsers(); } })();
</script>
</body>
</html>"""

# ========== HTTP HANDLER ==========
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send_json(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, text):
        body = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def auth_ok(self):
        return valid_session(get_token(self))

    def read_body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n)) if n > 0 else {}

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            self.send_html(HTML)
            return
        if not self.auth_ok():
            self.send_json({"error": "Unauthorized"}, 401)
            return
        if path == "/api/status":
            self.send_json(get_status_snapshot())
        elif path == "/api/users":
            users = get_users()
            enriched = []
            for u in users:
                status = get_user_status(u)
                enriched.append({"password": u, **status})
            self.send_json({"users": enriched})
        elif path == "/api/logs":
            self.send_json({"logs": get_logs_cached(30)})
        elif path.startswith("/api/user/status/"):
            pw = path.split("/")[-1]
            self.send_json(get_user_status(pw))
        else:
            self.send_json({"error": "Not found"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        body = self.read_body()
        if path == "/api/login":
            conf = load_panel_conf()
            if hash_pw(body.get("password", "")) == conf.get("pass_hash", ""):
                tok = new_session()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Set-Cookie", f"zivtoken={tok}; Path=/; HttpOnly; Max-Age=3600")
                self.end_headers()
                self.wfile.write(b'{"ok":true}')
            else:
                self.send_json({"ok": False, "error": "Wrong password"}, 401)
            return
        if path == "/api/logout":
            tok = get_token(self)
            if tok in sessions:
                del sessions[tok]
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Set-Cookie", "zivtoken=; Path=/; Max-Age=0")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        if not self.auth_ok():
            self.send_json({"error": "Unauthorized"}, 401)
            return
        if path == "/api/user/add":
            pw = body.get("password", "").strip()
            dev = int(body.get("device_limit", 0))
            data_gb = float(body.get("data_limit_gb", 0))
            days = int(body.get("validity_days", 0))
            if not pw:
                self.send_json({"ok": False, "error": "Empty password"})
                return
            ok = add_user(pw, dev, data_gb, days)
            if ok:
                svc_action("restart")
            self.send_json({"ok": ok})
        elif path == "/api/user/remove":
            pw = body.get("password", "").strip()
            ok = remove_user(pw)
            if ok:
                svc_action("restart")
            self.send_json({"ok": ok})
        elif path == "/api/user/clear":
            clear_users()
            svc_action("restart")
            self.send_json({"ok": True})
        elif path == "/api/service/start":
            ok = svc_action("start")
            self.send_json({"ok": ok, "status": svc_status()})
        elif path == "/api/service/stop":
            ok = svc_action("stop")
            self.send_json({"ok": ok, "status": svc_status()})
        elif path == "/api/service/restart":
            ok = svc_action("restart")
            self.send_json({"ok": ok, "status": svc_status()})
        else:
            self.send_json({"error": "Not found"}, 404)

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

def start_background_expiry_checker():
    def check():
        while True:
            time.sleep(3600)
            enforce_expiry()
    threading.Thread(target=check, daemon=True).start()

if __name__ == "__main__":
    conf = load_panel_conf()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else conf.get("port", 8080)
    ip = server_ip()
    start_background_expiry_checker()
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"NOOBS ZIVPN Web Panel (limits)  ►  http://{ip}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nWeb panel stopped.")
