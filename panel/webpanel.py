#!/usr/bin/env python3
"""
NOOBS ZIVPN UDP Web Panel — Professional UI, Mobile Ready & Optimized
Zero external dependencies — pure Python3 stdlib only
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

_ip_cache = {"ip": None, "ts": 0}
_device_cache = {"ts": 0, "data": {}}

# ========== DEVICE TRACKING (CACHED) ==========
def get_connected_devices(force_refresh=False):
    """Return dict: password -> list of source IPs currently connected."""
    global _device_cache
    now = time.time()
    if not force_refresh and (now - _device_cache["ts"]) < 5:
        return _device_cache["data"]

    ip_to_pw = {}
    try:
        # Try journalctl first
        cmd = ["journalctl", "-u", "zivpn", "-n", "2000", "--no-pager"]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=3).stdout
    except:
        out = ""
    if not out:
        try:
            with open("/var/log/syslog", "r") as f:
                out = f.read()
        except:
            out = ""

    patterns = [
        re.compile(r'(?:authenticated|auth).*password[:=](\S+).*from (\d+\.\d+\.\d+\.\d+)', re.IGNORECASE),
        re.compile(r'password[:=](\S+).*from (\d+\.\d+\.\d+\.\d+)', re.IGNORECASE),
        re.compile(r'auth.*for (\S+) from (\d+\.\d+\.\d+\.\d+)', re.IGNORECASE),
    ]
    for line in out.splitlines():
        for pat in patterns:
            m = pat.search(line)
            if m:
                groups = m.groups()
                if len(groups) == 2:
                    if re.match(r'^\d+\.\d+\.\d+\.\d+$', groups[0]):
                        ip, pw = groups[0], groups[1]
                    else:
                        pw, ip = groups[0], groups[1]
                    ip_to_pw[ip] = pw
                break

    # Get active UDP connections on the main port
    port = get_listen_port()
    active_ips = []
    try:
        r = subprocess.run(["ss", "-Hanu"], capture_output=True, text=True, timeout=2)
        for line in r.stdout.splitlines():
            if f":{port}" in line:
                parts = line.split()
                if len(parts) >= 6:
                    peer = parts[5]
                    if ":" in peer:
                        ip = peer.rsplit(":", 1)[0].strip("[]")
                        if ip in ip_to_pw:
                            active_ips.append(ip)
    except:
        pass

    result = {}
    for ip in set(active_ips):
        pw = ip_to_pw.get(ip)
        if pw:
            result.setdefault(pw, []).append(ip)

    _device_cache["data"] = result
    _device_cache["ts"] = now
    return result

# ========== IPTABLES HELPERS ==========
def chain_exists(chain):
    try:
        out = subprocess.run(["iptables", "-L", chain], capture_output=True, text=True, timeout=2)
        return out.returncode == 0
    except:
        return False

def setup_iptables_quota(pw, limit_gb):
    """Create the quota chain with quota and DROP rules."""
    chain = f"ZIV_USER_{pw}"
    limit_bytes = int(limit_gb * 1024**3)
    # Delete existing chain if any
    subprocess.run(["iptables", "-F", chain], stderr=subprocess.DEVNULL)
    subprocess.run(["iptables", "-X", chain], stderr=subprocess.DEVNULL)
    # Create new chain
    subprocess.run(["iptables", "-N", chain], stderr=subprocess.DEVNULL)
    subprocess.run(["iptables", "-A", chain, "-m", "quota", "--quota", str(limit_bytes), "-j", "RETURN"], stderr=subprocess.DEVNULL)
    subprocess.run(["iptables", "-A", chain, "-j", "DROP"], stderr=subprocess.DEVNULL)

def delete_iptables_chain(pw):
    chain = f"ZIV_USER_{pw}"
    # Remove all INPUT rules jumping to this chain
    try:
        out = subprocess.run(["iptables", "-L", "INPUT", "--line-numbers", "-n"], capture_output=True, text=True, timeout=2).stdout
        for line in reversed(out.splitlines()):
            if chain in line:
                num = line.split()[0]
                if num.isdigit():
                    subprocess.run(["iptables", "-D", "INPUT", num], stderr=subprocess.DEVNULL)
    except:
        pass
    subprocess.run(["iptables", "-F", chain], stderr=subprocess.DEVNULL)
    subprocess.run(["iptables", "-X", chain], stderr=subprocess.DEVNULL)

def get_iptables_quota_left(pw):
    """Return bytes left for this user's quota chain, or None if not found."""
    chain = f"ZIV_USER_{pw}"
    try:
        out = subprocess.run(["iptables", "-L", chain, "-v", "-n", "-x"], capture_output=True, text=True, timeout=2).stdout
        for line in out.splitlines():
            if "quota" in line:
                parts = line.split()
                for i, p in enumerate(parts):
                    if p == "quota" and i+1 < len(parts):
                        return int(parts[i+1])
    except:
        pass
    return None

