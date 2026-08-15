#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  NOOBS ZIVPN UDP PANEL  —  zivudp
#  Version : 4.0.1 (fixed)
# ═══════════════════════════════════════════════════════════════

PANEL_VERSION="4.0.1"
CONFIG_FILE="/etc/zivpn/config.json"
DB_FILE="/etc/zivpn/users.db"
META_FILE="/etc/zivpn/users_meta.json"
BIN_PATH="/usr/local/bin/zivpn"
PANEL_PATH="/usr/local/bin/zivudp"
WEBPANEL_PY="/etc/zivpn/webpanel.py"
WEBPANEL_CONF="/etc/zivpn/webpanel.conf"
WEBPANEL_SVC="/etc/systemd/system/zivpanel.service"
ACCT_BIN="/usr/local/bin/zivacctd"
ACCT_SVC="/etc/systemd/system/zivacct.service"
REPO_RAW="https://raw.githubusercontent.com/autobot-sys/ZIV-WEB/main"

# Colours
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'
M='\033[1;35m'; C='\033[1;36m'; W='\033[1;37m'; DR='\033[0;31m'
DG='\033[0;32m'; DY='\033[0;33m'; DC='\033[0;36m'; DW='\033[0;37m'
DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# Root check
[ "$EUID" -ne 0 ] && { echo -e "\n  ${R}✘  Run as root: sudo zivudp${NC}\n"; exit 1; }

# ═══════════════════════════════════════════════════════════════
#  DEPENDENCY CHECK
# ═══════════════════════════════════════════════════════════════
ensure_dependencies() {
  command -v jq &>/dev/null || apt-get install -y -qq jq
  command -v curl &>/dev/null || apt-get install -y -qq curl
  command -v python3 &>/dev/null || apt-get install -y -qq python3
  command -v openssl &>/dev/null || apt-get install -y -qq openssl
  command -v conntrack &>/dev/null || apt-get install -y -qq conntrack-tools
  modprobe nf_conntrack &>/dev/null || true
}
ensure_dependencies

# ═══════════════════════════════════════════════════════════════
#  CORE HELPERS
# ═══════════════════════════════════════════════════════════════
svc_running() { systemctl is-active --quiet zivpn; }
acct_running() { systemctl is-active --quiet zivacct 2>/dev/null; }

ensure_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
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
  fi
  [ ! -f "$META_FILE" ] && echo '{}' > "$META_FILE"
  [ ! -f "$DB_FILE" ] && touch "$DB_FILE"
}

get_passwords() {
  ensure_config
  jq -r '.auth.config[]' "$CONFIG_FILE" 2>/dev/null
}

restart_acct_daemon() {
  if acct_running; then
    systemctl restart zivacct 2>/dev/null
  fi
}

add_password() {
  local pass="$1"
  local dev_limit="$2"
  local data_gb="$3"
  local valid_days="$4"
  ensure_config
  jq --arg p "$pass" '.auth.config += [$p]' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
  python3 -c "
import json, time
META='$META_FILE'
meta = json.load(open(META)) if __import__('os').path.exists(META) else {}
if '$pass' not in meta:
    expiry = None
    if $valid_days > 0:
        expiry = time.time() + $valid_days * 86400
    meta['$pass'] = {
        'device_limit': $dev_limit,
        'data_limit_bytes': int($data_gb * 1024**3) if $data_gb > 0 else 0,
        'data_used_bytes': 0,
        'expiry': expiry,
        'created_at': time.time()
    }
    json.dump(meta, open(META, 'w'), indent=2)
"
  if [ "$data_gb" -gt 0 ]; then
    setup_iptables_quota "$pass" "$data_gb"
  fi
  restart_acct_daemon
}

remove_password() {
  local pass="$1"
  ensure_config
  jq --arg p "$pass" '.auth.config -= [$p]' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
  python3 -c "
import json
META='$META_FILE'
if __import__('os').path.exists(META):
    meta = json.load(open(META))
    meta.pop('$pass', None)
    json.dump(meta, open(META, 'w'), indent=2)
"
  delete_iptables_chain "$pass"
  restart_acct_daemon
}

clear_passwords() {
  ensure_config
  jq '.auth.config = []' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
  echo '{}' > "$META_FILE"
  for chain in $(iptables -S 2>/dev/null | awk '/^-N ZIV_USER_/{print $2}'); do
    delete_iptables_chain "${chain#ZIV_USER_}"
  done
  restart_acct_daemon
}

setup_iptables_quota() {
  local pass="$1"
  local limit_gb="$2"
  local chain="ZIV_USER_$pass"
  local limit_bytes=$((limit_gb * 1024**3))
  iptables -N "$chain" 2>/dev/null
  iptables -F "$chain" 2>/dev/null
  iptables -A "$chain" -m quota --quota "$limit_bytes" -j RETURN 2>/dev/null
  iptables -A "$chain" -j DROP 2>/dev/null
}

delete_iptables_chain() {
  local pass="$1"
  local chain="ZIV_USER_$pass"
  local line
  while line=$(iptables -L INPUT --line-numbers -n 2>/dev/null | grep "$chain" | tail -1 | awk '{print $1}') && [ -n "$line" ]; do
    iptables -D INPUT "$line" 2>/dev/null || break
  done
  iptables -F "$chain" 2>/dev/null
  iptables -X "$chain" 2>/dev/null
}

