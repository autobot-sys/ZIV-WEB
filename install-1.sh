#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  NOOBS ZIVPN UDP — Installer
#  Repo    : https://github.com/autobot-sys/ZIV-WEB
#  Panel   : zivudp  |  Web Panel : zivudp → [w]
#
#  ── ONE-LINE INSTALL ────────────────────────────────────────
#  apt update && apt install -y curl && bash <(curl -s https://raw.githubusercontent.com/autobot-sys/ZIV-WEB/main/install.sh)
# ═══════════════════════════════════════════════════════════════

CONFIG_FILE="/etc/zivpn/config.json"
DB_FILE="/etc/zivpn/users.db"
PANEL_PATH="/usr/local/bin/zivudp"
WEBPANEL_PATH="/etc/zivpn/webpanel.py"
BIN_PATH="/usr/local/bin/zivpn"
REPO_RAW="https://raw.githubusercontent.com/autobot-sys/ZIV-WEB/main"

# ── Colours ──────────────────────────────────────────────────────
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

step()  { echo -e "\n${Y}[$1/$TOTAL]${NC} $2"; }
ok()    { echo -e "  ${G}✔ $*${NC}"; }
fail()  { echo -e "  ${R}✘ $* — exiting.${NC}"; exit 1; }
warn()  { echo -e "  ${Y}⚠ $* (continuing)${NC}"; }

TOTAL=8

# ── Root check ───────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && { echo -e "${R}Run as root.${NC}"; exit 1; }

# ── Password gate ──────────────────────────────────────────────────
# Only a SHA-256 hash of the password is stored below. The plaintext
# password is never written to this file, never echoed, and never
# logged. Installation aborts immediately if the hash doesn't match.
PASS_HASH="25809d28dc0f580a263b8e39548491e5bc8358af41e3be4df8b095b423530c3d"

hash_input() {
  if command -v sha256sum &>/dev/null; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v openssl &>/dev/null; then
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
  else
    echo -e "${R}No SHA-256 utility found (need sha256sum or openssl). Exiting.${NC}"
    exit 1
  fi
}

MAX_ATTEMPTS=3
attempt=1
authorized=0
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  read -s -p "Enter installation password: " ENTERED_PASS
  echo
  ENTERED_HASH=$(hash_input "$ENTERED_PASS")
  unset ENTERED_PASS
  if [ "$ENTERED_HASH" = "$PASS_HASH" ]; then
    authorized=1
    unset ENTERED_HASH
    break
  fi
  echo -e "${R}Incorrect password. ($attempt/$MAX_ATTEMPTS)${NC}"
  attempt=$((attempt + 1))
done

[ "$authorized" -eq 1 ] || { echo -e "${R}Too many failed attempts. Aborting installation.${NC}"; exit 1; }

# ── Fix hostname DNS warning ─────────────────────────────────────
HN=$(hostname)
grep -q "$HN" /etc/hosts 2>/dev/null || echo "127.0.1.1 $HN" >> /etc/hosts

# ── Server info ───────────────────────────────────────────────────
GEO=$(curl -4 -s --max-time 10 "https://ipapi.co/json/" 2>/dev/null || echo '{}')
IP=$(echo "$GEO"   | grep -oP '"ip":\s*"\K[^"]+' 2>/dev/null || hostname -I | awk '{print $1}')
CITY=$(echo "$GEO" | grep -oP '"city":\s*"\K[^"]+' 2>/dev/null || echo "Unknown")
ISP=$(echo "$GEO"  | grep -oP '"org":\s*"\K[^"]+' 2>/dev/null  || echo "Unknown")
OS_INFO=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)
ARCH=$(uname -m)

clear
echo -e "${C}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║       NOOBS ZIVPN UDP PANEL — INSTALLER             ║"
echo "  ║       github.com/autobot-sys/ZIV-WEB                ║"
echo "  ╠══════════════════════════════════════════════════════╣"
printf "  ║  OS   : %-44s║\n" "$OS_INFO"
printf "  ║  IP   : %-44s║\n" "$IP"
printf "  ║  City : %-44s║\n" "$CITY"
printf "  ║  ISP  : %-44s║\n" "$ISP"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Step 1: Dependencies ─────────────────────────────────────────
step 1 "Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget jq openssl python3 iptables iptables-persistent \
  netfilter-persistent bc vnstat || warn "Some packages may not have installed"
ok "Dependencies ready"

# ── Step 2: Architecture ──────────────────────────────────────────
step 2 "Detecting architecture..."
case $ARCH in
  x86_64|amd64)  BIN_ARCH="amd64" ;;
  aarch64|arm64) BIN_ARCH="arm64" ;;
  *) fail "Unsupported architecture: $ARCH" ;;
esac
ok "Architecture: $ARCH → $BIN_ARCH"

# ── Step 3: Download ZIVPN binary ────────────────────────────────
step 3 "Downloading ZIVPN binary..."
systemctl stop zivpn 2>/dev/null || true

wget -q --timeout=30 --show-progress \
  "https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-$BIN_ARCH" \
  -O "$BIN_PATH" || fail "Binary download failed. Check internet connection."

