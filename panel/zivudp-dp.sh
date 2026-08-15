#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  NOOBS ZIVPN UDP PANEL  —  zivudp
#  Repo    : https://github.com/autobot-sys/ZIV-WEB
#  Version : 4.4.0 (Complete Production Version)
# ═══════════════════════════════════════════════════════════════

PANEL_VERSION="4.4.0"
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

# ═══════════════════════════════════════════════════════════════
#  COLOURS
# ═══════════════════════════════════════════════════════════════
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'
M='\033[1;35m'; C='\033[1;36m'; W='\033[1;37m'; DR='\033[0;31m'
DG='\033[0;32m'; DY='\033[0;33m'; DC='\033[0;36m'; DW='\033[0;37m'
DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# ═══════════════════════════════════════════════════════════════
#  ROOT CHECK
# ═══════════════════════════════════════════════════════════════
[ "$EUID" -ne 0 ] && { echo -e "\n  ${R}✘  Run as root: sudo zivudp${NC}\n"; exit 1; }

# ═══════════════════════════════════════════════════════════════
#  DEPENDENCY CHECK
# ═══════════════════════════════════════════════════════════════
ensure_dependencies() {
  local missing=()
  command -v jq &>/dev/null || missing+=("jq")
  command -v curl &>/dev/null || missing+=("curl")
  command -v wget &>/dev/null || missing+=("wget")
  command -v python3 &>/dev/null || missing+=("python3")
  command -v openssl &>/dev/null || missing+=("openssl")
  command -v iptables &>/dev/null || missing+=("iptables")
  command -v conntrack &>/dev/null || missing+=("conntrack-tools")
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${Y}Installing: ${missing[*]}...${NC}"
    apt-get update -qq &>/dev/null
    apt-get install -y -qq "${missing[@]}" &>/dev/null
  fi
  modprobe nf_conntrack &>/dev/null || true
}
ensure_dependencies

# ═══════════════════════════════════════════════════════════════
#  SERVICE HELPERS
# ═══════════════════════════════════════════════════════════════
svc_running() { systemctl is-active --quiet zivpn; }
webpanel_running() { systemctl is-active --quiet zivpanel 2>/dev/null; }
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

pwd_count() {
  jq -r '.auth.config | length' "$CONFIG_FILE" 2>/dev/null || echo "0"
}

get_port() {
  jq -r '.listen // ":5667"' "$CONFIG_FILE" 2>/dev/null | tr -d ':'
}

server_ip() {
  curl -4 -s --max-time 5 "https://api.ipify.org" 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}'
}

reload_svc() { systemctl restart zivpn 2>/dev/null; }

restart_acct_daemon() {
  if acct_running; then
    systemctl restart zivacct 2>/dev/null
  fi
}

# ═══════════════════════════════════════════════════════════════
#  USER MANAGEMENT
# ═══════════════════════════════════════════════════════════════
add_password() {
  local pass="$1"
  local dev_limit="$2"
  local data_gb="$3"
  local valid_days="$4"
  ensure_config
  
  # Add to config.json
  jq --arg p "$pass" '.auth.config += [$p]' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
  
  # Create Python script to handle metadata
  cat > /tmp/zv_add_meta.py << PYEOF
import json, time, os, sys

META_FILE = "$META_FILE"
pass_word = "$pass"
dev_limit = int("$dev_limit")
data_gb = float("$data_gb")
valid_days = int("$valid_days")

# Load existing metadata
meta = {}
if os.path.exists(META_FILE):
    try:
        with open(META_FILE) as f:
            content = f.read().strip()
            if content:
                meta = json.loads(content)
    except Exception as e:
        print(f"ERROR loading metadata: {e}", file=sys.stderr)
        meta = {}

# Check if user exists
if pass_word in meta:
    print("EXISTS")
    sys.exit(1)

# Create user entry
expiry = None
if valid_days > 0:
    expiry = time.time() + valid_days * 86400

meta[pass_word] = {
    "device_limit": dev_limit,
    "data_limit_bytes": int(data_gb * 1024**3) if data_gb > 0 else 0,
    "data_used_bytes": 0,
    "expiry": expiry,
    "created_at": time.time()
}

# Save metadata
with open(META_FILE, "w") as f:
    json.dump(meta, f, indent=2)

print("OK")
sys.exit(0)
PYEOF

  # Run the Python script
  local result=$(python3 /tmp/zv_add_meta.py 2>&1)
  local exit_code=$?
  rm -f /tmp/zv_add_meta.py
  
  echo -e "  ${DIM}Result: $result${NC}"
  
  # Setup iptables quota if data limit > 0
  if [ "$data_gb" -gt 0 ] && [ $exit_code -eq 0 ]; then
    setup_iptables_quota "$pass" "$data_gb"
  fi
  
  restart_acct_daemon
  return $exit_code
}

