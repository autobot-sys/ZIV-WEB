# 🛡️ NOOBS ZIVPN UDP PANEL

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Linux%20x64%20%7C%20ARM64-blue?style=for-the-badge&logo=linux&logoColor=white"/>
  <img src="https://img.shields.io/badge/Protocol-ZIVPN%20UDP-00d4ff?style=for-the-badge"/>
  <img src="https://img.shields.io/badge/Shell-Bash-yellow?style=for-the-badge&logo=gnubash&logoColor=black"/>
  <img src="https://img.shields.io/badge/Web%20Panel-Python3-3776ab?style=for-the-badge&logo=python&logoColor=white"/>
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge"/>
</p>

<p align="center">
  <b>Full-featured ZIVPN UDP installer with terminal panel + browser web panel.</b><br>
  One command installs everything. Works directly with the ZIVPN client app.
</p>

---

## ⚡ One-Line Install

```bash
apt update && apt install -y curl && bash <(curl -s https://raw.githubusercontent.com/autobot-sys/ZIV-WEB/main/install.sh)
```

> Run as **root** on a fresh Debian/Ubuntu VPS.

---

## 📱 Client App Setup

After adding a user via the panel, connect the **ZIVPN app** using:

| Field    | Value                          |
|----------|-------------------------------|
| Server   | Your VPS public IP             |
| Port     | Any port between `6000–19999` |
| Password | Password you created           |
| Obfs     | `zivpn`                        |

---

## 🖥️ Terminal Panel

After installation, open the management panel anytime:

```bash
zivudp
```

### Features

| Option | Description |
|--------|-------------|
| `[1]` | List all users + client connection info |
| `[2]` | Add single user |
| `[3]` | Bulk add users (comma-separated) |
| `[4]` | Trial user (auto-expires 1–60 min) |
| `[5]` | Remove single user |
| `[6]` | Remove multiple users |
| `[7]` | Clear all users |
| `[8]` | Start ZIVPN |
| `[9]` | Stop ZIVPN |
| `[10]` | Restart ZIVPN |
| `[u]` | Auto-update all scripts from GitHub |
| `[w]` | Web panel control |
| `[m]` | Live connection monitor |
| `[p]` | Change listen port |
| `[c]` | Config check & repair |
| `[i]` | About / info |

---

## 🌐 Web Panel

The web panel gives you a browser-based UI to manage ZIVPN from any device.

### Enable Web Panel

```bash
zivudp
```
Then press **`[w]`** → **`[1] Install`**

Enter your preferred port (default `8080`) and password, then open:

```
http://YOUR-VPS-IP:8080
```

**Default login password:** `admin`  
⚠️ Change it immediately after first login via `zivudp → [w] → [4] Change Password`

### Web Panel Pages

| Page | Features |
|------|----------|
| **Dashboard** | Service status, server IP, port, active users, connections, client info |
| **Users** | List users, add single, bulk add, remove per user, clear all |
| **Service** | Start / Stop / Restart with live status badge |
| **Logs** | Last 60 service log lines, colour-coded by type |

---

## 🔧 How It Works

```
ZIVPN Client App
       │
       ▼  UDP port 6000–19999
iptables NAT (PREROUTING)
       │
       ▼  redirected to :5667
zivpn server  (/usr/local/bin/zivpn)
       │
       ▼
/etc/zivpn/config.json  ←  passwords live here (auth.config)
```

### Key Config Fields

```json
{
  "listen": ":5667",
  "cert":   "/etc/zivpn/zivpn.crt",
  "key":    "/etc/zivpn/zivpn.key",
  "obfs":   "zivpn",
  "auth": {
    "mode":   "passwords",
    "config": ["yourpassword"]
  }
}
```

---

## 📦 Repository Structure

```
ZIV-WEB/
├── install.sh          ← Main installer
├── panel/
│   ├── zivudp.sh       ← Terminal management panel
│   └── webpanel.py     ← Browser web panel (Python3)
└── README.md
```

---

## 🗂️ Installed File Locations

| File | Path |
|------|------|
| ZIVPN binary | `/usr/local/bin/zivpn` |
| Config | `/etc/zivpn/config.json` |
| TLS Certificate | `/etc/zivpn/zivpn.crt` |
| TLS Key | `/etc/zivpn/zivpn.key` |
| User database | `/etc/zivpn/users.db` |
| Terminal panel | `/usr/local/bin/zivudp` |
| Web panel | `/etc/zivpn/webpanel.py` |
| Web panel config | `/etc/zivpn/webpanel.conf` |
| ZIVPN service | `/etc/systemd/system/zivpn.service` |
| Web panel service | `/etc/systemd/system/zivpanel.service` |

---

## 🔄 Update Scripts

To pull the latest panel scripts from this repo:

```bash
zivudp
```
Then press **`[u]`** — updates `zivudp.sh`, `install.sh`, `webpanel.py`, and the ZIVPN binary automatically.

Or update the panel only via command line:

```bash
wget -qO /usr/local/bin/zivudp https://raw.githubusercontent.com/autobot-sys/ZIV-WEB/main/panel/zivudp.sh && chmod +x /usr/local/bin/zivudp
```

---

## 🛠️ Supported Operating Systems

| OS | Status |
|----|--------|
| Debian 10 / 11 / 12 | ✅ Fully supported |
| Ubuntu 20.04 LTS | ✅ Fully supported |
| Ubuntu 22.04 LTS | ✅ Fully supported |
| Ubuntu 24.04 LTS | ✅ Fully supported |
| Kali Linux (server) | ✅ Fully supported |
| CentOS / AlmaLinux | ❌ Not supported |
| Alpine Linux | ❌ Not supported |

**Architecture:** AMD x64 (`amd64`) and ARM64 (`arm64`)

---

## 🔌 Ports Used

| Port | Protocol | Purpose |
|------|----------|---------|
| `5667` | UDP | ZIVPN listen port |
| `6000–19999` | UDP | NAT relay (client connects here) |
| `8080` | TCP | Web panel (default, configurable) |
| `22` | TCP | SSH (kept open to prevent lockout) |

---

## ⚙️ Service Commands

```bash
# ZIVPN service
systemctl start   zivpn
systemctl stop    zivpn
systemctl restart zivpn
systemctl status  zivpn

# Web panel service
systemctl start   zivpanel
systemctl stop    zivpanel
systemctl restart zivpanel
systemctl status  zivpanel

# View logs
journalctl -u zivpn    -f
journalctl -u zivpanel -f
```

---

## 👤 Credits

| Role | Name |
|------|------|
| Original ZIVPN UDP | [Zahid Islam](https://github.com/zahidbd2) |
| Installer & Panel | Ardvak / [autobot-sys](https://github.com/autobot-sys) |

---

## 📜 License

MIT License — see [LICENSE](LICENSE)
