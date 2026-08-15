#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  NOOBS ZIVPN UDP PANEL  —  zivudp
#  Version : 4.2.0
# ═══════════════════════════════════════════════════════════════

PANEL_VERSION="4.2.0"
CONFIG_FILE="/etc/zivpn/config.json"
DB_FILE="/etc/zivpn/users.db"
META_FILE="/etc/zivpn/users_meta.json"
BIN_PATH="/usr/local/bin/zivpn"
PANEL_PATH="/usr/local/bin/zivudp"
WEBPANEL_PY="/etc/zivpn/webpanel.py"
WEBPANEL_CONF="/etc/zivpn/webpanel.conf"
WEBPANEL_SVC="/etc/systemd/system/zivpanel.service"
ACCT_BIN="/usr/local/bin/zivacctd"
REPO_RAW="https://raw.githubusercontent.com/autobot-sys/ZIV-WEB/main"

# Colors
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'
M='\033[1;35m'; C='\033[1;36m'; W='\033[1;37m'; DIM='\033[2m'
BOLD='\033[1m'; NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${R}Run as root.${NC}"; exit 1; }

# Dependencies
command -v jq &>/dev/null || apt-get install -y -qq jq
command -v curl &>/dev/null || apt-get install -y -qq curl
command -v python3 &>/dev/null || apt-get install -y -qq python3

# ═══════════════════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════════════════
svc_running() { systemctl is-active --quiet zivpn; }
webpanel_running() { systemctl is-active --quiet zivpanel 2>/dev/null; }
acct_running() { systemctl is-active --quiet zivacct 2>/dev/null; }