pwd_count() {
  jq -r '.auth.config | length' "$CONFIG_FILE" 2>/dev/null || echo "0"
}

get_port() {
  jq -r '.listen // ":5667"' "$CONFIG_FILE" 2>/dev/null | tr -d ':'
}

server_ip() {
  curl -4 -s --max-time 5 "https://api.ipify.org" 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}

reload_svc() { systemctl restart zivpn 2>/dev/null; }

press_any() {
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -ne "  ${DY}↩  Press Enter to return...${NC} "
  read -r
}

confirm_yn() {
  echo -ne "  ${Y}$1 ${DW}[yes/no]${NC}: "
  read -r ans
  [ "$ans" = "yes" ]
}

result_ok()   { echo -e "\n  ${G}  ✔  $*${NC}"; }
result_warn() { echo -e "\n  ${Y}  ⚠  $*${NC}"; }
result_err()  { echo -e "\n  ${R}  ✘  $*${NC}"; }

# ═══════════════════════════════════════════════════════════════
#  HEADER
# ═══════════════════════════════════════════════════════════════
draw_header() {
  clear
  echo -e "${C}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║       NOOBS ZIVPN UDP PANEL                         ║"
  echo "  ╠══════════════════════════════════════════════════════╣"
  local IP=$(server_ip)
  local PORT=$(get_port)
  local CNT=$(pwd_count)
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
#  SCREEN FUNCTIONS
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
  reload_svc
  echo -e "\n  ${G}✔ User added${NC}"
  read -p "  Press Enter..." dummy
}

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
  reload_svc
  echo -e "\n  ${G}✔ $added user(s) added${NC}"
  read -p "  Press Enter..." dummy
}

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
META='$META_FILE'
meta = json.load(open(META))
if '$pass' in meta:
    meta['$pass']['expiry'] = time.time() + $mins * 60
    json.dump(meta, open(META, 'w'), indent=2)
"
  reload_svc
  echo -e "\n  ${G}✔ Trial user: $pass (expires in $mins min)${NC}"
  read -p "  Press Enter..." dummy
}

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
      reload_svc
      echo -e "\n  ${G}✔ Removed $p${NC}"
      break
    fi
    ((i++))
  done < <(get_passwords)
  read -p "  Press Enter..." dummy
}

screen_clear() {
  draw_header
  echo -e "\n  ${R}⚠ CLEAR ALL USERS${NC}"
  read -p "  Confirm? (yes/no): " confirm
  if [ "$confirm" = "yes" ]; then
    clear_passwords
    > "$DB_FILE"
    reload_svc
    echo -e "\n  ${G}✔ All cleared${NC}"
  fi
  read -p "  Press Enter..." dummy
}

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

screen_monitor() {
  draw_header
  echo -e "\n  ${W}MONITOR${NC}"
  local PORT=$(get_port)
  conntrack -L -p udp -n 2>/dev/null | grep "dport=$PORT" | head -20
  echo ""
  read -p "  Press Enter..." dummy
}

screen_change_port() {
  draw_header
  echo -e "\n  ${W}CHANGE PORT${NC}"
  local curr=$(get_port)
  echo -e "  Current: $curr"
  read -p "  New port: " np
  if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1024 ] && [ "$np" -le 65535 ]; then
    jq --arg p ":$np" '.listen = $p' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
    iptables -I INPUT -p udp --dport "$np" -j ACCEPT 2>/dev/null
    reload_svc
    echo -e "\n  ${G}✔ Port changed to $np${NC}"
  else
    echo -e "\n  ${R}✘ Invalid port${NC}"
  fi
  read -p "  Press Enter..." dummy
}

screen_accounting() {
  draw_header
  echo -e "\n  ${W}ACCOUNTING DAEMON${NC}"
  if acct_running; then
    echo -e "  Status: ${G}RUNNING${NC}"
  else
    echo -e "  Status: ${R}STOPPED${NC}"
  fi
  echo ""
  echo -e "  ${G}[1]${NC} Start/Restart"
  echo -e "  ${R}[2]${NC} Stop"
  echo -e "  ${Y}[3]${NC} Recompile"
  read -p "  Select: " ac
  case "$ac" in
    1) 
      if [ -f "$ACCT_BIN" ]; then
        systemctl restart zivacct
      else
        echo -e "  ${Y}Not installed. Run installer.${NC}"
      fi
      ;;
    2) systemctl stop zivacct ;;
    3) 
      if [ -f "$ACCT_BIN" ]; then
        gcc -O3 -o "$ACCT_BIN" /tmp/zivacctd.c -lnetfilter_queue -lnetfilter_conntrack -lmnl -lnfnetlink -lpthread 2>/dev/null
        systemctl restart zivacct
      fi
      ;;
  esac
  sleep 1
}

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
  echo -e "  ${C}[8]${NC} Monitor           ${C}[9]${NC} Change Port"
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
    8) screen_monitor ;;
    9) screen_change_port ;;
    a|A) screen_accounting ;;
    i|I) screen_about ;;
    q|Q|0) clear; echo -e "\n  ${C}★ Goodbye! ★${NC}\n"; exit 0 ;;
    *) echo -e "\n  ${R}Invalid option${NC}"; sleep 1 ;;
  esac
done