remove_password() {
  local pass="$1"
  ensure_config
  
  # Remove from config.json
  jq --arg p "$pass" '.auth.config -= [$p]' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
  
  # Remove from metadata
  cat > /tmp/zv_meta.py << PYEOF
import json, os

META_FILE = "$META_FILE"
pass_word = "$pass"

if os.path.exists(META_FILE):
    with open(META_FILE) as f:
        meta = json.load(f)
    if pass_word in meta:
        del meta[pass_word]
        with open(META_FILE, "w") as f:
            json.dump(meta, f, indent=2)
        print("OK")
    else:
        print("NOT_FOUND")
else:
    print("NO_FILE")
PYEOF

  python3 /tmp/zv_meta.py
  rm -f /tmp/zv_meta.py
  
  delete_iptables_chain "$pass"
  restart_acct_daemon
}

clear_passwords() {
  ensure_config
  jq '.auth.config = []' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
  echo '{}' > "$META_FILE"
  > "$DB_FILE"
  
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

# ═══════════════════════════════════════════════════════════════
#  USER DETAILS
# ═══════════════════════════════════════════════════════════════
get_user_details() {
  local pass="$1"
  cat > /tmp/zv_details.py << PYEOF
import json, time, os, sys

META_FILE = "$META_FILE"
pass_word = "$pass"

try:
    with open(META_FILE) as f:
        meta = json.load(f)
    data = meta.get(pass_word, {})
    
    dev_limit = data.get("device_limit", 0)
    data_limit = data.get("data_limit_bytes", 0)
    data_used = data.get("data_used_bytes", 0)
    expiry = data.get("expiry")
    
    # Calculate remaining days
    remaining_days = -1
    if expiry:
        remaining_days = max(0, int((expiry - time.time()) / 86400))
    
    # Calculate remaining GB
    remaining_gb = -1
    if data_limit > 0:
        remaining_gb = round(max(0, data_limit - data_used) / (1024**3), 2)
    
    print(f"{dev_limit}|{remaining_gb}|{remaining_days}")
except Exception as e:
    print("0|-1|-1")
PYEOF

  python3 /tmp/zv_details.py 2>/dev/null
  rm -f /tmp/zv_details.py
}

get_active_devices() {
  local port=$(get_port)
  if command -v conntrack &>/dev/null; then
    conntrack -L -p udp -n 2>/dev/null | grep "dport=$port" | grep -oP 'src=\K[0-9.]+' | sort -u | wc -l
  else
    echo "0"
  fi
}

# ═══════════════════════════════════════════════════════════════
#  HEADER & UI
# ═══════════════════════════════════════════════════════════════
draw_header() {
  clear
  echo -e "${C}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║       NOOBS ZIVPN UDP PANEL  v${PANEL_VERSION}       ║"
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

press_any() {
  echo ""
  read -p "  Press Enter to continue..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: LIST USERS (WITH DETAILS)
# ═══════════════════════════════════════════════════════════════
screen_list() {
  draw_header
  echo -e "\n  ${W}USERS WITH LIMITS:${NC}\n"
  
  local users=$(get_passwords)
  if [ -z "$users" ]; then
    echo -e "  ${DIM}No users configured. Use option [2] to add users.${NC}"
  else
    echo -e "  ${DIM}┌────┬──────────────────┬─────────┬────────────┬───────────┐${NC}"
    echo -e "  ${DIM}│ No │ Password         │ Devices │ Remaining  │  Expiry   │${NC}"
    echo -e "  ${DIM}│    │                  │  Limit  │    GB      │  (days)   │${NC}"
    echo -e "  ${DIM}├────┼──────────────────┼─────────┼────────────┼───────────┤${NC}"
    
    local i=1
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      
      local details=$(get_user_details "$p")
      local dev_limit=$(echo "$details" | cut -d'|' -f1)
      local remaining_gb=$(echo "$details" | cut -d'|' -f2)
      local remaining_days=$(echo "$details" | cut -d'|' -f3)
      
      local device_display="∞"
      [ "$dev_limit" != "0" ] && device_display="$dev_limit"
      
      local gb_display="∞"
      [ "$remaining_gb" != "-1" ] && gb_display="${remaining_gb} GB"
      
      local expiry_display="∞"
      [ "$remaining_days" != "-1" ] && expiry_display="${remaining_days} days"
      
      printf "  ${DIM}│${NC} ${G}%-3s${DIM}│${NC} ${W}%-16s${DIM}│${NC} %-7s${DIM}│${NC} %-10s${DIM}│${NC} %-9s${DIM}│${NC}\n" \
        "$i" "${p:0:16}" "$device_display" "$gb_display" "$expiry_display"
      
      ((i++))
    done < <(get_passwords)
    
    echo -e "  ${DIM}└────┴──────────────────┴─────────┴────────────┴───────────┘${NC}"
  fi
  
  echo ""
  read -p "  Press Enter to continue..." dummy
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: ADD USER
# ═══════════════════════════════════════════════════════════════
screen_add_user() {
  draw_header
  echo -e "\n  ${W}ADD NEW USER${NC}\n"
  
  read -p "  Password: " pass
  pass=$(echo "$pass" | xargs)
  [ -z "$pass" ] && { echo -e "  ${R}Password cannot be empty${NC}"; press_any; return; }
  
  read -p "  Device limit (0=unlimited): " dev
  dev=${dev:-0}
  
  read -p "  Data limit GB (0=unlimited): " data
  data=${data:-0}
  
  read -p "  Validity days (0=unlimited): " days
  days=${days:-0}
  
  add_password "$pass" "$dev" "$data" "$days"
  local result=$?
  
  if [ $result -eq 0 ]; then
    echo "$pass|permanent|unlimited|$(date +%Y-%m-%d)" >> "$DB_FILE"
    reload_svc
    echo -e "\n  ${G}✔ User added successfully${NC}"
    echo -e "  ${DIM}  Password: $pass${NC}"
    echo -e "  ${DIM}  Device Limit: $dev${NC}"
    echo -e "  ${DIM}  Data Limit: $data GB${NC}"
    echo -e "  ${DIM}  Validity: $days days${NC}"
  else
    echo -e "\n  ${Y}⚠ User already exists${NC}"
  fi
  
  press_any
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: BULK ADD
# ═══════════════════════════════════════════════════════════════
screen_bulk_add() {
  draw_header
  echo -e "\n  ${W}BULK ADD USERS${NC}\n"
  read -p "  Passwords (comma separated): " input
  [ -z "$input" ] && { echo -e "  ${R}No input${NC}"; press_any; return; }
  
  IFS=',' read -r -a incoming <<< "$input"
  local added=0 skipped=0
  
  for np in "${incoming[@]}"; do
    np=$(echo "$np" | xargs)
    [ -z "$np" ] && continue
    
    add_password "$np" 0 0 0
    if [ $? -eq 0 ]; then
      echo "$np|permanent|unlimited|$(date +%Y-%m-%d)" >> "$DB_FILE"
      ((added++))
    else
      ((skipped++))
    fi
  done
  
  reload_svc
  echo -e "\n  ${G}✔ $added user(s) added${NC}"
  [ $skipped -gt 0 ] && echo -e "  ${Y}  $skipped duplicate(s) skipped${NC}"
  press_any
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: TRIAL USER
# ═══════════════════════════════════════════════════════════════
screen_trial_user() {
  draw_header
  echo -e "\n  ${W}TRIAL USER${NC}\n"
  read -p "  Duration (minutes, 1-60): " mins
  
  if ! [[ "$mins" =~ ^[0-9]+$ ]] || [ "$mins" -lt 1 ] || [ "$mins" -gt 60 ]; then
    echo -e "  ${R}Invalid duration${NC}"
    press_any
    return
  fi
  
  local pass="trial_$(openssl rand -hex 3)"
  add_password "$pass" 0 0 0
  
  # Set expiry
  cat > /tmp/zv_trial.py << PYEOF
import json, time

META_FILE = "$META_FILE"
pass_word = "$pass"
minutes = $mins

with open(META_FILE) as f:
    meta = json.load(f)

if pass_word in meta:
    meta[pass_word]["expiry"] = time.time() + minutes * 60
    with open(META_FILE, "w") as f:
        json.dump(meta, f, indent=2)
    print("OK")
PYEOF

  python3 /tmp/zv_trial.py
  rm -f /tmp/zv_trial.py
  
  reload_svc
  
  local IP=$(server_ip)
  echo -e "\n  ${G}✔ Trial user created${NC}"
  echo -e "  ${DIM}  Password: $pass${NC}"
  echo -e "  ${DIM}  Server IP: $IP${NC}"
  echo -e "  ${DIM}  Duration: $mins minutes${NC}"
  echo -e "  ${DIM}  Expires: $(date -d "+$mins minutes" '+%Y-%m-%d %H:%M:%S')${NC}"
  
  press_any
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: REMOVE USER
# ═══════════════════════════════════════════════════════════════
screen_remove_user() {
  draw_header
  echo -e "\n  ${W}REMOVE USER${NC}\n"
  
  local users=$(get_passwords)
  if [ -z "$users" ]; then
    echo -e "  ${DIM}No users to remove${NC}"
    press_any
    return
  fi
  
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
      echo -e "\n  ${G}✔ Removed: $p${NC}"
      break
    fi
    ((i++))
  done < <(get_passwords)
  
  press_any
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: CLEAR ALL
# ═══════════════════════════════════════════════════════════════
screen_clear_all() {
  draw_header
  echo -e "\n  ${R}⚠ CLEAR ALL USERS${NC}\n"
  read -p "  Confirm? (yes/no): " confirm
  
  if [ "$confirm" = "yes" ]; then
    clear_passwords
    reload_svc
    echo -e "\n  ${G}✔ All users cleared${NC}"
  else
    echo -e "\n  ${Y}Cancelled${NC}"
  fi
  
  press_any
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: SERVICE CONTROL
# ═══════════════════════════════════════════════════════════════
screen_service() {
  draw_header
  echo -e "\n  ${W}SERVICE CONTROL${NC}\n"
  echo -e "  ${G}[1]${NC} Start"
  echo -e "  ${R}[2]${NC} Stop"
  echo -e "  ${Y}[3]${NC} Restart"
  echo -e "  ${DIM}[0]${NC} Back"
  echo ""
  read -p "  Select: " s
  
  case "$s" in
    1) systemctl start zivpn; sleep 1 ;;
    2) systemctl stop zivpn; sleep 1 ;;
    3) systemctl restart zivpn; sleep 2 ;;
    0) return ;;
  esac
  
  svc_running && echo -e "\n  ${G}✔ RUNNING${NC}" || echo -e "\n  ${R}✘ STOPPED${NC}"
  press_any
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: WEB PANEL
# ═══════════════════════════════════════════════════════════════
screen_webpanel() {
  while true; do
    draw_header
    echo -e "\n  ${W}WEB PANEL CONTROL${NC}\n"
    
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
            sed -i 's/\r$//' "$WEBPANEL_PY"
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
            echo -e "  ${DIM}  Password: $wp_pass${NC}"
          else
            echo -e "\n  ${R}✘ Download failed${NC}"
          fi
        else
          systemctl restart zivpanel
          sleep 1
          echo -e "\n  ${G}✔ Restarted${NC}"
        fi
        press_any
        ;;
      2) systemctl stop zivpanel; echo -e "\n  ${G}✔ Stopped${NC}"; press_any ;;
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
        press_any
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
        press_any
        ;;
      5)
        systemctl stop zivpanel 2>/dev/null
        systemctl disable zivpanel 2>/dev/null
        rm -f "$WEBPANEL_SVC" "$WEBPANEL_PY" "$WEBPANEL_CONF"
        systemctl daemon-reload
        echo -e "\n  ${G}✔ Uninstalled${NC}"
        press_any
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
  echo -e "\n  ${W}AUTO-UPDATE${NC}\n"
  echo -e "  ${DIM}Updating from: $REPO_RAW${NC}\n"
  
  local ERRS=0
  
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
  echo -e "\n  ${W}ACCOUNTING DAEMON${NC}\n"
  
  if acct_running; then
    echo -e "  Status: ${G}RUNNING${NC}"
  else
    echo -e "  Status: ${R}STOPPED${NC} or not installed"
  fi
  
  echo ""
  echo -e "  ${G}[1]${NC} Start/Restart"
  echo -e "  ${R}[2]${NC} Stop"
  echo -e "  ${DIM}[0]${NC} Back"
  echo ""
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
    0) return ;;
  esac
  
  press_any
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: MONITOR
# ═══════════════════════════════════════════════════════════════
screen_monitor() {
  draw_header
  echo -e "\n  ${W}LIVE MONITOR${NC}\n"
  
  local PORT=$(get_port)
  if command -v conntrack &>/dev/null; then
    conntrack -L -p udp -n 2>/dev/null | grep "dport=$PORT" | head -20
  else    echo -e "  ${DIM}conntrack not available${NC}"
  fi
  
  echo -e "\n  ${W}Per-user bandwidth:${NC}\n"
  cat > /tmp/zv_bw.py << PYEOF
import json

META_FILE = "$META_FILE"
try:
    with open(META_FILE) as f:
        meta = json.load(f)
    for pw, data in meta.items():
        limit = data.get("data_limit_bytes", 0)
        used = data.get("data_used_bytes", 0)
        if limit > 0:
            rem = (limit - used) / (1024**3)
            print(f"  {pw}: {used/1024**3:.2f} GB used / {limit/1024**3:.2f} GB limit (remaining: {rem:.2f} GB)")
        else:
            print(f"  {pw}: unlimited")
except Exception as e:
    print("  No data available")
PYEOF
  
  python3 /tmp/zv_bw.py
  rm -f /tmp/zv_bw.py
  
  press_any
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: CHANGE PORT
# ═══════════════════════════════════════════════════════════════
screen_change_port() {
  draw_header
  echo -e "\n  ${W}CHANGE PORT${NC}\n"
  
  local curr=$(get_port)
  echo -e "  Current port: $curr"
  read -p "  New port: " np
  
  if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1024 ] && [ "$np" -le 65535 ]; then
    jq --arg p ":$np" '.listen = $p' "$CONFIG_FILE" > /tmp/zv.json && mv /tmp/zv.json "$CONFIG_FILE"
    iptables -I INPUT -p udp --dport "$np" -j ACCEPT 2>/dev/null
    reload_svc
    echo -e "\n  ${G}✔ Port changed to $np${NC}"
  else
    echo -e "\n  ${R}✘ Invalid port${NC}"
  fi
  
  press_any
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN: ABOUT
# ═══════════════════════════════════════════════════════════════
screen_about() {
  draw_header
  echo -e "\n  ${W}ABOUT${NC}\n"
  echo -e "  Version: $PANEL_VERSION"
  echo -e "  Repo: github.com/autobot-sys/ZIV-WEB"
  echo -e "  Config: $CONFIG_FILE"
  echo -e "  Metadata: $META_FILE"
  echo -e "  Binary: $BIN_PATH"
  echo -e "  Panel: $PANEL_PATH"
  
  if [ -f "$ACCT_BIN" ]; then
    echo -e "  Accounting: $ACCT_BIN"
  fi
  
  if [ -f "$WEBPANEL_PY" ]; then
    echo -e "  Web Panel: $WEBPANEL_PY"
  fi
  
  press_any
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
  echo -e "  ${G}[7]${NC} Service Control   ${M}[w]${NC} Web Panel"
  echo -e "  ${C}[8]${NC} Monitor           ${C}[9]${NC} Change Port"
  echo -e "  ${M}[u]${NC} Auto-Update       ${M}[a]${NC} Accounting"
  echo -e "  ${W}[i]${NC} About             ${R}[q]${NC} Exit"
  echo ""
  echo -ne "  ${C}▶${NC} Select: "
  read -r choice
  
  case "$choice" in
    1) screen_list ;;
    2) screen_add_user ;;
    3) screen_bulk_add ;;
    4) screen_trial_user ;;
    5) screen_remove_user ;;
    6) screen_clear_all ;;
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