def ensure_iptables_quota_for_user(pw):
    """
    Ensure the quota chain exists and is attached to INPUT for all active IPs of this user.
    Attach to ALL UDP traffic (any port) from those IPs.
    """
    meta = load_meta()
    data = meta.get(pw, {})
    data_limit = data.get("data_limit_bytes", 0)
    if data_limit == 0:
        return  # no quota needed

    chain = f"ZIV_USER_{pw}"
    if not chain_exists(chain):
        # Recreate the chain with the correct limit
        setup_iptables_quota(pw, data_limit / 1024**3)
    else:
        # Ensure the quota rule has the correct limit (in case it was changed)
        # For simplicity, we could just recreate, but that would reset the counter.
        # We'll keep it as is, but if the limit changed, we need to adjust.
        # That's a corner case; we'll assume limits don't change after creation.
        pass

    # Get active IPs for this user (force refresh)
    devices = get_connected_devices(force_refresh=True)
    ips = devices.get(pw, [])

    # Remove any existing INPUT rules that jump to this chain (to avoid duplicates)
    try:
        out = subprocess.run(["iptables", "-L", "INPUT", "--line-numbers", "-n"], capture_output=True, text=True, timeout=2).stdout
        for line in reversed(out.splitlines()):
            if chain in line:
                num = line.split()[0]
                if num.isdigit():
                    subprocess.run(["iptables", "-D", "INPUT", num], stderr=subprocess.DEVNULL)
    except:
        pass

    # Add new rule for each IP: allow all UDP from this IP to pass through the chain
    for ip in ips:
        subprocess.run(["iptables", "-I", "INPUT", "-s", ip, "-p", "udp", "-j", chain], stderr=subprocess.DEVNULL)

def periodic_chain_attacher():
    """Background thread to periodically re-attach chains for all limited users."""
    while True:
        time.sleep(30)
        meta = load_meta()
        for pw, data in meta.items():
            if data.get("data_limit_bytes", 0) > 0:
                try:
                    ensure_iptables_quota_for_user(pw)
                except:
                    pass

# ========== METADATA HELPERS ==========
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
        expiry = get_future_timestamp(validity_days)
    meta[pw] = {
        "device_limit": device_limit,
        "data_limit_bytes": data_limit_gb * 1024**3 if data_limit_gb > 0 else 0,
        "data_used_bytes": 0,
        "expiry": expiry,
        "created_at": time.time()
    }
    save_meta(meta)
    if data_limit_gb > 0:
        setup_iptables_quota(pw, data_limit_gb)

def get_user_status(pw):
    """Return device count, remaining GB, and expiry days."""
    # Ensure quota is attached for active IPs
    ensure_iptables_quota_for_user(pw)

    meta = load_meta()
    data = meta.get(pw, {})
    device_limit = data.get("device_limit", 0)
    data_limit = data.get("data_limit_bytes", 0)
    expiry_ts = data.get("expiry", None)
    remaining_days = -1
    if expiry_ts:
        remaining_days = max(0, int((expiry_ts - time.time()) / 86400))

    # Calculate used bytes from iptables if possible
    used_bytes = data.get("data_used_bytes", 0)
    if data_limit > 0:
        quota_left = get_iptables_quota_left(pw)
        if quota_left is not None:
            used_bytes = data_limit - quota_left
            if used_bytes > data.get("data_used_bytes", 0):
                data["data_used_bytes"] = used_bytes
                save_meta(meta)
        else:
            # Chain missing – recreate it
            setup_iptables_quota(pw, data_limit / 1024**3)
            used_bytes = 0

    remaining_bytes = data_limit - used_bytes if data_limit > 0 else 0
    remaining_gb = round(remaining_bytes / (1024**3), 2) if remaining_bytes > 0 else 0

    devices = get_connected_devices()
    device_ips = devices.get(pw, [])
    device_count = len(device_ips)

    return {
        "devices": device_count,
        "device_limit": device_limit,
        "remaining_bytes_gb": remaining_gb,
        "remaining_days": remaining_days,
        "expired": expiry_ts is not None and expiry_ts < time.time()
    }

