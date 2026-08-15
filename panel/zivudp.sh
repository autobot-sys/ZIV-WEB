#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  NOOBS ZIVPN UDP PANEL  —  zivudp
#  Version : 4.0.0
# ═══════════════════════════════════════════════════════════════

PANEL_VERSION="4.0.0"
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

# Colors
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
  local -A pkg_for=(
    [jq]=jq
    [python3]=python3
    [iptables]=iptables
    [conntrack]=conntrack-tools
    [curl]=curl
    [wget]=wget
    [openssl]=openssl
  )
  local missing=()
  for cmd in "${!pkg_for[@]}"; do
    command -v "$cmd" &>/dev/null || missing+=("${pkg_for[$cmd]}")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${Y}Installing missing dependencies: ${missing[*]}...${NC}"
    apt-get update -qq &>/dev/null
    apt-get install -y -qq "${missing[@]}" &>/dev/null
  fi
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
  curl -4 -s --max-time 5 "https://api.ipify.org" 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}'
}

reload_svc() { systemctl restart zivpn 2>/dev/null; }

press_any() {
  echo ""
  echo -e "  ${DIM}╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌${NC}"
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
#  HEADER & DASHBOARD
# ═══════════════════════════════════════════════════════════════
draw_header() {
    clear
    local box_width=60
    _center_line() {
        local text="$1" colour="$2"
        local text_len=${#text}
        local pad_left=$(( (box_width - text_len) / 2 ))
        local pad_right=$(( box_width - text_len - pad_left ))
        printf "  ${C}║${NC}"
        printf "%*s" "$pad_left" ""
        printf "%b" "${colour}${text}${NC}"
        printf "%*s" "$pad_right" ""
        printf "${C}║${NC}\n"
    }
    local border_line
    border_line=$(printf '═%.0s' $(seq 1 $box_width))
    printf "  ${C}╔%s╗${NC}\n" "$border_line"
    _center_line "" ""
    _center_line "███╗   ██╗ ██████╗  ██████╗ ██████╗ ███████╗" ""
    _center_line "████╗  ██║██╔═══██╗██╔═══██╗██╔══██╗██╔════╝" ""
    _center_line "██╔██╗ ██║██║   ██║██║   ██║██████╔╝███████╗" ""
    _center_line "██║╚██╗██║██║   ██║██║   ██║██╔══██╗╚════██║" ""
    _center_line "██║ ╚████║╚██████╔╝╚██████╔╝██████╔╝███████║" ""
    _center_line "╚═╝  ╚═══╝ ╚═════╝  ╚═════╝ ╚═════╝ ╚══════╝" ""
    _center_line "" ""
    local title="  ━━━━━━ Z I V P N  U D P  P A N E L ━━━━━━   "
    _center_line "$title" "${Y}${BOLD}"
    local subtitle=" @ARDVAK == https://t.me/noobsvpn  -  v${PANEL_VERSION} "
    _center_line "$subtitle" "${DIM}"
    printf "  ${C}╚%s╝${NC}\n" "$border_line"
}

_format_cell() {
    local label="$1" value="$2" label_color="$3" value_color="$4"
    local label_len=${#label} value_len=${#value}
    local max_value_len=$(( 30 - label_len - 1 ))
    (( max_value_len < 0 )) && max_value_len=0
    if (( value_len > max_value_len )); then
        value="${value:0:$((max_value_len-1))}…"
        value_len=$(( max_value_len ))
    fi
    local pad_total=$(( 30 - label_len - 1 - value_len ))
    (( pad_total < 0 )) && pad_total=0
    printf "%b" "${label_color}${label}${NC} "
    printf "%b" "${value_color}${value}${NC}"
    printf "%*s" "$pad_total" ""
}

draw_dashboard() {
    ensure_config
    local CNT=$(pwd_count)
    local IP=$(server_ip)
    local PORT=$(get_port)
    local SVC_TXT SVC_COL
    if svc_running; then
        SVC_TXT="RUNNING"; SVC_COL="${G}"
    else
        SVC_TXT="STOPPED"; SVC_COL="${R}"
    fi
    local srv_cell ip_cell port_cell relay_cell obfs_cell users_cell
    srv_cell=$(_format_cell "Service" "$SVC_TXT"      "${DW}" "${SVC_COL}")
    ip_cell=$(_format_cell  "IP"      "$IP"            "${DW}" "${W}")
    port_cell=$(_format_cell "Port"   "${PORT}/udp"    "${DW}" "${Y}")
    relay_cell=$(_format_cell "Relay" "6000-19999/udp" "${DW}" "${W}")
    obfs_cell=$(_format_cell "Obfs"   "zivpn"          "${DW}" "${C}")
    users_cell=$(_format_cell "Users" "${CNT} active"   "${DW}" "${Y}")
    local sep="──────────────────────────────"
    echo -e "\n  ${DIM}┌${sep}┬${sep}┐${NC}"
    printf "  ${DIM}│${NC}%s${DIM}│${NC}%s${DIM}│${NC}\n" "$srv_cell" "$ip_cell"
    printf "  ${DIM}│${NC}%s${DIM}│${NC}%s${DIM}│${NC}\n" "$port_cell" "$relay_cell"
    printf "  ${DIM}│${NC}%s${DIM}│${NC}%s${DIM}│${NC}\n" "$obfs_cell" "$users_cell"
    echo -e "  ${DIM}└${sep}┴${sep}┘${NC}\n"
}

section() {
  local col="$1" title="$2"
  echo -e "  ${col}┌──────────────────────────────────────────────────────┐${NC}"
  printf  "  ${col}│${NC}  ${BOLD}${W}%-52s${NC}${col}│${NC}\n" "$title"
  echo -e "  ${col}└──────────────────────────────────────────────────────┘${NC}"
  echo ""
}

# ═══════════════════════════════════════════════════════════════
#  SCREEN FUNCTIONS
# ═══════════════════════════════════════════════════════════════
screen_list() {
  draw_header; draw_dashboard
  section "$B" "👥   USER / PASSWORD LIST"
  mapfile -t PWDS < <(get_passwords)
  if [ ${#PWDS[@]} -eq 0 ]; then
    echo -e "  ${DIM}  No users configured. Use [2] to add.${NC}"
  else
    echo -e "  ${DIM}  Users:${NC}"
    local i=1
    for p in "${PWDS[@]}"; do
      echo -e "  ${G}  $i.${NC} ${W}$p${NC}"
      ((i++))
    done
  fi
  press_any
}

screen_add_user() {
  draw_header; draw_dashboard
  section "$G" "➕   ADD NEW USER"
  echo -ne "  ${DW}Password${NC}: "
  read -r new_pass
  new_pass=$(echo "$new_pass" | xargs)
  [ -z "$new_pass" ] && { result_err "Empty password"; press_any; return; }
  echo -ne "  ${DW}Device limit (0=unlimited)${NC}: "
  read -r dev_limit
  dev_limit=${dev_limit:-0}
  echo -ne "  ${DW}Data limit GB (0=unlimited)${NC}: "
  read -r data_gb
  data_gb=${data_gb:-0}
  echo -ne "  ${DW}Validity days (0=unlimited)${NC}: "
  read -r valid_days
  valid_days=${valid_days:-0}
  add_password "$new_pass" "$dev_limit" "$data_gb" "$valid_days"
  echo "$new_pass|permanent|unlimited|$(date +%Y-%m-%d)" >> "$DB_FILE"
  reload_svc
  result_ok "User added: $new_pass"
  press_any
}

screen_bulk_add() {
  draw_header; draw_dashboard
  section "$G" "📋   BULK ADD"
  echo -ne "  ${DW}Passwords (comma separated)${NC}: "
  read -r input
  [ -z "$input" ] && { result_err "No input"; press_any; return; }
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
  result_ok "$added user(s) added"
  press_any
}

screen_trial_user() {
  draw_header; draw_dashboard
  section "$Y" "⏱   TRIAL USER"
  echo -ne "  ${DW}Duration (minutes, 1-60)${NC}: "
  read -r mins
  if ! [[ "$mins" =~ ^[0-9]+$ ]] || [ "$mins" -lt 1 ] || [ "$mins" -gt 60 ]; then
    result_err "Invalid duration"; press_any; return
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
  result_ok "Trial user: $pass (expires in $mins min)"
  press_any
}

screen_remove_user() {
  draw_header; draw_dashboard
  section "$R" "🗑   REMOVE USER"
  mapfile -t PWDS < <(get_passwords)
  [ ${#PWDS[@]} -eq 0 ] && { echo -e "  ${DIM}No users.${NC}"; press_any; return; }
  local i=1
  for p in "${PWDS[@]}"; do
    echo -e "  ${G}  $i.${NC} ${W}$p${NC}"
    ((i++))
  done
  echo -ne "  ${DW}Delete # (0=cancel)${NC}: "
  read -r sel
  [ "$sel" = "0" ] && return
  if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -le "${#PWDS[@]}" ]; then
    remove_password "${PWDS[$((sel-1))]}"
    reload_svc
    result_ok "Removed"
  else
    result_err "Invalid"
  fi
  press_any
}

screen_clear_all() {
  draw_header; draw_dashboard
  section "$R" "⚠   CLEAR ALL"
  if confirm_yn "Delete ALL users?"; then
    clear_passwords
    > "$DB_FILE"
    reload_svc
    result_ok "All cleared"
  fi
  press_any
}

screen_start() {
  draw_header; draw_dashboard
  systemctl start zivpn 2>/dev/null
  sleep 1
  svc_running && result_ok "ZIVPN running" || result_err "Failed to start"
  press_any
}

screen_stop() {
  draw_header; draw_dashboard
  systemctl stop zivpn 2>/dev/null
  result_ok "ZIVPN stopped"
  press_any
}

screen_restart() {
  draw_header; draw_dashboard
  systemctl restart zivpn 2>/dev/null
  sleep 2
  svc_running && result_ok "Restarted" || result_err "Failed"
  press_any
}

screen_monitor() {
  draw_header; draw_dashboard
  section "$Y" "📡   MONITOR"
  local PORT=$(get_port)
  conntrack -L -p udp -n 2>/dev/null | grep "dport=$PORT" | head -20
  press_any
}

screen_change_port() {
  draw_header; draw_dashboard
  section "$C" "🔌   CHANGE PORT"
  echo -ne "  ${DW}New port${NC}: "
  read -r np
  if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1024 ] && [ "$np" -le 65535 ]; then
    jq --arg p ":$np" '.listen = $p' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
    reload_svc
    result_ok "Port changed to $np"
  else
    result_err "Invalid port"
  fi
  press_any
}

screen_about() {
  draw_header
  section "$C" "ℹ   ABOUT"
  echo -e "  ${W}  Version: $PANEL_VERSION${NC}"
  echo -e "  ${W}  Repo: github.com/autobot-sys/ZIV-WEB${NC}"
  press_any
}

# ═══════════════════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════════════════
main_menu() {
  ensure_config
  while true; do
    draw_header
    draw_dashboard
    echo ""
    echo -e "  ${G}  [1]${NC} List Users        ${G}  [2]${NC} Add User"
    echo -e "  ${G}  [3]${NC} Bulk Add          ${Y}  [4]${NC} Trial User"
    echo -e "  ${R}  [5]${NC} Remove User       ${R}  [6]${NC} Clear All"
    echo -e "  ${G}  [7]${NC} Start ZIVPN       ${R}  [8]${NC} Stop ZIVPN"
    echo -e "  ${Y}  [9]${NC} Restart ZIVPN"
    echo -e "  ${C}  [m]${NC} Monitor           ${C}  [p]${NC} Change Port"
    echo -e "  ${W}  [i]${NC} About             ${R}  [q]${NC} Exit"
    echo ""
    echo -ne "  ${C}▶  ${NC}Select: "
    read -r choice
    case "$choice" in
      1) screen_list ;;
      2) screen_add_user ;;
      3) screen_bulk_add ;;
      4) screen_trial_user ;;
      5) screen_remove_user ;;
      6) screen_clear_all ;;
      7) screen_start ;;
      8) screen_stop ;;
      9) screen_restart ;;
      m|M) screen_monitor ;;
      p|P) screen_change_port ;;
      i|I) screen_about ;;
      q|Q|0) clear; echo -e "\n  ${C}  ★  Goodbye!  ★${NC}\n"; exit 0 ;;
      *) echo -e "\n  ${R}  Invalid option${NC}"; sleep 1 ;;
    esac
  done
}

main_menu
