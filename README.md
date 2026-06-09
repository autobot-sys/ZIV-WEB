🛡️ NOOBS ZIVPN UDP PANEL
�
￼ ￼ ￼ ￼ ￼ 


�
Full-featured ZIVPN UDP installer with terminal panel + browser web panel.
One command installs everything. Works directly with the ZIVPN client app. 


⚡ One-Line Install
Bash
Run as root on a fresh Debian/Ubuntu VPS.
📱 Client App Setup
After adding a user via the panel, connect the ZIVPN app using:
Field
Value
Server
Your VPS public IP
Port
Any port between 6000–19999
Password
Password you created
Obfs
zivpn
🖥️ Terminal Panel
After installation, open the management panel anytime:
Bash
Features
Option
Description
[1]
List all users + client connection info
[2]
Add single user
[3]
Bulk add users (comma-separated)
[4]
Trial user (auto-expires 1–60 min)
[5]
Remove single user
[6]
Remove multiple users
[7]
Clear all users
[8]
Start ZIVPN
[9]
Stop ZIVPN
[10]
Restart ZIVPN
[u]
Auto-update all scripts from GitHub
[w]
Web panel control
[m]
Live connection monitor
[p]
Change listen port
[c]
Config check & repair
[i]
About / info
🌐 Web Panel
The web panel gives you a browser-based UI to manage ZIVPN from any device.
Enable Web Panel
Bash
Then press [w] → [1] Install
Enter your preferred port (default 8080) and password, then open:
Code
Default login password: admin
⚠️ Change it immediately after first login via zivudp → [w] → [4] Change Password
Web Panel Pages
Page
Features
Dashboard
Service status, server IP, port, active users, connections, client info
Users
List users, add single, bulk add, remove per user, clear all
Service
Start / Stop / Restart with live status badge
Logs
Last 60 service log lines, colour-coded by type
🔧 How It Works
Code
Key Config Fields
Json
📦 Repository Structure
Code
🗂️ Installed File Locations
File
Path
ZIVPN binary
/usr/local/bin/zivpn
Config
/etc/zivpn/config.json
TLS Certificate
/etc/zivpn/zivpn.crt
TLS Key
/etc/zivpn/zivpn.key
User database
/etc/zivpn/users.db
Terminal panel
/usr/local/bin/zivudp
Web panel
/etc/zivpn/webpanel.py
Web panel config
/etc/zivpn/webpanel.conf
ZIVPN service
/etc/systemd/system/zivpn.service
Web panel service
/etc/systemd/system/zivpanel.service
🔄 Update Scripts
To pull the latest panel scripts from this repo:
Bash
Then press [u] — updates zivudp.sh, install.sh, webpanel.py, and the ZIVPN binary automatically.
Or update the panel only via command line:
Bash
🛠️ Supported Operating Systems
OS
Status
Debian 10 / 11 / 12
✅ Fully supported
Ubuntu 20.04 LTS
✅ Fully supported
Ubuntu 22.04 LTS
✅ Fully supported
Ubuntu 24.04 LTS
✅ Fully supported
Kali Linux (server)
✅ Fully supported
CentOS / AlmaLinux
❌ Not supported
Alpine Linux
❌ Not supported
Architecture: AMD x64 (amd64) and ARM64 (arm64)
🔌 Ports Used
Port
Protocol
Purpose
5667
UDP
ZIVPN listen port
6000–19999
UDP
NAT relay (client connects here)
8080
TCP
Web panel (default, configurable)
22
TCP
SSH (kept open to prevent lockout)
⚙️ Service Commands
Bash
👤 Credits
Role
Name
Original ZIVPN UDP
Zahid Islam
Installer & Panel
PowerMX / autobot-sys
📜 License
MIT License — see LICENSE