get_port() { jq -r '.listen // ":5667"' "$CONFIG_FILE" 2>/dev/null | tr -d ':'; }
server_ip() { curl -4 -s --max-time 5 "https://api.ipify.org" 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'; }

webpanel_get_port() {
  python3 -c "import json; d=json.load(open('$WEBPANEL_CONF')); print(d.get('port',8080))" 2>/dev/null || echo "8080"
}

press_any() {
  echo ""
  read -p "  Press Enter to continue..." dummy
}

get_passwords() { jq -r '.auth.config[]' "$CONFIG_FILE" 2>/dev/null; }

add_password() {
  local pass="$1" dev="$2" data="$3" days="$4"
  jq --arg p "$pass" '.auth.config += [$p]' "$CONFIG_FILE" > /tmp/zv.json && mv /tmp/zv.json "$CONFIG_FILE"
  python3 -c "
import json, time
meta = json.load(open('$META_FILE')) if __import__('os').path.exists('$META_FILE') else {}
if '$pass' not in meta:
    expiry = time.time() + $days * 86400 if $days > 0 else None
    meta['$pass'] = {
        'device_limit': $dev,
        'data_limit_bytes': int($data * 1024**3) if $data > 0 else 0,
        'data_used_bytes': 0,
        'expiry': expiry,
        'created_at': time.time()
    }
    json.dump(meta, open('$META_FILE', 'w'), indent=2)
"
  systemctl restart zivpn 2>/dev/null
  acct_running && systemctl restart zivacct 2>/dev/null
}

remove_password() {
  local pass="$1"
  jq --arg p "$pass" '.auth.config -= [$p]' "$CONFIG_FILE" > /tmp/zv.json && mv /tmp/zv.json "$CONFIG_FILE"
  python3 -c "
import json
meta = json.load(open('$META_FILE'))
meta.pop('$pass', None)
json.dump(meta, open('$META_FILE', 'w'), indent=2)
" 2>/dev/null
  systemctl restart zivpn 2>/dev/null
  acct_running && systemctl restart zivacct 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
#  HEADER
# ═══════════════════════════════════════════════════════════════
draw_header() {
  clear
  echo -e "${C}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║       NOOBS ZIVPN UDP PANEL  v${PANEL_VERSION}       ║"
  echo "  ╠══════════════════════════════════════════════════════╣"
  local IP=$(server_ip)
  local PORT=$(get_port)
  local CNT=$(jq -r '.auth.config | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
  local SVC="STOPPED"
  svc_running && SVC="RUNNING"
  printf "  ║  IP      : %-42s║\n" "$IP"
  printf "  ║  Port    : %-42s║\n" "$PORT/udp"
  printf "  ║  Users   : %-42s║\n" "$CNT"
  printf "  ║  Service : %-42s║\n" "$SVC"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: LIST USERS
# ═══════════════════════════════════════════════════════════════
screen_list() {
  draw_header
  echo -e "\n  ${W}USERS:${NC}"
  local i=1
  while IFS= read -r p; do
    [ -n "$p" ] && echo -e "  ${G}$i.${NC} ${W}$p${NC}" && ((i++))
  done < <(get_passwords)
  echo ""
  read -p "  Press Enter to continue..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: ADD USER
# ═══════════════════════════════════════════════════════════════
screen_add() {
  draw_header
  echo -e "\n  ${W}ADD USER${NC}"
  read -p "  Password: " pass
  [ -z "$pass" ] && return
  read -p "  Device limit (0=unlimited): " dev
  dev=${dev:-0}
  read -p "  Data limit GB (0=unlimited): " data
  data=${data:-0}
  read -p "  Validity days (0=unlimited): " days
  days=${days:-0}
  add_password "$pass" "$dev" "$data" "$days"
  echo "$pass|permanent|unlimited|$(date +%Y-%m-%d)" >> "$DB_FILE"
  echo -e "\n  ${G}✔ User added${NC}"
  read -p "  Press Enter..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: BULK ADD
# ═══════════════════════════════════════════════════════════════
screen_bulk_add() {
  draw_header
  echo -e "\n  ${W}BULK ADD${NC}"
  read -p "  Passwords (comma separated): " input
  [ -z "$input" ] && return
  IFS=',' read -r -a incoming <<< "$input"
  local added=0
  for np in "${incoming[@]}"; do
    np=$(echo "$np" | xargs)
    [ -z "$np" ] && continue
    add_password "$np" 0 0 0
    echo "$np|permanent|unlimited|$(date +%Y-%m-%d)" >> "$DB_FILE"
    ((added++))
  done
  echo -e "\n  ${G}✔ $added user(s) added${NC}"
  read -p "  Press Enter..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: TRIAL USER
# ═══════════════════════════════════════════════════════════════
screen_trial() {
  draw_header
  echo -e "\n  ${W}TRIAL USER${NC}"
  read -p "  Duration (minutes, 1-60): " mins
  if ! [[ "$mins" =~ ^[0-9]+$ ]] || [ "$mins" -lt 1 ] || [ "$mins" -gt 60 ]; then
    echo -e "  ${R}Invalid duration${NC}"
    read -p "  Press Enter..." dummy
    return
  fi
  local pass="trial_$(openssl rand -hex 3)"
  add_password "$pass" 0 0 0
  python3 -c "
import json, time
meta = json.load(open('$META_FILE'))
if '$pass' in meta:
    meta['$pass']['expiry'] = time.time() + $mins * 60
    json.dump(meta, open('$META_FILE', 'w'), indent=2)
"
  echo -e "\n  ${G}✔ Trial: $pass (expires in $mins min)${NC}"
  read -p "  Press Enter..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: REMOVE USER
# ═══════════════════════════════════════════════════════════════
screen_remove() {
  draw_header
  echo -e "\n  ${W}REMOVE USER${NC}"
  local i=1
  while IFS= read -r p; do
    [ -n "$p" ] && echo -e "  ${G}$i.${NC} ${W}$p${NC}" && ((i++))
  done < <(get_passwords)
  read -p "  Delete # (0=cancel): " sel
  [ "$sel" = "0" ] && return
  local i=1
  while IFS= read -r p; do
    if [ "$i" = "$sel" ]; then
      remove_password "$p"
      sed -i "/^${p}|/d" "$DB_FILE" 2>/dev/null
      echo -e "\n  ${G}✔ Removed $p${NC}"
      break
    fi
    ((i++))
  done < <(get_passwords)
  read -p "  Press Enter..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: CLEAR ALL
# ═══════════════════════════════════════════════════════════════
screen_clear() {
  draw_header
  echo -e "\n  ${R}⚠ CLEAR ALL USERS${NC}"
  read -p "  Confirm? (yes/no): " confirm
  if [ "$confirm" = "yes" ]; then
    jq '.auth.config = []' "$CONFIG_FILE" > /tmp/zv.json && mv /tmp/zv.json "$CONFIG_FILE"
    echo '{}' > "$META_FILE"
    > "$DB_FILE"
    systemctl restart zivpn 2>/dev/null
    echo -e "\n  ${G}✔ All cleared${NC}"
  fi
  read -p "  Press Enter..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: SERVICE CONTROL
# ═══════════════════════════════════════════════════════════════
screen_service() {
  draw_header
  echo -e "\n  ${W}SERVICE CONTROL${NC}"
  echo -e "  ${G}[1]${NC} Start"
  echo -e "  ${R}[2]${NC} Stop"
  echo -e "  ${Y}[3]${NC} Restart"
  read -p "  Select: " s
  case "$s" in
    1) systemctl start zivpn; sleep 1 ;;
    2) systemctl stop zivpn; sleep 1 ;;
    3) systemctl restart zivpn; sleep 2 ;;
  esac
  svc_running && echo -e "\n  ${G}✔ RUNNING${NC}" || echo -e "\n  ${R}✘ STOPPED${NC}"
  read -p "  Press Enter..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: MONITOR
# ═══════════════════════════════════════════════════════════════
screen_monitor() {
  draw_header
  echo -e "\n  ${W}MONITOR${NC}"
  local PORT=$(get_port)
  command -v conntrack &>/dev/null && conntrack -L -p udp -n 2>/dev/null | grep "dport=$PORT" | head -20
  echo ""
  read -p "  Press Enter..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: CHANGE PORT
# ═══════════════════════════════════════════════════════════════
screen_change_port() {
  draw_header
  echo -e "\n  ${W}CHANGE PORT${NC}"
  local curr=$(get_port)
  echo -e "  Current: $curr"
  read -p "  New port: " np
  if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1024 ] && [ "$np" -le 65535 ]; then
    jq --arg p ":$np" '.listen = $p' "$CONFIG_FILE" > /tmp/zv.json && mv /tmp/zv.json "$CONFIG_FILE"
    iptables -I INPUT -p udp --dport "$np" -j ACCEPT 2>/dev/null
    systemctl restart zivpn 2>/dev/null
    echo -e "\n  ${G}✔ Port changed to $np${NC}"
  else
    echo -e "\n  ${R}✘ Invalid port${NC}"
  fi
  read -p "  Press Enter..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: WEB PANEL
# ═══════════════════════════════════════════════════════════════
screen_webpanel() {
  while true; do
    draw_header
    echo -e "\n  ${W}WEB PANEL CONTROL${NC}"
    
    local INSTALLED=0
    [ -f "$WEBPANEL_PY" ] && [ -f "$WEBPANEL_SVC" ] && INSTALLED=1
    
    if [ $INSTALLED -eq 1 ]; then
      local IP=$(server_ip)
      local PORT=$(webpanel_get_port)
      if webpanel_running; then
        echo -e "  Status: ${G}RUNNING${NC}"
      else
        echo -e "  Status: ${R}STOPPED${NC}"
      fi
      echo -e "  URL: ${C}http://${IP}:${PORT}${NC}"
    else
      echo -e "  ${Y}Not installed${NC}"
    fi
    
    echo ""
    if [ $INSTALLED -eq 0 ]; then
      echo -e "  ${G}[1]${NC} Install Web Panel"
    else
      echo -e "  ${G}[1]${NC} Start / Restart"
      echo -e "  ${R}[2]${NC} Stop"
      echo -e "  ${C}[3]${NC} Change Password"
      echo -e "  ${C}[4]${NC} Change Port"
      echo -e "  ${R}[5]${NC} Uninstall"
    fi
    echo -e "  ${DIM}[0]${NC} Back"
    echo ""
    read -p "  Select: " wc
    
    case "$wc" in
      1)
        if [ $INSTALLED -eq 0 ]; then
          echo -ne "  Web panel port [8080]: "; read -r wp_port
          wp_port=${wp_port:-8080}
          echo -ne "  Admin password [admin]: "; read -r wp_pass
          wp_pass=${wp_pass:-admin}
          
          wget -q --timeout=20 "$REPO_RAW/panel/webpanel.py" -O "$WEBPANEL_PY"
          if [ -s "$WEBPANEL_PY" ]; then
            python3 -c "
import json, hashlib
c = {'port': $wp_port, 'pass_hash': hashlib.sha256('$wp_pass'.encode()).hexdigest()}
json.dump(c, open('$WEBPANEL_CONF', 'w'), indent=2)
"
            cat > "$WEBPANEL_SVC" << EOF
[Unit]
Description=NOOBS ZIVPN Web Panel
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $WEBPANEL_PY $wp_port
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable zivpanel 2>/dev/null
            systemctl restart zivpanel
            iptables -I INPUT -p tcp --dport "$wp_port" -j ACCEPT 2>/dev/null
            sleep 2
            local IP=$(server_ip)
            echo -e "\n  ${G}✔ Installed! URL: http://${IP}:${wp_port}${NC}"
          else
            echo -e "\n  ${R}✘ Download failed${NC}"
          fi
        else
          systemctl restart zivpanel
          sleep 1
          echo -e "\n  ${G}✔ Restarted${NC}"
        fi
        read -p "  Press Enter..." dummy
        ;;
      2) systemctl stop zivpanel; echo -e "\n  ${G}✔ Stopped${NC}"; read -p "  Press Enter..." dummy ;;
      3)
        echo -ne "  New password: "; read -r new_pass
        python3 -c "
import json, hashlib
d = json.load(open('$WEBPANEL_CONF'))
d['pass_hash'] = hashlib.sha256('$new_pass'.encode()).hexdigest()
json.dump(d, open('$WEBPANEL_CONF', 'w'), indent=2)
"
        systemctl restart zivpanel
        echo -e "\n  ${G}✔ Password updated${NC}"
        read -p "  Press Enter..." dummy
        ;;
      4)
        echo -ne "  New port: "; read -r new_port
        python3 -c "
import json
d = json.load(open('$WEBPANEL_CONF'))
d['port'] = $new_port
json.dump(d, open('$WEBPANEL_CONF', 'w'), indent=2)
"
        cat > "$WEBPANEL_SVC" << EOF
[Unit]
Description=NOOBS ZIVPN Web Panel
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $WEBPANEL_PY $new_port
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl restart zivpanel
        iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null
        echo -e "\n  ${G}✔ Port changed to $new_port${NC}"
        read -p "  Press Enter..." dummy
        ;;
      5)
        systemctl stop zivpanel 2>/dev/null
        systemctl disable zivpanel 2>/dev/null
        rm -f "$WEBPANEL_SVC" "$WEBPANEL_PY" "$WEBPANEL_CONF"
        systemctl daemon-reload
        echo -e "\n  ${G}✔ Uninstalled${NC}"
        read -p "  Press Enter..." dummy
        ;;
      0) return ;;
      *) echo -e "\n  ${R}Invalid${NC}"; sleep 1 ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: AUTO-UPDATE
# ═══════════════════════════════════════════════════════════════
screen_update() {
  draw_header
  echo -e "\n  ${W}AUTO-UPDATE${NC}"
  echo -e "  ${DIM}Updating from: $REPO_RAW${NC}"
  echo ""
  
  local ERRS=0
  
  # Update zivudp.sh
  echo -ne "  ${C}⟳${NC} Panel (zivudp.sh)..."
  wget -q --timeout=20 "$REPO_RAW/panel/zivudp.sh" -O /tmp/zivudp_new.sh
  if [ -s /tmp/zivudp_new.sh ]; then
    sed -i 's/\r$//' /tmp/zivudp_new.sh
    bash -n /tmp/zivudp_new.sh 2>/dev/null
    if [ $? -eq 0 ]; then
      cp /tmp/zivudp_new.sh "$PANEL_PATH"
      chmod +x "$PANEL_PATH"
      echo -e "  ${G}✔ Updated${NC}"
    else
      echo -e "  ${R}✘ Syntax error in download${NC}"
      ((ERRS++))
    fi
  else
    echo -e "  ${R}✘ Download failed${NC}"
    ((ERRS++))
  fi
  rm -f /tmp/zivudp_new.sh
  
  # Update webpanel.py
  echo -ne "  ${C}⟳${NC} Web panel (webpanel.py)..."
  if [ -f "$WEBPANEL_PY" ]; then
    wget -q --timeout=20 "$REPO_RAW/panel/webpanel.py" -O "$WEBPANEL_PY"
    [ -s "$WEBPANEL_PY" ] && echo -e "  ${G}✔ Updated${NC}" || { echo -e "  ${R}✘ Failed${NC}"; ((ERRS++)); }
  else
    echo -e "  ${DIM}Not installed, skipped${NC}"
  fi
  
  echo ""
  if [ $ERRS -eq 0 ]; then
    echo -e "  ${G}✔ All updates complete${NC}"
  else
    echo -e "  ${Y}⚠ $ERRS error(s)${NC}"
  fi
  echo ""
  read -p "  Press Enter to restart panel..." dummy
  exec "$PANEL_PATH"
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: ACCOUNTING
# ═══════════════════════════════════════════════════════════════
screen_accounting() {
  draw_header
  echo -e "\n  ${W}ACCOUNTING DAEMON${NC}"
  if acct_running; then
    echo -e "  Status: ${G}RUNNING${NC}"
  else
    echo -e "  Status: ${R}STOPPED${NC} or not installed"
  fi
  echo ""
  echo -e "  ${G}[1]${NC} Start/Restart"
  echo -e "  ${R}[2]${NC} Stop"
  read -p "  Select: " ac
  case "$ac" in
    1) 
      if [ -f "$ACCT_BIN" ]; then
        systemctl restart zivacct
        echo -e "\n  ${G}✔ Restarted${NC}"
      else
        echo -e "\n  ${Y}Not installed. Run installer to compile.${NC}"
      fi
      ;;
    2) 
      systemctl stop zivacct
      echo -e "\n  ${G}✔ Stopped${NC}"
      ;;
  esac
  read -p "  Press Enter..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: ABOUT
# ═══════════════════════════════════════════════════════════════
screen_about() {
  draw_header
  echo -e "\n  ${W}ABOUT${NC}"
  echo -e "  Version: $PANEL_VERSION"
  echo -e "  Repo: github.com/autobot-sys/ZIV-WEB"
  echo ""
  read -p "  Press Enter..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════════════════
while true; do
  draw_header
  echo ""
  echo -e "  ${G}[1]${NC} List Users        ${G}[2]${NC} Add User"
  echo -e "  ${G}[3]${NC} Bulk Add          ${Y}[4]${NC} Trial User"
  echo -e "  ${R}[5]${NC} Remove User       ${R}[6]${NC} Clear All"
  echo -e "  ${G}[7]${NC} Service Control"
  echo -e "  ${M}[w]${NC} Web Panel         ${C}[8]${NC} Monitor"
  echo -e "  ${C}[9]${NC} Change Port       ${M}[u]${NC} Auto-Update"
  echo -e "  ${M}[a]${NC} Accounting        ${W}[i]${NC} About"
  echo -e "  ${R}[q]${NC} Exit"
  echo ""
  echo -ne "  ${C}▶${NC} Select: "
  read -r choice
  case "$choice" in
    1) screen_list ;;
    2) screen_add ;;
    3) screen_bulk_add ;;
    4) screen_trial ;;
    5) screen_remove ;;
    6) screen_clear ;;
    7) screen_service ;;
    w|W) screen_webpanel ;;
    8) screen_monitor ;;
    9) screen_change_port ;;
    u|U) screen_update ;;
    a|A) screen_accounting ;;
    i|I) screen_about ;;
    q|Q|0) clear; echo -e "\n  ${C}★ Goodbye! ★${NC}\n"; exit 0 ;;
    *) echo -e "\n  ${R}Invalid option${NC}"; sleep 1 ;;
  esac
done
