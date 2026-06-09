#!/usr/bin/env python3
"""
NOOBS ZIVPN UDP Web Panel
Zero external dependencies — pure Python3 stdlib only
Default port : 8080
Config file  : /etc/zivpn/webpanel.conf
"""

import json, os, sys, subprocess, hashlib, secrets, time, socket, re
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

CONFIG_FILE = "/etc/zivpn/config.json"
PANEL_CONF  = "/etc/zivpn/webpanel.conf"
sessions    = {}   # token -> expiry_epoch
SESS_TTL    = 3600

# ══════════════════════════════════════════════════════════════
#  CONFIG HELPERS
# ══════════════════════════════════════════════════════════════

def load_panel_conf():
    try:
        with open(PANEL_CONF) as f:
            return json.load(f)
    except Exception:
        return {"port": 8080, "pass_hash": hashlib.sha256(b"admin").hexdigest()}

def save_panel_conf(c):
    with open(PANEL_CONF, "w") as f:
        json.dump(c, f, indent=2)

def hash_pw(pw):
    return hashlib.sha256(pw.encode()).hexdigest()

# ══════════════════════════════════════════════════════════════
#  ZIVPN CONFIG HELPERS
# ══════════════════════════════════════════════════════════════

def read_zivpn():
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except Exception:
        return {"listen": ":5667", "auth": {"mode": "passwords", "config": []}}

def write_zivpn(d):
    with open(CONFIG_FILE, "w") as f:
        json.dump(d, f, indent=2)

def get_users():
    return read_zivpn().get("auth", {}).get("config", [])

def add_user(pw):
    d = read_zivpn()
    d.setdefault("auth", {"mode": "passwords", "config": []})
    d["auth"].setdefault("config", [])
    if pw not in d["auth"]["config"]:
        d["auth"]["config"].append(pw)
        write_zivpn(d)
        return True
    return False

def remove_user(pw):
    d = read_zivpn()
    cfg = d.get("auth", {}).get("config", [])
    if pw in cfg:
        cfg.remove(pw)
        write_zivpn(d)
        return True
    return False

def clear_users():
    d = read_zivpn()
    d.setdefault("auth", {})["config"] = []
    write_zivpn(d)

def get_listen_port():
    return read_zivpn().get("listen", ":5667").lstrip(":")

# ══════════════════════════════════════════════════════════════
#  SYSTEM HELPERS
# ══════════════════════════════════════════════════════════════

def svc_status():
    r = subprocess.run(["systemctl", "is-active", "zivpn"],
                       capture_output=True, text=True)
    return r.stdout.strip()

def svc_action(action):
    r = subprocess.run(["systemctl", action, "zivpn"],
                       capture_output=True, text=True)
    return r.returncode == 0

def get_logs(n=60):
    r = subprocess.run(
        ["journalctl", "-u", "zivpn", f"-n{n}", "--no-pager",
         "--output=short-iso"],
        capture_output=True, text=True)
    return r.stdout

def server_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
        return "unknown"

def get_connections():
    port = get_listen_port()
    r = subprocess.run(["ss", "-anu"], capture_output=True, text=True)
    return [l for l in r.stdout.splitlines() if f":{port}" in l]

# ══════════════════════════════════════════════════════════════
#  SESSION HELPERS
# ══════════════════════════════════════════════════════════════

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

# ══════════════════════════════════════════════════════════════
#  EMBEDDED HTML  (single-page app)
# ══════════════════════════════════════════════════════════════

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