[ -s "$BIN_PATH" ] || fail "Downloaded binary is empty."
chmod +x "$BIN_PATH"
ok "Binary installed → $BIN_PATH"

# ── Step 4: Config & database ────────────────────────────────────
step 4 "Writing config and database..."
mkdir -p /etc/zivpn

cat > "$CONFIG_FILE" << 'CONF'
{
  "listen": ":5667",
  "cert": "/etc/zivpn/zivpn.crt",
  "key": "/etc/zivpn/zivpn.key",
  "obfs": "zivpn",
  "auth": {
    "mode": "passwords",
    "config": []
  }
}
CONF

touch "$DB_FILE"
ok "Config → $CONFIG_FILE"

# ── Step 5: SSL Certificate ───────────────────────────────────────
step 5 "Generating SSL certificate (RSA 4096 — ~30s)..."
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
  -subj "/C=GH/ST=Accra/L=Accra/O=NoobsVPN/CN=zivpn" \
  -keyout "/etc/zivpn/zivpn.key" \
  -out    "/etc/zivpn/zivpn.crt" 2>/dev/null || fail "SSL generation failed."
chmod 600 /etc/zivpn/zivpn.key
ok "Certificate generated"

# ── Step 6: Firewall ─────────────────────────────────────────────
step 6 "Configuring firewall..."

if command -v ufw &>/dev/null; then
  ufw disable &>/dev/null || true
  ok "UFW disabled (using iptables directly)"
fi

iptables -I INPUT -p tcp --dport 22    -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p udp --dport 5667  -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p udp --dport 6000:19999 -j ACCEPT 2>/dev/null || true
iptables -t nat -A PREROUTING -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || true

mkdir -p /etc/iptables
if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save 2>/dev/null || true
else
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
ok "Firewall rules applied and saved"

# ── Step 7: Systemd service ───────────────────────────────────────
step 7 "Installing systemd service..."

cat > /etc/systemd/system/zivpn.service << 'UNIT'
[Unit]
Description=NOOBS ZIVPN UDP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable zivpn 2>/dev/null
systemctl start  zivpn

sleep 2
if systemctl is-active --quiet zivpn; then
  ok "ZIVPN service running"
else
  echo -e "  ${R}✘ Service failed to start. Logs:${NC}"
  journalctl -u zivpn -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
fi

# ── Step 8: Download panel + web panel ───────────────────────────
step 8 "Installing management panel and web panel..."

# ─ Terminal panel (zivudp) ───────────────────────────────────────
wget -q --timeout=30 "$REPO_RAW/panel/zivudp.sh" -O "$PANEL_PATH" || \
  warn "zivudp panel download failed — re-run: zivudp"
if [ -s "$PANEL_PATH" ]; then
  chmod +x "$PANEL_PATH"
  ok "Terminal panel installed → zivudp"
else
  warn "Terminal panel not downloaded"
fi

# ─ Web panel (webpanel.py) ───────────────────────────────────────
wget -q --timeout=30 "$REPO_RAW/panel/webpanel.py" -O "$WEBPANEL_PATH" || \
  warn "webpanel.py download failed"
if [ -s "$WEBPANEL_PATH" ]; then
  chmod +x "$WEBPANEL_PATH"
  ok "Web panel downloaded → $WEBPANEL_PATH"
  echo -e "  ${DIM}  Start web panel from:  zivudp → [w] → [1] Install${NC}"
else
  warn "webpanel.py not downloaded — run Auto-Update inside zivudp to retry"
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo -e "${G}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${G}║          ✔  INSTALLATION COMPLETE                   ║${NC}"
echo -e "${G}╠══════════════════════════════════════════════════════╣${NC}"
printf "${G}║${NC}  %-20s ${W}%-31s${G}║${NC}\n" "Server IP"     "$IP"
printf "${G}║${NC}  %-20s ${W}%-31s${G}║${NC}\n" "Location"      "$CITY"
printf "${G}║${NC}  %-20s ${W}%-31s${G}║${NC}\n" "Listen Port"   "5667/udp"
printf "${G}║${NC}  %-20s ${W}%-31s${G}║${NC}\n" "NAT Relay"     "6000-19999/udp"
printf "${G}║${NC}  %-20s ${W}%-31s${G}║${NC}\n" "Obfs Key"      "zivpn"
printf "${G}║${NC}  %-20s ${W}%-31s${G}║${NC}\n" "Terminal Panel" "zivudp"
printf "${G}║${NC}  %-20s ${W}%-31s${G}║${NC}\n" "Web Panel"     "zivudp → [w] → [1]"
printf "${G}║${NC}  %-20s ${W}%-31s${G}║${NC}\n" "Repo"          "github.com/autobot-sys/ZIV-WEB"
echo -e "${G}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${Y}▶  Type ${W}zivudp${Y} to open the terminal management panel.${NC}"
echo -e "  ${Y}▶  Run  ${W}zivudp → [w]${Y} to set up the web panel.${NC}"
echo ""