def get_future_timestamp(days):
    try:
        url = "https://timeapi.io/api/Time/current/zone?timeZone=UTC"
        with urllib.request.urlopen(url, timeout=3) as resp:
            data = json.loads(resp.read().decode())
            now_epoch = data.get("epochTime", time.time())
        return now_epoch + days * 86400
    except:
        return time.time() + days * 86400

def enforce_expiry():
    changed = False
    meta = load_meta()
    for pw, data in list(meta.items()):
        if data.get("expiry") and data["expiry"] < time.time():
            remove_user(pw)
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
    global _ip_cache
    now = time.time()
    if _ip_cache["ip"] and (now - _ip_cache["ts"]) < 60:
        return _ip_cache["ip"]

    try:
        r = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=2)
        ips = (r.stdout or "").split()
        for ip in ips:
            if ip and not ip.startswith("127."):
                _ip_cache["ip"] = ip
                _ip_cache["ts"] = now
                return ip
    except:
        pass

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(1.0)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            _ip_cache["ip"] = ip
            _ip_cache["ts"] = now
            return ip
    except:
        _ip_cache["ip"] = "unknown"
        _ip_cache["ts"] = now
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

# ========== HTML (unchanged from previous mobile-ready version) ==========
HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes, viewport-fit=cover">
  <title>NOOBS ZIVPN | Control Panel</title>
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    body {
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
      background: #f1f5f9;
      color: #0f172a;
      line-height: 1.5;
    }
    .login-container {
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
      padding: 1.5rem;
    }
    .login-card {
      background: white;
      border-radius: 1.5rem;
      padding: 2rem;
      width: 100%;
      max-width: 420px;
      box-shadow: 0 20px 35px -10px rgba(0,0,0,0.3);
    }
    .login-logo {
      text-align: center;
      margin-bottom: 2rem;
    }
    .login-logo h1 {
      font-size: 1.75rem;
      font-weight: 700;
      background: linear-gradient(135deg, #2c7da0, #2a9d8f);
      -webkit-background-clip: text;
      background-clip: text;
      color: transparent;
      letter-spacing: -0.5px;
    }
    .login-logo p {
      color: #64748b;
      font-size: 0.75rem;
      margin-top: 0.25rem;
    }
    .login-card input {
      width: 100%;
      padding: 0.75rem 1rem;
      border: 1px solid #cbd5e1;
      border-radius: 0.75rem;
      font-size: 1rem;
      transition: all 0.2s;
    }
    .login-card input:focus {
      outline: none;
      border-color: #2c7da0;
      box-shadow: 0 0 0 3px rgba(44,125,160,0.2);
    }
    .login-btn {
      width: 100%;
      padding: 0.75rem;
      background: #2c7da0;
      color: white;
      border: none;
      border-radius: 0.75rem;
      font-weight: 600;
      font-size: 1rem;
      cursor: pointer;
      transition: background 0.2s;
      margin-top: 1rem;
    }
    .login-btn:hover { background: #1f5e7a; }
    .error-msg { color: #e11d48; font-size: 0.875rem; margin-top: 0.5rem; text-align: center; }

    .app {
      display: flex;
      min-height: 100vh;
    }
    .sidebar {
      width: 280px;
      background: white;
      border-right: 1px solid #e2e8f0;
      display: flex;
      flex-direction: column;
      position: fixed;
      top: 0;
      bottom: 0;
      left: 0;
      z-index: 40;
      transition: transform 0.2s ease;
    }
    .sidebar-header {
      padding: 1.5rem;
      border-bottom: 1px solid #e2e8f0;
    }
    .sidebar-header h2 {
      font-size: 1.25rem;
      font-weight: 700;
      background: linear-gradient(135deg, #2c7da0, #2a9d8f);
      -webkit-background-clip: text;
      background-clip: text;
      color: transparent;
    }
    .sidebar-header p {
      font-size: 0.7rem;
      color: #64748b;
      margin-top: 4px;
    }
    .nav-item {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      padding: 0.75rem 1.5rem;
      margin: 0.25rem 0.75rem;
      border-radius: 0.75rem;
      cursor: pointer;
      color: #475569;
      transition: all 0.2s;
    }
    .nav-item i { width: 1.5rem; font-style: normal; font-weight: 500; }
    .nav-item:hover { background: #f1f5f9; color: #0f172a; }
    .nav-item.active {
      background: #eef2ff;
      color: #2c7da0;
      font-weight: 500;
    }
    .sidebar-footer {
      margin-top: auto;
      padding: 1rem 1.5rem;
      border-top: 1px solid #e2e8f0;
    }
    .main-content {
      flex: 1;
      margin-left: 280px;
      padding: 1.5rem;
      transition: margin-left 0.2s;
    }
    .stats-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 1rem;
      margin-bottom: 2rem;
    }
    .stat-card {
      background: white;
      border-radius: 1rem;
      padding: 1rem;
      box-shadow: 0 1px 3px rgba(0,0,0,0.05);
      border: 1px solid #e2e8f0;
    }
    .stat-title {
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: #64748b;
      margin-bottom: 0.5rem;
    }
    .stat-value {
      font-size: 1.5rem;
      font-weight: 700;
      color: #0f172a;
    }
    .stat-value.green { color: #10b981; }
    .stat-value.red { color: #ef4444; }
    .stat-value.cyan { color: #2c7da0; }
    .stat-value.yellow { color: #eab308; }

    .card {
      background: white;
      border-radius: 1rem;
      border: 1px solid #e2e8f0;
      margin-bottom: 1.5rem;
      overflow: hidden;
    }
    .card-header {
      padding: 0.75rem 1rem;
      border-bottom: 1px solid #e2e8f0;
      background: #fafcff;
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 0.5rem;
    }
    .card-title {
      font-weight: 600;
      font-size: 0.9rem;
      color: #0f172a;
    }
    .card-body {
      padding: 1rem;
    }
    .form-row {
      display: flex;
      flex-wrap: wrap;
      gap: 0.75rem;
      margin-bottom: 1rem;
    }
    .form-group {
      flex: 1;
      min-width: 140px;
    }
    .form-group label {
      display: block;
      font-size: 0.7rem;
      font-weight: 500;
      color: #475569;
      margin-bottom: 0.25rem;
    }
    .form-control {
      width: 100%;
      padding: 0.5rem 0.75rem;
      border: 1px solid #cbd5e1;
      border-radius: 0.5rem;
      font-size: 0.875rem;
    }
    .form-control:focus {
      outline: none;
      border-color: #2c7da0;
      box-shadow: 0 0 0 2px rgba(44,125,160,0.2);
    }
    .btn {
      padding: 0.5rem 1rem;
      border-radius: 0.5rem;
      font-weight: 500;
      font-size: 0.875rem;
      cursor: pointer;
      transition: all 0.2s;
      border: none;
      background: #f1f5f9;
      color: #1e293b;
    }
    .btn-primary { background: #2c7da0; color: white; }
    .btn-primary:hover { background: #1f5e7a; }
    .btn-success { background: #10b981; color: white; }
    .btn-success:hover { background: #0e9f6e; }
    .btn-danger { background: #ef4444; color: white; }
    .btn-danger:hover { background: #dc2626; }
    .btn-warning { background: #eab308; color: #1e293b; }
    .btn-warning:hover { background: #ca8a04; }
    .btn-sm { padding: 0.25rem 0.75rem; font-size: 0.75rem; }

    .table-responsive {
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.8rem;
      min-width: 500px;
    }
    th {
      text-align: left;
      padding: 0.6rem 0.75rem;
      background: #f8fafc;
      border-bottom: 1px solid #e2e8f0;
      color: #475569;
      font-weight: 600;
    }
    td {
      padding: 0.6rem 0.75rem;
      border-bottom: 1px solid #f1f5f9;
    }
    tr:hover td { background: #fafcff; }
    .clickable-row { cursor: pointer; }
    .clickable-row:hover { background: #f1f5f9; }

    .modal {
      display: none;
      position: fixed;
      inset: 0;
      background: rgba(0,0,0,0.5);
      align-items: center;
      justify-content: center;
      z-index: 1000;
      padding: 1rem;
    }
    .modal-content {
      background: white;
      border-radius: 1rem;
      max-width: 450px;
      width: 100%;
      padding: 1.5rem;
      box-shadow: 0 25px 50px -12px rgba(0,0,0,0.25);
    }
    .toast {
      position: fixed;
      bottom: 1rem;
      right: 1rem;
      left: auto;
      background: #1e293b;
      color: white;
      padding: 0.6rem 1rem;
      border-radius: 0.75rem;
      font-size: 0.8rem;
      z-index: 1100;
      opacity: 0;
      transition: opacity 0.2s;
      pointer-events: none;
      max-width: calc(100% - 2rem);
    }
    .toast.show { opacity: 1; }
    .toast.success { background: #10b981; }
    .toast.error { background: #ef4444; }

    .log-output {
      background: #0f172a;
      color: #e2e8f0;
      font-family: 'SF Mono', monospace;
      font-size: 0.7rem;
      padding: 0.75rem;
      border-radius: 0.75rem;
      max-height: 500px;
      overflow-y: auto;
      white-space: pre-wrap;
      word-break: break-all;
    }

    .menu-toggle {
      display: none;
      position: fixed;
      top: 1rem;
      left: 1rem;
      z-index: 50;
      background: white;
      border: 1px solid #e2e8f0;
      border-radius: 0.5rem;
      padding: 0.5rem 0.75rem;
      cursor: pointer;
      font-size: 1.25rem;
      box-shadow: 0 1px 3px rgba(0,0,0,0.1);
    }

    @media (max-width: 768px) {
      .menu-toggle {
        display: block;
      }
      .sidebar {
        transform: translateX(-100%);
        width: 260px;
        z-index: 100;
        box-shadow: 2px 0 10px rgba(0,0,0,0.1);
      }
      .sidebar.open {
        transform: translateX(0);
      }
      .main-content {
        margin-left: 0;
        padding-top: 4rem;
        padding-left: 1rem;
        padding-right: 1rem;
      }
      .stats-grid {
        grid-template-columns: 1fr;
        gap: 0.75rem;
      }
      .card-header {
        flex-direction: column;
        align-items: flex-start;
      }
      .form-group {
        min-width: 100%;
      }
      .btn {
        width: 100%;
        text-align: center;
      }
      .login-card {
        margin: 1rem;
        padding: 1.5rem;
      }
    }
  </style>
</head>
<body>

<div id="loginScreen" class="login-container">
  <div class="login-card">
    <div class="login-logo">
      <h1>NOOBS ZIVPN</h1>
      <p>UDP PANEL</p>
    </div>
    <input type="password" id="loginPassword" placeholder="Panel password" autocomplete="off">
    <div id="loginError" class="error-msg"></div>
    <button class="login-btn" onclick="doLogin()">Login →</button>
  </div>
</div>

<div id="app" style="display: none;">
  <div class="menu-toggle" onclick="toggleSidebar()">☰</div>
  <div class="sidebar" id="sidebar">
    <div class="sidebar-header">
      <h2>NOOBS ZIVPN</h2>
      <p>UDP PANEL</p>
    </div>
    <div class="nav-item active" onclick="showPage('dashboard')">
      <i>📊</i> <span>Dashboard</span>
    </div>
    <div class="nav-item" onclick="showPage('users')">
      <i>👥</i> <span>Users</span>
    </div>
    <div class="nav-item" onclick="showPage('service')">
      <i>⚙️</i> <span>Service</span>
    </div>
    <div class="nav-item" onclick="showPage('logs')">
      <i>📜</i> <span>Logs</span>
    </div>
    <div class="sidebar-footer">
      <div class="nav-item" onclick="doLogout()">
        <i>🚪</i> <span>Logout</span>
      </div>
    </div>
  </div>

  <div class="main-content" id="mainContent">
    <!-- Dashboard Page -->
    <div id="page-dashboard" class="page">
      <div class="stats-grid" id="statsGrid">
        <div class="stat-card"><div class="stat-title">Service Status</div><div class="stat-value" id="statService">—</div></div>
        <div class="stat-card"><div class="stat-title">Server IP</div><div class="stat-value cyan" id="statIp">—</div></div>
        <div class="stat-card"><div class="stat-title">Listen Port</div><div class="stat-value yellow" id="statPort">—</div></div>
        <div class="stat-card"><div class="stat-title">Active Users</div><div class="stat-value cyan" id="statUsers">—</div></div>
        <div class="stat-card"><div class="stat-title">Current Connections</div><div class="stat-value cyan" id="statConns">—</div></div>
      </div>
      <div class="card">
        <div class="card-header"><span class="card-title">📡 Client Connection Info</span></div>
        <div class="card-body">
          <table style="width:100%">
            <tr><th style="width:120px">Server IP</th><td id="infoIp">—</td></tr>
            <tr><th>Port Range</th><td>6000 – 19999 (UDP)</td></tr>
            <tr><th>Obfs</th><td>zivpn</td></tr>
            <tr><th>Password</th><td>One of your added users</td></tr>
          </table>
        </div>
      </div>
    </div>

    <!-- Users Page -->
    <div id="page-users" class="page" style="display:none">
      <div class="card">
        <div class="card-header"><span class="card-title">➕ Add New User</span></div>
        <div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>Password</label><input type="text" id="newPassword" class="form-control" placeholder="user123"></div>
            <div class="form-group"><label>Device limit (0 = ∞)</label><input type="number" id="deviceLimit" class="form-control" value="0"></div>
            <div class="form-group"><label>Data limit (GB)</label><input type="number" id="dataLimitGb" class="form-control" value="0" step="1"></div>
            <div class="form-group"><label>Validity (days)</label><input type="number" id="validityDays" class="form-control" value="0"></div>
            <div class="form-group"><label> </label><button class="btn btn-success" onclick="addUser()">Add User</button></div>
          </div>
          <div class="form-row">
            <div class="form-group"><label>Bulk add (comma separated)</label><input type="text" id="bulkPasswords" class="form-control" placeholder="pass1,pass2,pass3"></div>
            <div class="form-group"><label> </label><button class="btn btn-primary" onclick="bulkAdd()">Bulk Add</button></div>
          </div>
        </div>
      </div>
      <div class="card">
        <div class="card-header">
          <span class="card-title">📋 Active Users</span>
          <button class="btn btn-danger btn-sm" onclick="clearAllUsers()">Clear All</button>
        </div>
        <div class="card-body table-responsive">
          <table id="usersTable">
            <thead><tr><th>#</th><th>Password</th><th>Devices</th><th>Remaining GB</th><th>Expiry (days)</th><th>Action</th></tr></thead>
            <tbody><tr><td colspan="6">Loading...</td></tr></tbody>
          </table>
        </div>
      </div>
    </div>

    <!-- Service Page -->
    <div id="page-service" class="page" style="display:none">
      <div class="card">
        <div class="card-header"><span class="card-title">🟢 Service Control</span></div>
        <div class="card-body">
          <div style="display:flex; gap:0.75rem; flex-wrap:wrap; margin-bottom:1rem">
            <button class="btn btn-success" onclick="svcAction('start')">▶ Start</button>
            <button class="btn btn-danger" onclick="svcAction('stop')">⏹ Stop</button>
            <button class="btn btn-warning" onclick="svcAction('restart')">⟳ Restart</button>
          </div>
          <div><span style="font-weight:500">Current status:</span> <span id="serviceStatusBadge" class="badge">—</span></div>
        </div>
      </div>
    </div>

    <!-- Logs Page -->
    <div id="page-logs" class="page" style="display:none">
      <div class="card">
        <div class="card-header">
          <span class="card-title">📜 Service Logs</span>
          <button class="btn btn-primary btn-sm" onclick="loadLogs()">⟳ Refresh</button>
        </div>
        <div class="card-body">
          <pre id="logOutput" class="log-output">Loading logs...</pre>
        </div>
      </div>
    </div>
  </div>
</div>

<div id="monitorModal" class="modal">
  <div class="modal-content">
    <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
      <h3>🔍 Monitor: <span id="monitorUser">—</span></h3>
      <button onclick="closeModal()" style="background:none; border:none; font-size:1.5rem; cursor:pointer">&times;</button>
    </div>
    <div><strong>Active devices:</strong> <span id="monitorDevices">0</span> / <span id="monitorDeviceLimit">∞</span></div>
    <div><strong>Bandwidth remaining:</strong> <span id="monitorRemainingGb">0</span> GB</div>
    <div><strong>Expiry:</strong> <span id="monitorExpiry">Never</span> days left</div>
    <button class="btn btn-primary" style="margin-top:1rem; width:100%" onclick="refreshMonitor()">⟳ Refresh</button>
  </div>
</div>

<div id="toast" class="toast"></div>

<script>
// Helper functions
let currentMonitorPw = null;

async function apiCall(path, method='GET', body=null) {
  const opts = { method, headers: {'Content-Type':'application/json'} };
  if (body) opts.body = JSON.stringify(body);
  const resp = await fetch(path, opts);
  return resp.json();
}

function showToast(msg, type='success') {
  const toast = document.getElementById('toast');
  toast.textContent = msg;
  toast.className = `toast ${type} show`;
  setTimeout(() => toast.classList.remove('show'), 3000);
}

async function doLogin() {
  const pw = document.getElementById('loginPassword').value;
  const res = await apiCall('/api/login', 'POST', { password: pw });
  if (res.ok) {
    document.getElementById('loginScreen').style.display = 'none';
    document.getElementById('app').style.display = 'block';
    loadDashboard();
    loadUsers();
  } else {
    document.getElementById('loginError').innerText = 'Wrong password';
  }
}

async function doLogout() {
  await apiCall('/api/logout', 'POST');
  location.reload();
}

let currentPage = 'dashboard';
function showPage(page) {
  currentPage = page;
  document.querySelectorAll('.page').forEach(p => p.style.display = 'none');
  document.getElementById(`page-${page}`).style.display = 'block';
  document.querySelectorAll('.nav-item').forEach(nav => nav.classList.remove('active'));
  event.currentTarget.classList.add('active');
  if (page === 'dashboard') loadDashboard();
  if (page === 'users') loadUsers();
  if (page === 'service') loadServiceStatus();
  if (page === 'logs') loadLogs();
  if (window.innerWidth <= 768) {
    document.getElementById('sidebar').classList.remove('open');
  }
}

async function loadDashboard() {
  const data = await apiCall('/api/status');
  document.getElementById('statService').innerHTML = data.service === 'active' ? '<span class="stat-value green">RUNNING</span>' : '<span class="stat-value red">STOPPED</span>';
  document.getElementById('statIp').innerText = data.ip;
  document.getElementById('statPort').innerText = data.port;
  document.getElementById('statUsers').innerText = data.users;
  document.getElementById('statConns').innerText = data.connection_count;
  document.getElementById('infoIp').innerText = data.ip;
}

async function loadUsers() {
  const data = await apiCall('/api/users');
  if (!data.users) return;
  const tbody = document.querySelector('#usersTable tbody');
  tbody.innerHTML = data.users.map((u, idx) => `
    <tr class="clickable-row" ondblclick="showMonitor('${escapeHtml(u.password)}')">
      <td>${idx+1}</td>
      <td style="font-weight:500; color:#2c7da0">${escapeHtml(u.password)}</td>
      <td>${u.devices} / ${u.device_limit === 0 ? '∞' : u.device_limit}</td>
      <td>${u.remaining_bytes_gb} GB</td>
      <td>${u.remaining_days === -1 ? 'Never' : u.remaining_days}</td>
      <td><button class="btn btn-danger btn-sm" onclick="removeUser('${escapeHtml(u.password)}')">Remove</button></td>
    </tr>
  `).join('');
}

async function loadServiceStatus() {
  const data = await apiCall('/api/status');
  const badge = document.getElementById('serviceStatusBadge');
  if (data.service === 'active') {
    badge.innerHTML = '<span style="color:#10b981">● RUNNING</span>';
  } else {
    badge.innerHTML = '<span style="color:#ef4444">● STOPPED</span>';
  }
}

async function svcAction(action) {
  const res = await apiCall(`/api/service/${action}`, 'POST');
  if (res.ok) showToast(`Service ${action}ed`, 'success');
  else showToast(`Failed to ${action}`, 'error');
  loadDashboard();
  loadServiceStatus();
}

async function loadLogs() {
  const data = await apiCall('/api/logs');
  const logs = data.logs || 'No logs available';
  document.getElementById('logOutput').innerText = logs.slice(0, 10000);
}

function showMonitor(pw) {
  currentMonitorPw = pw;
  document.getElementById('monitorUser').innerText = pw;
  refreshMonitor();
  document.getElementById('monitorModal').style.display = 'flex';
}

async function refreshMonitor() {
  if (!currentMonitorPw) return;
  const st = await apiCall(`/api/user/status/${currentMonitorPw}`);
  document.getElementById('monitorDevices').innerText = st.devices;
  document.getElementById('monitorDeviceLimit').innerText = st.device_limit === 0 ? '∞' : st.device_limit;
  document.getElementById('monitorRemainingGb').innerText = st.remaining_bytes_gb;
  document.getElementById('monitorExpiry').innerText = st.remaining_days === -1 ? 'Never' : st.remaining_days;
}

function closeModal() {
  document.getElementById('monitorModal').style.display = 'none';
}

async function addUser() {
  const pw = document.getElementById('newPassword').value.trim();
  if (!pw) { showToast('Password required', 'error'); return; }
  const dev = parseInt(document.getElementById('deviceLimit').value) || 0;
  const dataGb = parseFloat(document.getElementById('dataLimitGb').value) || 0;
  const days = parseInt(document.getElementById('validityDays').value) || 0;
  const res = await apiCall('/api/user/add', 'POST', {
    password: pw, device_limit: dev, data_limit_gb: dataGb, validity_days: days
  });
  if (res.ok) {
    showToast('User added');
    document.getElementById('newPassword').value = '';
    loadUsers();
    loadDashboard();
  } else {
    showToast('User exists or error', 'error');
  }
}

async function bulkAdd() {
  const val = document.getElementById('bulkPasswords').value.trim();
  if (!val) { showToast('Enter passwords', 'error'); return; }
  const pws = val.split(',').map(s=>s.trim()).filter(Boolean);
  let added = 0;
  for (const pw of pws) {
    const res = await apiCall('/api/user/add', 'POST', { password: pw, device_limit:0, data_limit_gb:0, validity_days:0 });
    if (res.ok) added++;
  }
  showToast(`${added} user(s) added`);
  document.getElementById('bulkPasswords').value = '';
  loadUsers();
  loadDashboard();
}

async function removeUser(pw) {
  if (!confirm(`Remove user "${pw}"?`)) return;
  const res = await apiCall('/api/user/remove', 'POST', { password: pw });
  if (res.ok) { showToast('User removed'); loadUsers(); loadDashboard(); }
  else showToast('Failed', 'error');
}

async function clearAllUsers() {
  if (!confirm('⚠️ Delete ALL users? This will disconnect all clients.')) return;
  await apiCall('/api/user/clear', 'POST');
  showToast('All users cleared');
  loadUsers();
  loadDashboard();
}

function toggleSidebar() {
  document.getElementById('sidebar').classList.toggle('open');
}

function escapeHtml(str) {
  return str.replace(/[&<>]/g, function(m) {
    if (m === '&') return '&amp;';
    if (m === '<') return '&lt;';
    if (m === '>') return '&gt;';
    return m;
  });
}

// Auto-refresh
setInterval(() => {
  if (currentPage === 'dashboard') loadDashboard();
  if (currentPage === 'users') loadUsers();
}, 15000);

// Check if already logged in
(async () => {
  const st = await apiCall('/api/status');
  if (!st.error) {
    document.getElementById('loginScreen').style.display = 'none';
    document.getElementById('app').style.display = 'block';
    loadDashboard();
    loadUsers();
  }
})();
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
        elif path == "/api/devices":
            devices = get_connected_devices(force_refresh=True)
            result = [{"password": pw, "devices": len(ips), "ips": ips} for pw, ips in devices.items()]
            self.send_json(result)
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

def start_background_chain_attacher():
    """Start a background thread to periodically re-attach chains."""
    threading.Thread(target=periodic_chain_attacher, daemon=True).start()

if __name__ == "__main__":
    conf = load_panel_conf()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else conf.get("port", 8080)
    ip = server_ip()
    start_background_expiry_checker()
    start_background_chain_attacher()
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"NOOBS ZIVPN Web Panel (bandwidth fixed)  ►  http://{ip}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nWeb panel stopped.")