/* ── Login ── */
#login-screen{
  position:fixed;inset:0;background:var(--bg);
  display:flex;align-items:center;justify-content:center;z-index:999;
}
.login-box{
  background:var(--bg3);border:1px solid var(--border);
  border-radius:12px;padding:40px;width:360px;max-width:94vw;
  box-shadow:0 0 40px rgba(34,211,238,.08);
}
.login-logo{text-align:center;margin-bottom:28px}
.login-logo .big{font-size:2rem;font-weight:900;color:var(--cyan);letter-spacing:4px}
.login-logo .sub{color:var(--muted);font-size:.75rem;margin-top:4px;letter-spacing:2px}
.login-box input{
  width:100%;background:var(--bg2);border:1px solid var(--border);
  color:var(--white);padding:12px 14px;border-radius:8px;font-family:inherit;
  font-size:.9rem;outline:none;transition:.2s;
}
.login-box input:focus{border-color:var(--cyan);box-shadow:0 0 0 2px rgba(34,211,238,.1)}
.btn{
  display:inline-flex;align-items:center;gap:6px;
  padding:10px 18px;border-radius:8px;border:none;cursor:pointer;
  font-family:inherit;font-size:.85rem;font-weight:600;letter-spacing:.5px;
  transition:.18s;
}
.btn-cyan{background:var(--cyan);color:#000}
.btn-cyan:hover{background:#38e5ff}
.btn-green{background:var(--green);color:#000}
.btn-green:hover{background:#34d399}
.btn-red{background:var(--red);color:#fff}
.btn-red:hover{background:#f87171}
.btn-yellow{background:var(--yellow);color:#000}
.btn-yellow:hover{background:#fbbf24}
.btn-ghost{background:transparent;color:var(--muted);border:1px solid var(--border)}
.btn-ghost:hover{border-color:var(--cyan);color:var(--cyan)}
.btn-full{width:100%;justify-content:center;margin-top:14px;padding:13px}
.err-msg{color:var(--red);font-size:.8rem;margin-top:8px;min-height:18px;text-align:center}

/* ── Layout ── */
#app{display:flex;min-height:100vh}
#sidebar{
  width:220px;background:var(--bg2);border-right:1px solid var(--border);
  display:flex;flex-direction:column;padding:20px 0;flex-shrink:0;
}
.sidebar-brand{
  padding:0 20px 20px;border-bottom:1px solid var(--border);margin-bottom:12px;
}
.sidebar-brand .name{color:var(--cyan);font-weight:900;font-size:1rem;letter-spacing:2px}
.sidebar-brand .ver{color:var(--muted);font-size:.7rem;letter-spacing:1px}
.nav-item{
  display:flex;align-items:center;gap:10px;
  padding:10px 20px;cursor:pointer;color:var(--muted);
  font-size:.85rem;letter-spacing:.5px;transition:.15s;border-left:3px solid transparent;
}
.nav-item:hover{color:var(--text);background:var(--bg3)}
.nav-item.active{color:var(--cyan);border-left-color:var(--cyan);background:var(--bg3)}
.nav-item .icon{font-size:1rem;width:20px;text-align:center}
.sidebar-footer{margin-top:auto;padding:12px 20px;border-top:1px solid var(--border)}
#main{flex:1;overflow-y:auto;padding:24px;max-width:100%}
.page{display:none}
.page.active{display:block}

/* ── Cards ── */
.page-title{
  font-size:1.1rem;font-weight:700;color:var(--white);
  letter-spacing:1px;margin-bottom:20px;display:flex;align-items:center;gap:8px;
}
.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:14px;margin-bottom:24px}
.stat-card{
  background:var(--card);border:1px solid var(--border);border-radius:10px;
  padding:18px;display:flex;flex-direction:column;gap:6px;
}
.stat-label{color:var(--muted);font-size:.72rem;letter-spacing:1.5px;text-transform:uppercase}
.stat-value{font-size:1.4rem;font-weight:700;color:var(--white)}
.stat-value.green{color:var(--green)}
.stat-value.red{color:var(--red)}
.stat-value.cyan{color:var(--cyan)}
.stat-value.yellow{color:var(--yellow)}

/* ── Table ── */
.card{
  background:var(--card);border:1px solid var(--border);border-radius:10px;
  padding:20px;margin-bottom:18px;
}
.card-title{
  font-size:.85rem;font-weight:700;color:var(--cyan);letter-spacing:1px;
  margin-bottom:16px;text-transform:uppercase;display:flex;align-items:center;gap:8px;
}
table{width:100%;border-collapse:collapse;font-size:.85rem}
th{
  color:var(--muted);font-weight:600;text-align:left;
  padding:8px 12px;border-bottom:1px solid var(--border);font-size:.72rem;
  letter-spacing:1px;text-transform:uppercase;
}
td{padding:10px 12px;border-bottom:1px solid var(--border);color:var(--text)}
tr:last-child td{border-bottom:none}
tr:hover td{background:rgba(34,211,238,.03)}
.badge{
  display:inline-flex;align-items:center;gap:4px;
  padding:3px 10px;border-radius:20px;font-size:.72rem;font-weight:600;letter-spacing:.5px;
}
.badge-green{background:rgba(16,185,129,.15);color:var(--green)}
.badge-red{background:rgba(239,68,68,.15);color:var(--red)}

/* ── Form ── */
.input-row{display:flex;gap:10px;margin-bottom:14px;flex-wrap:wrap}
.input-row input,.input-row select{
  flex:1;min-width:160px;background:var(--bg2);border:1px solid var(--border);
  color:var(--white);padding:10px 14px;border-radius:8px;font-family:inherit;
  font-size:.85rem;outline:none;transition:.2s;
}
.input-row input:focus,.input-row select:focus{
  border-color:var(--cyan);box-shadow:0 0 0 2px rgba(34,211,238,.1)
}

/* ── Logs ── */
#log-output{
  background:var(--bg);border:1px solid var(--border);border-radius:8px;
  padding:16px;font-size:.75rem;line-height:1.7;color:#94a3b8;
  max-height:500px;overflow-y:auto;white-space:pre-wrap;word-break:break-all;
}
.log-error{color:var(--red)}
.log-conn{color:var(--green)}
.log-warn{color:var(--yellow)}

/* ── Service buttons ── */
.svc-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px}
.svc-btn{
  padding:18px;border-radius:10px;border:1px solid var(--border);
  background:var(--card);cursor:pointer;text-align:center;transition:.18s;
}
.svc-btn:hover{transform:translateY(-1px);box-shadow:0 4px 20px rgba(0,0,0,.3)}
.svc-btn .svc-icon{font-size:1.8rem;margin-bottom:8px}
.svc-btn .svc-name{font-size:.8rem;font-weight:600;letter-spacing:1px;color:var(--muted)}
.svc-btn.start:hover{border-color:var(--green);background:rgba(16,185,129,.08)}
.svc-btn.stop:hover{border-color:var(--red);background:rgba(239,68,68,.08)}
.svc-btn.restart:hover{border-color:var(--yellow);background:rgba(245,158,11,.08)}

/* ── Toast ── */
#toast{
  position:fixed;bottom:24px;right:24px;
  background:var(--bg3);border:1px solid var(--border);
  color:var(--text);padding:12px 20px;border-radius:8px;
  font-size:.85rem;opacity:0;pointer-events:none;
  transition:opacity .3s;z-index:9999;max-width:300px;
}
#toast.show{opacity:1}
#toast.ok{border-color:var(--green);color:var(--green)}
#toast.err{border-color:var(--red);color:var(--red)}

/* ── Mobile ── */
@media(max-width:640px){
  #sidebar{
    width:100%;flex-direction:row;padding:0;
    position:fixed;bottom:0;left:0;z-index:100;
    border-right:none;border-top:1px solid var(--border);
    overflow-x:auto;
  }
  .sidebar-brand{display:none}
  .sidebar-footer{display:none}
  .nav-item{
    flex-direction:column;gap:2px;padding:10px 14px;
    font-size:.65rem;border-left:none;border-top:3px solid transparent;min-width:60px;
  }
  .nav-item.active{border-top-color:var(--cyan);border-left-color:transparent}
  .nav-item .icon{font-size:1.2rem}
  #main{padding:16px;padding-bottom:80px}
}
.spinner{
  display:inline-block;width:14px;height:14px;
  border:2px solid var(--muted);border-top-color:var(--cyan);
  border-radius:50%;animation:spin .6s linear infinite;
}
@keyframes spin{to{transform:rotate(360deg)}}
</style>
</head>
<body>

<!-- ── Login ─────────────────────────────────────────── -->
<div id="login-screen">
  <div class="login-box">
    <div class="login-logo">
      <div class="big">NOOBS</div>
      <div class="sub">ZIVPN UDP PANEL</div>
      <div style="color:var(--muted);font-size:.7rem;margin-top:6px">github.com/autobot-sys/ZIV-WEB</div>
    </div>
    <input type="password" id="login-pw" placeholder="Enter panel password" autocomplete="off">
    <div class="err-msg" id="login-err"></div>
    <button class="btn btn-cyan btn-full" onclick="doLogin()">&#9658; LOGIN</button>
  </div>
</div>

<!-- ── App ───────────────────────────────────────────── -->
<div id="app" style="display:none">
  <div id="sidebar">
    <div class="sidebar-brand">
      <div class="name">&#9670; NOOBS</div>
      <div class="ver">ZIVPN UDP PANEL</div>
    </div>
    <div class="nav-item active" onclick="show('dashboard')">
      <span class="icon">&#9636;</span><span>Dashboard</span>
    </div>
    <div class="nav-item" onclick="show('users')">
      <span class="icon">&#9633;</span><span>Users</span>
    </div>
    <div class="nav-item" onclick="show('service')">
      <span class="icon">&#9651;</span><span>Service</span>
    </div>
    <div class="nav-item" onclick="show('logs')">
      <span class="icon">&#9643;</span><span>Logs</span>
    </div>
    <div class="sidebar-footer">
      <div class="nav-item" onclick="doLogout()" style="padding:8px 0;border-left:none">
        <span class="icon">&#10006;</span><span>Logout</span>
      </div>
    </div>
  </div>

  <div id="main">

    <!-- Dashboard -->
    <div class="page active" id="page-dashboard">
      <div class="page-title">&#9636; Dashboard</div>
      <div class="stats-grid" id="stats-grid">
        <div class="stat-card"><div class="stat-label">Service</div><div class="stat-value" id="s-svc">...</div></div>
        <div class="stat-card"><div class="stat-label">Server IP</div><div class="stat-value cyan" id="s-ip">...</div></div>
        <div class="stat-card"><div class="stat-label">Port</div><div class="stat-value yellow" id="s-port">...</div></div>
        <div class="stat-card"><div class="stat-label">Active Users</div><div class="stat-value cyan" id="s-users">...</div></div>
        <div class="stat-card"><div class="stat-label">Connections</div><div class="stat-value cyan" id="s-conns">...</div></div>
      </div>
      <div class="card">
        <div class="card-title">&#9670; Client Connection Info</div>
        <table>
          <tr><td style="color:var(--muted);width:140px">Server IP</td><td id="ci-ip" style="color:var(--cyan)">...</td></tr>
          <tr><td style="color:var(--muted)">Port</td><td>Any port <span style="color:var(--yellow)">6000 – 19999</span></td></tr>
          <tr><td style="color:var(--muted)">Password</td><td>One of your added users</td></tr>
          <tr><td style="color:var(--muted)">Obfs</td><td style="color:var(--green)">zivpn</td></tr>
        </table>
      </div>
    </div>

    <!-- Users -->
    <div class="page" id="page-users">
      <div class="page-title">&#9633; User Management</div>
      <div class="card">
        <div class="card-title">&#43; Add New User</div>
        <div class="input-row">
          <input type="text" id="new-pw" placeholder="Password for new user" autocomplete="off">
          <button class="btn btn-green" onclick="addUser()">Add User</button>
        </div>
        <div style="color:var(--muted);font-size:.78rem">
          Bulk add: enter multiple passwords separated by commas
        </div>
        <div class="input-row" style="margin-top:10px">
          <input type="text" id="bulk-pw" placeholder="user1,user2,user3" autocomplete="off">
          <button class="btn btn-cyan" onclick="bulkAdd()">Bulk Add</button>
        </div>
      </div>
      <div class="card">
        <div class="card-title" style="justify-content:space-between">
          <span>&#9633; Active Users</span>
          <button class="btn btn-red" style="padding:6px 14px;font-size:.75rem" onclick="clearUsers()">Clear All</button>
        </div>
        <table>
          <thead><tr><th>#</th><th>Password</th><th>Action</th></tr></thead>
          <tbody id="users-table"><tr><td colspan="3" style="color:var(--muted);text-align:center;padding:20px">Loading...</td></tr></tbody>
        </table>
      </div>
    </div>

    <!-- Service -->
    <div class="page" id="page-service">
      <div class="page-title">&#9651; Service Control</div>
      <div class="card" style="margin-bottom:18px">
        <div class="card-title">&#9670; Status</div>
        <div style="display:flex;align-items:center;gap:12px;font-size:1rem">
          <span style="color:var(--muted)">ZIVPN Service:</span>
          <span id="svc-badge" class="badge badge-green">loading...</span>
        </div>
      </div>
      <div class="card">
        <div class="card-title">&#9670; Actions</div>
        <div class="svc-grid">
          <div class="svc-btn start" onclick="svcAction('start')">
            <div class="svc-icon" style="color:var(--green)">&#9654;</div>
            <div class="svc-name">START</div>
          </div>
          <div class="svc-btn stop" onclick="svcAction('stop')">
            <div class="svc-icon" style="color:var(--red)">&#9646;</div>
            <div class="svc-name">STOP</div>
          </div>
          <div class="svc-btn restart" onclick="svcAction('restart')">
            <div class="svc-icon" style="color:var(--yellow)">&#8635;</div>
            <div class="svc-name">RESTART</div>
          </div>
        </div>
      </div>
    </div>

    <!-- Logs -->
    <div class="page" id="page-logs">
      <div class="page-title">&#9643; Service Logs
        <button class="btn btn-ghost" style="padding:5px 12px;font-size:.75rem;margin-left:auto" onclick="loadLogs()">&#8635; Refresh</button>
      </div>
      <div class="card">
        <div id="log-output">Loading logs...</div>
      </div>
    </div>

  </div><!-- /main -->
</div><!-- /app -->

<div id="toast"></div>

<script>
// ── Helpers ──────────────────────────────────────────────────
async function api(path, method='GET', body=null){
  const opts = { method, headers:{'Content-Type':'application/json'} };
  if(body) opts.body = JSON.stringify(body);
  const r = await fetch(path, opts);
  return r.json();
}

function toast(msg, type='ok'){
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = `show ${type}`;
  clearTimeout(t._t);
  t._t = setTimeout(()=>t.className='', 2800);
}

function show(page){
  document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n=>n.classList.remove('active'));
  document.getElementById('page-'+page).classList.add('active');
  event.currentTarget.classList.add('active');
  if(page==='dashboard') loadStatus();
  if(page==='users') loadUsers();
  if(page==='service') loadSvcStatus();
  if(page==='logs') loadLogs();
}

// ── Auth ─────────────────────────────────────────────────────
async function doLogin(){
  const pw = document.getElementById('login-pw').value;
  document.getElementById('login-err').textContent = '';
  if(!pw){ document.getElementById('login-err').textContent='Enter password'; return; }
  const r = await api('/api/login','POST',{password:pw});
  if(r.ok){
    document.getElementById('login-screen').style.display='none';
    document.getElementById('app').style.display='flex';
    loadStatus();
  } else {
    document.getElementById('login-err').textContent = r.error || 'Wrong password';
  }
}

async function doLogout(){
  await api('/api/logout','POST');
  location.reload();
}

document.getElementById('login-pw').addEventListener('keydown', e=>{
  if(e.key==='Enter') doLogin();
});

// ── Dashboard ────────────────────────────────────────────────
async function loadStatus(){
  const d = await api('/api/status');
  if(d.error){ location.reload(); return; }
  const running = d.service === 'active';
  const el = document.getElementById('s-svc');
  el.textContent = running ? 'RUNNING' : 'STOPPED';
  el.className = 'stat-value ' + (running ? 'green' : 'red');
  document.getElementById('s-ip').textContent    = d.ip || '—';
  document.getElementById('s-port').textContent  = d.port + '/udp';
  document.getElementById('s-users').textContent = d.users;
  document.getElementById('s-conns').textContent = d.connections.length;
  document.getElementById('ci-ip').textContent   = d.ip || '—';
  const badge = document.getElementById('svc-badge');
  if(badge){
    badge.textContent  = running ? 'RUNNING' : 'STOPPED';
    badge.className    = 'badge ' + (running ? 'badge-green' : 'badge-red');
  }
}

// ── Users ─────────────────────────────────────────────────────
async function loadUsers(){
  const d = await api('/api/users');
  if(d.error){ location.reload(); return; }
  const tb = document.getElementById('users-table');
  if(!d.users.length){
    tb.innerHTML = '<tr><td colspan="3" style="color:var(--muted);text-align:center;padding:20px">No users configured</td></tr>';
    return;
  }
  tb.innerHTML = d.users.map((u,i)=>`
    <tr>
      <td style="color:var(--muted)">${i+1}</td>
      <td><span style="color:var(--white);font-weight:600">${escHtml(u)}</span></td>
      <td><button class="btn btn-red" style="padding:5px 12px;font-size:.75rem"
          onclick="removeUser('${escHtml(u)}')">Remove</button></td>
    </tr>`).join('');
}

function escHtml(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/'/g,'&#39;'); }

async function addUser(){
  const pw = document.getElementById('new-pw').value.trim();
  if(!pw){ toast('Enter a password','err'); return; }
  const r = await api('/api/user/add','POST',{password:pw});
  if(r.ok){ toast('User added'); document.getElementById('new-pw').value=''; loadUsers(); loadStatus(); }
  else toast(r.error||'Already exists','err');
}

async function bulkAdd(){
  const val = document.getElementById('bulk-pw').value.trim();
  if(!val){ toast('Enter passwords','err'); return; }
  const pws = val.split(',').map(s=>s.trim()).filter(Boolean);
  let added=0;
  for(const pw of pws){
    const r = await api('/api/user/add','POST',{password:pw});
    if(r.ok) added++;
  }
  toast(`${added} user(s) added`);
  document.getElementById('bulk-pw').value='';
  loadUsers(); loadStatus();
}

async function removeUser(pw){
  if(!confirm(`Remove user: ${pw}?`)) return;
  const r = await api('/api/user/remove','POST',{password:pw});
  r.ok ? (toast('User removed'), loadUsers(), loadStatus()) : toast('Failed','err');
}

async function clearUsers(){
  if(!confirm('Clear ALL users? This will disconnect all clients.')) return;
  await api('/api/user/clear','POST');
  toast('All users cleared');
  loadUsers(); loadStatus();
}

// ── Service ───────────────────────────────────────────────────
async function loadSvcStatus(){
  const d = await api('/api/status');
  if(d.error) return;
  const running = d.service === 'active';
  const badge = document.getElementById('svc-badge');
  if(badge){
    badge.textContent = running ? 'RUNNING' : 'STOPPED';
    badge.className   = 'badge ' + (running ? 'badge-green' : 'badge-red');
  }
}

async function svcAction(action){
  const r = await api(`/api/service/${action}`,'POST');
  const ok = r.ok;
  toast(ok ? `Service ${action}ed` : `Failed to ${action}`+(r.error?': '+r.error:''), ok?'ok':'err');
  loadSvcStatus(); loadStatus();
}

// ── Logs ──────────────────────────────────────────────────────
async function loadLogs(){
  const el = document.getElementById('log-output');
  el.textContent = 'Loading...';
  const d = await api('/api/logs');
  if(d.error){ location.reload(); return; }
  const lines = (d.logs||'No logs available').split('\n');
  el.innerHTML = lines.map(line=>{
    if(/error|fail|crit/i.test(line)) return `<span class="log-error">${escHtml(line)}</span>`;
    if(/connect|auth|accept/i.test(line)) return `<span class="log-conn">${escHtml(line)}</span>`;
    if(/warn/i.test(line)) return `<span class="log-warn">${escHtml(line)}</span>`;
    return escHtml(line);
  }).join('\n');
  el.scrollTop = el.scrollHeight;
}

// ── Init ─────────────────────────────────────────────────────
(async()=>{
  const r = await api('/api/status');
  if(!r.error){
    document.getElementById('login-screen').style.display='none';
    document.getElementById('app').style.display='flex';
    loadStatus();
  }
})();

// Auto-refresh dashboard every 15s
setInterval(()=>{
  if(document.getElementById('page-dashboard').classList.contains('active')) loadStatus();
}, 15000);
</script>
</body>
</html>"""

# ══════════════════════════════════════════════════════════════
#  HTTP HANDLER
# ══════════════════════════════════════════════════════════════

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass   # silence default access log

    def send_json(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type",   "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, text):
        body = text.encode()
        self.send_response(200)
        self.send_header("Content-Type",   "text/html; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def auth_ok(self):
        return valid_session(get_token(self))

    def read_body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n)) if n > 0 else {}

    # ── GET ──────────────────────────────────────────────────
    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/":
            self.send_html(HTML)
            return

        if not self.auth_ok():
            self.send_json({"error": "Unauthorized"}, 401)
            return

        if path == "/api/status":
            status = svc_status()
            self.send_json({
                "service":     status,
                "users":       len(get_users()),
                "port":        get_listen_port(),
                "ip":          server_ip(),
                "connections": get_connections(),
            })
        elif path == "/api/users":
            self.send_json({"users": get_users()})
        elif path == "/api/logs":
            self.send_json({"logs": get_logs(80)})
        else:
            self.send_json({"error": "Not found"}, 404)

    # ── POST ─────────────────────────────────────────────────
    def do_POST(self):
        path = urlparse(self.path).path
        body = self.read_body()

        # ─ Login (no auth required) ─
        if path == "/api/login":
            conf = load_panel_conf()
            if hash_pw(body.get("password", "")) == conf.get("pass_hash", ""):
                tok     = new_session()
                payload = json.dumps({"ok": True}).encode()
                self.send_response(200)
                self.send_header("Content-Type",   "application/json")
                self.send_header("Set-Cookie",
                    f"zivtoken={tok}; Path=/; HttpOnly; Max-Age=3600")
                self.send_header("Content-Length", len(payload))
                self.end_headers()
                self.wfile.write(payload)
            else:
                self.send_json({"ok": False, "error": "Wrong password"}, 401)
            return

        # ─ Logout ─
        if path == "/api/logout":
            tok = get_token(self)
            if tok and tok in sessions:
                del sessions[tok]
            payload = json.dumps({"ok": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type",   "application/json")
            self.send_header("Set-Cookie",     "zivtoken=; Path=/; Max-Age=0")
            self.send_header("Content-Length", len(payload))
            self.end_headers()
            self.wfile.write(payload)
            return

        # ─ All other endpoints require auth ─
        if not self.auth_ok():
            self.send_json({"error": "Unauthorized"}, 401)
            return

        if path == "/api/user/add":
            pw = body.get("password", "").strip()
            if not pw:
                self.send_json({"ok": False, "error": "Empty password"})
            else:
                ok = add_user(pw)
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


# ══════════════════════════════════════════════════════════════
#  ENTRY POINT
# ══════════════════════════════════════════════════════════════
if __name__ == "__main__":
    conf = load_panel_conf()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else conf.get("port", 8080)
    ip   = server_ip()

    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"NOOBS ZIVPN Web Panel  ►  http://{ip}:{port}")
    print(f"Default password: admin  (change via zivudp → [w])")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nWeb panel stopped.")
