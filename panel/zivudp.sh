#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  NOOBS ZIVPN UDP PANEL  —  zivudp
#  Repo    : https://github.com/autobot-sys/ZIV-WEB
#  Version : 2.2.0 (terminal panel: device/data limits removed)
# ═══════════════════════════════════════════════════════════════

PANEL_VERSION="2.2.0"
CONFIG_FILE="/etc/zivpn/config.json"
DB_FILE="/etc/zivpn/users.db"
META_FILE="/etc/zivpn/users_meta.json"
BIN_PATH="/usr/local/bin/zivpn"
PANEL_PATH="/usr/local/bin/zivudp"
WEBPANEL_PY="/etc/zivpn/webpanel.py"
WEBPANEL_CONF="/etc/zivpn/webpanel.conf"
WEBPANEL_SVC="/etc/systemd/system/zivpanel.service"
REPO_RAW="https://raw.githubusercontent.com/autobot-sys/ZIV-WEB/main"

# Colours
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'
M='\033[1;35m'; C='\033[1;36m'; W='\033[1;37m'; DR='\033[0;31m'
DG='\033[0;32m'; DY='\033[0;33m'; DC='\033[0;36m'; DW='\033[0;37m'
DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
C='\e[36m'          # cyan
BOLD='\e[1m'
Y='\e[33m'          # yellow
DIM='\e[2m'
NC='\e[0m'          # reset

draw_header

# Root check
[ "$EUID" -ne 0 ] && { echo -e "\n  ${R}✘  Run as root: sudo zivudp${NC}\n"; exit 1; }

# Ensure required tools are installed
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

# ════════════════════════════════════════════════════════════════
#  CORE HELPERS — CONFIG & METADATA
# ════════════════════════════════════════════════════════════════

svc_running() { systemctl is-active --quiet zivpn; }

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
  if ! jq -e '.auth' "$CONFIG_FILE" &>/dev/null; then
    jq '. + {"auth": {"mode": "passwords", "config": []}}' "$CONFIG_FILE" > /tmp/zv_fix.json && mv /tmp/zv_fix.json "$CONFIG_FILE"
  fi
  if ! jq -e '.auth.config' "$CONFIG_FILE" &>/dev/null; then
    jq '.auth.config = []' "$CONFIG_FILE" > /tmp/zv_fix.json && mv /tmp/zv_fix.json "$CONFIG_FILE"
  fi
  [ ! -f "$META_FILE" ] && echo '{}' > "$META_FILE"
  [ ! -f "$DB_FILE" ] && touch "$DB_FILE"
}

# Get all passwords (plain list)
get_passwords() {
  ensure_config
  jq -r '.auth.config[]' "$CONFIG_FILE" 2>/dev/null
}

# Add a password + metadata with expiry only (no device/data limits)
add_password() {
  local pass="$1"
  local valid_days="$2"
  ensure_config
  jq --arg p "$pass" '.auth.config += [$p]' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"

  # Metadata now contains only expiry and creation time.
  python3 -c "
import json, time
META='$META_FILE'
meta = json.load(open(META)) if __import__('os').path.exists(META) else {}
if '$pass' not in meta:
    expiry = None
    if $valid_days > 0:
        expiry = time.time() + $valid_days * 86400
    meta['$pass'] = {
        'expiry': expiry,
        'created_at': time.time()
    }
    json.dump(meta, open(META, 'w'), indent=2)
"
}

# Remove password and metadata
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
  # Clean any legacy iptables chains (from older versions that had data limits)
  delete_iptables_chain "$pass"
}

# Clear all users
clear_passwords() {
  ensure_config
  jq '.auth.config = []' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
  echo '{}' > "$META_FILE"
  # Remove any legacy per-user chains
  for chain in $(iptables -S 2>/dev/null | awk '/^-N ZIV_USER_/{print $2}'); do
    delete_iptables_chain "${chain#ZIV_USER_}"
  done
}

# Legacy cleanup function (kept only to remove old chains from previous versions)
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

# ════════════════════════════════════════════════════════════════
#  HEADER & DASHBOARD
# ════════════════════════════════════════════════════════════════

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
    local visible_length label_len=${#label} value_len=${#value}
    local max_value_len pad_total space_count pad_right
    max_value_len=$(( 30 - label_len - 1 ))
    (( max_value_len < 0 )) && max_value_len=0
    if (( value_len > max_value_len )); then
        value="${value:0:$((max_value_len-1))}…"
        value_len=$(( max_value_len ))
    fi
    visible_length=$(( label_len + 1 + value_len ))
    pad_total=$(( 30 - visible_length ))
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

# ════════════════════════════════════════════════════════════════
#  [1]  LIST USERS (expiry only)
# ════════════════════════════════════════════════════════════════
screen_list() {
  draw_header; draw_dashboard
  section "$B" "👥   USER / PASSWORD LIST"

  mapfile -t PWDS < <(get_passwords)
  if [ ${#PWDS[@]} -eq 0 ]; then
    echo -e "  ${DIM}  ┄ No passwords configured. Use [2] to add users. ┄${NC}"
  else
    echo -e "  ${DIM}  ┌──────┬──────────────────────────┬─────────────┐${NC}"
    printf  "  ${DIM}  │${NC}  ${G}%-4s${DIM}│${NC}  ${W}%-24s${DIM}│${NC}  %-11s${DIM}│${NC}\n" "No" "Password" "Expiry (days)"
    echo -e "  ${DIM}  ├──────┼──────────────────────────┼─────────────┤${NC}"
    local i=1
    for p in "${PWDS[@]}"; do
      local expiry_days
      expiry_days=$(python3 -c "import json,time; d=json.load(open('$META_FILE')); e=d.get('$p',{}).get('expiry'); print(max(0,int((e-time.time())/86400)) if e else '∞')" 2>/dev/null)
      [ -z "$expiry_days" ] && expiry_days="∞"
      printf "  ${DIM}  │${NC}  ${G}%-4s${DIM}│${NC}  ${W}%-24s${DIM}│${NC}  %-11s${DIM}│${NC}\n" "$i" "${p:0:24}" "$expiry_days"
      ((i++))
    done
    echo -e "  ${DIM}  └──────┴──────────────────────────┴─────────────┘${NC}"
    echo -e "\n  ${DIM}  Total:${NC} ${Y}${#PWDS[@]} user(s)${NC}"
  fi

  local IP=$(server_ip)
  local PORT=$(get_port)
  echo ""
  echo -e "  ${C}  ┌─────────── Client App Connection Info ──────────────┐${NC}"
  printf  "  ${C}  │${NC}  ${DW}Server IP :${NC}  ${W}%-40s${C}│${NC}\n" "$IP"
  printf  "  ${C}  │${NC}  ${DW}Port      :${NC}  ${W}%-40s${C}│${NC}\n" "Any port 6000–19999"
  printf  "  ${C}  │${NC}  ${DW}Password  :${NC}  ${W}%-40s${C}│${NC}\n" "One of the above"
  printf  "  ${C}  │${NC}  ${DW}Obfs      :${NC}  ${W}%-40s${C}│${NC}\n" "zivpn"
  echo -e "  ${C}  └──────────────────────────────────────────────────────┘${NC}"
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [2]  ADD USER (validity only)
# ════════════════════════════════════════════════════════════════
screen_add_user() {
  draw_header; draw_dashboard
  section "$G" "➕   ADD NEW USER"

  echo -ne "  ${DW}Password${NC}  ${DIM}▶${NC} "
  read -r new_pass
  new_pass=$(echo "$new_pass" | xargs)
  [ -z "$new_pass" ] && { result_err "Password cannot be empty."; press_any; return; }

  if get_passwords | grep -qxF "$new_pass"; then
    result_warn "Password '${W}$new_pass${Y}' already exists."; press_any; return
  fi

  echo -ne "  ${DW}Validity (days, 0 = unlimited)${NC}  ${DIM}▶${NC} "
  read -r valid_days
  valid_days=${valid_days:-0}

  add_password "$new_pass" "$valid_days"
  echo "$new_pass|permanent|unlimited|$(date +%Y-%m-%d)" >> "$DB_FILE"
  reload_svc

  local IP=$(server_ip)
  local exp_disp="unlimited"
  [ "$valid_days" != "0" ] && exp_disp="${valid_days} days"

  echo ""
  echo -e "  ${G}  ╔═══════════════════════════════════════════════╗${NC}"
  echo -e "  ${G}  ║     🎉  USER ADDED SUCCESSFULLY  🎉           ║${NC}"
  echo -e "  ${G}  ╠═══════════════════════════════════════════════╣${NC}"
  printf  "  ${G}  ║${NC}  ${DW}Password  :${NC}  ${W}%-31s${G}  ║${NC}\n" "$new_pass"
  printf  "  ${G}  ║${NC}  ${DW}Expiry     :${NC}  ${W}%-31s${G}  ║${NC}\n" "$exp_disp"
  printf  "  ${G}  ║${NC}  ${DW}Server IP  :${NC}  ${W}%-31s${G}  ║${NC}\n" "$IP"
  echo -e "  ${G}  ╚═══════════════════════════════════════════════╝${NC}"

  if [ "$valid_days" != "0" ] && ! webpanel_running; then
    echo -e "\n  ${Y}  ⚠  Expiry limits are only enforced while the Web Panel${NC}"
    echo -e "  ${Y}     service is running. Install/start it from the Web Panel menu [w].${NC}"
  fi
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [3]  BULK ADD (no limits)
# ════════════════════════════════════════════════════════════════
screen_bulk_add() {
  draw_header; draw_dashboard
  section "$G" "📋   BULK ADD PASSWORDS"

  echo -e "  ${DIM}  Enter passwords separated by commas.${NC}"
  echo -ne "  ${DW}Passwords${NC}  ${DIM}▶${NC} "
  read -r input
  [ -z "$input" ] && { result_err "No input given."; press_any; return; }

  IFS=',' read -r -a incoming <<< "$input"
  local added=0 skipped=0
  for np in "${incoming[@]}"; do
    np=$(echo "$np" | xargs)
    [ -z "$np" ] && continue
    if get_passwords | grep -qxF "$np"; then
      ((skipped++))
    else
      add_password "$np" 0
      echo "$np|permanent|unlimited|$(date +%Y-%m-%d)" >> "$DB_FILE"
      ((added++))
    fi
  done
  reload_svc
  result_ok "$added password(s) added."
  [ $skipped -gt 0 ] && echo -e "  ${Y}  ⊘  $skipped duplicate(s) skipped.${NC}"
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [4]  TRIAL USER (auto-expires)
# ════════════════════════════════════════════════════════════════
screen_trial_user() {
  draw_header; draw_dashboard
  section "$Y" "⏱   CREATE TRIAL USER"

  echo -ne "  ${DW}Duration in minutes${NC}  ${DIM}(1–60)${NC}  ${DIM}▶${NC} "
  read -r mins
  if ! [[ "$mins" =~ ^[0-9]+$ ]] || [ "$mins" -lt 1 ] || [ "$mins" -gt 60 ]; then
    result_err "Enter a number between 1 and 60."; press_any; return
  fi

  local pass="trial_$(openssl rand -hex 3)"
  add_password "$pass" 0
  python3 -c "
import json, time
META='$META_FILE'
meta = json.load(open(META))
if '$pass' in meta:
    meta['$pass']['expiry'] = time.time() + $mins * 60
    json.dump(meta, open(META, 'w'), indent=2)
"
  reload_svc

  local IP=$(server_ip)
  echo ""
  echo -e "  ${Y}  ╔═══════════════════════════════════════════════╗${NC}"
  echo -e "  ${Y}  ║     ⏱  TRIAL USER CREATED                    ║${NC}"
  echo -e "  ${Y}  ╠═══════════════════════════════════════════════╣${NC}"
  printf  "  ${Y}  ║${NC}  ${DW}Password  :${NC}  ${W}%-31s${Y}  ║${NC}\n" "$pass"
  printf  "  ${Y}  ║${NC}  ${DW}Server IP :${NC}  ${W}%-31s${Y}  ║${NC}\n" "$IP"
  printf  "  ${Y}  ║${NC}  ${DW}Duration  :${NC}  ${W}%-31s${Y}  ║${NC}\n" "$mins minutes"
  printf  "  ${Y}  ║${NC}  ${DW}Obfs      :${NC}  ${W}%-31s${Y}  ║${NC}\n" "zivpn"
  echo -e "  ${Y}  ╚═══════════════════════════════════════════════╝${NC}"
  if ! webpanel_running; then
    echo -e "\n  ${Y}  ⚠  Web panel isn't running -- this trial will only auto-expire${NC}"
    echo -e "  ${Y}     if this menu stays open for the full $mins minute(s).${NC}"
  fi
  echo -e "\n  ${DIM}  Auto-expiring in $mins minutes...${NC}"

  (
    sleep $((mins * 60))
    remove_password "$pass"
    systemctl restart zivpn 2>/dev/null
  ) & disown
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [5]  REMOVE USER
# ════════════════════════════════════════════════════════════════
screen_remove_user() {
  draw_header; draw_dashboard
  section "$R" "🗑   REMOVE A USER"

  mapfile -t PWDS < <(get_passwords)
  [ ${#PWDS[@]} -eq 0 ] && { echo -e "  ${DIM}  No users to remove.${NC}"; press_any; return; }

  echo -e "  ${DIM}  ┌──────┬────────────────────────────────────────────┐${NC}"
  local i=1
  for p in "${PWDS[@]}"; do
    printf "  ${DIM}  │${NC}  ${G}%-4s${DIM}│${NC}  ${W}%-44s${DIM}│${NC}\n" "$i" "$p"
    ((i++))
  done
  echo -e "  ${DIM}  └──────┴────────────────────────────────────────────┘${NC}\n"
  echo -ne "  ${DW}Delete #${NC}  ${DIM}(0 to cancel)${NC}  ${DIM}▶${NC} "
  read -r sel
  { [ "$sel" = "0" ] || [ -z "$sel" ]; } && return
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -gt "${#PWDS[@]}" ]; then
    result_err "Invalid selection."; press_any; return
  fi

  local removed="${PWDS[$((sel-1))]}"
  remove_password "$removed"
  sed -i "/^${removed}|/d" "$DB_FILE" 2>/dev/null
  reload_svc
  result_ok "User '${W}$removed${G}' removed."
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [6]  BULK REMOVE
# ════════════════════════════════════════════════════════════════
screen_bulk_remove() {
  draw_header; draw_dashboard
  section "$R" "🗑   REMOVE MULTIPLE USERS"

  mapfile -t PWDS < <(get_passwords)
  [ ${#PWDS[@]} -eq 0 ] && { echo -e "  ${DIM}  No users to remove.${NC}"; press_any; return; }

  echo -e "  ${DIM}  ┌──────┬────────────────────────────────────────────┐${NC}"
  local i=1
  for p in "${PWDS[@]}"; do
    printf "  ${DIM}  │${NC}  ${G}%-4s${DIM}│${NC}  ${W}%-44s${DIM}│${NC}\n" "$i" "$p"
    ((i++))
  done
  echo -e "  ${DIM}  └──────┴────────────────────────────────────────────┘${NC}\n"
  echo -e "  ${DIM}  Enter numbers to remove, e.g. ${DW}1,3,5${DIM} or 0 to cancel${NC}"
  echo -ne "  ${DIM}▶${NC} "
  read -r sel_input
  { [ "$sel_input" = "0" ] || [ -z "$sel_input" ]; } && return

  IFS=',' read -r -a sel_arr <<< "$sel_input"
  local cnt=0
  declare -A to_rm
  for s in "${sel_arr[@]}"; do
    s=$(echo "$s" | xargs)
    [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -ge 1 ] && [ "$s" -le "${#PWDS[@]}" ] && to_rm[$((s-1))]=1
  done

  for idx in "${!to_rm[@]}"; do
    remove_password "${PWDS[$idx]}"
    sed -i "/^${PWDS[$idx]}|/d" "$DB_FILE" 2>/dev/null
    ((cnt++))
  done
  reload_svc
  result_ok "$cnt user(s) removed."
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [7]  CLEAR ALL
# ════════════════════════════════════════════════════════════════
screen_clear_all() {
  draw_header; draw_dashboard
  section "$R" "⚠   CLEAR ALL USERS"
  echo -e "  ${R}  This removes EVERY user. All clients disconnect.${NC}\n"
  if confirm_yn "Confirm clear all users?"; then
    clear_passwords
    > "$DB_FILE"
    reload_svc
    result_ok "All users cleared."
  else
    result_warn "Cancelled."
  fi
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [8]  START
# ════════════════════════════════════════════════════════════════
screen_start() {
  draw_header; draw_dashboard
  section "$G" "▶   START ZIVPN"
  if svc_running; then
    result_warn "Already running."
  else
    ensure_config
    echo -e "  ${DIM}  Starting...${NC}"
    systemctl start zivpn
    sleep 2
    if svc_running; then
      result_ok "ZIVPN is now RUNNING."
    else
      result_err "Service failed to start. Logs:"
      echo ""
      journalctl -u zivpn -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    fi
  fi
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [9]  STOP
# ════════════════════════════════════════════════════════════════
screen_stop() {
  draw_header; draw_dashboard
  section "$R" "⏹   STOP ZIVPN"
  if ! svc_running; then
    result_warn "Already stopped."
  else
    systemctl stop zivpn
    sleep 1
    result_ok "ZIVPN stopped."
  fi
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [10]  RESTART
# ════════════════════════════════════════════════════════════════
screen_restart() {
  draw_header; draw_dashboard
  section "$Y" "↺   RESTART ZIVPN"
  echo -e "  ${DIM}  Restarting...${NC}"
  systemctl restart zivpn
  sleep 2
  if svc_running; then
    result_ok "ZIVPN restarted successfully."
  else
    result_err "Service may have crashed. Logs:"
    echo ""
    journalctl -u zivpn -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
  fi
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [U]  AUTO-UPDATE
# ════════════════════════════════════════════════════════════════
screen_autoupdate() {
  draw_header; draw_dashboard
  section "$M" "⟳   AUTO-UPDATE FROM GITHUB"
  echo -e "  ${DIM}  Pulling latest scripts from:${NC}"
  echo -e "  ${W}  $REPO_RAW${NC}\n"
  confirm_yn "Proceed with update?" || { result_warn "Cancelled."; press_any; return; }
  echo ""
  local ERRS=0
  local TMP=$(mktemp -d)

  echo -ne "  ${C}⟳${NC}  Panel (zivudp.sh)..."
  if wget -q --timeout=20 "$REPO_RAW/panel/zivudp.sh" -O "$TMP/zivudp.sh" && [ -s "$TMP/zivudp.sh" ]; then
    cp "$TMP/zivudp.sh" "$PANEL_PATH" && chmod +x "$PANEL_PATH"
    echo -e "  ${G}✔${NC}"
  else
    echo -e "  ${R}✘ failed${NC}"; ((ERRS++))
  fi

  echo -ne "  ${C}⟳${NC}  Web panel (webpanel.py)..."
  if wget -q --timeout=20 "$REPO_RAW/panel/webpanel.py" -O "$TMP/webpanel.py" && [ -s "$TMP/webpanel.py" ]; then
    cp "$TMP/webpanel.py" "$WEBPANEL_PY"
    echo -e "  ${G}✔${NC}"
  else
    echo -e "  ${R}✘ failed${NC}"; ((ERRS++))
  fi

  local ARCH=$(uname -m)
  local BIN_ARCH="amd64"
  case $ARCH in aarch64|arm64) BIN_ARCH="arm64";; esac
  echo -ne "  ${C}⟳${NC}  Binary (zivpn)..."
  if wget -q --timeout=30 "https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-$BIN_ARCH" -O "$TMP/zivpn_new" && [ -s "$TMP/zivpn_new" ]; then
    if cmp -s "$TMP/zivpn_new" "$BIN_PATH" 2>/dev/null; then
      echo -e "  ${DIM}already latest${NC}"
    else
      systemctl stop zivpn 2>/dev/null
      cp "$TMP/zivpn_new" "$BIN_PATH" && chmod +x "$BIN_PATH"
      systemctl start zivpn 2>/dev/null
      echo -e "  ${G}✔ updated${NC}"
    fi
  else
    echo -e "  ${Y}⚠ skipped${NC}"; ((ERRS++))
  fi

  rm -rf "$TMP"
  echo ""
  if [ "$ERRS" -eq 0 ]; then
    result_ok "All components updated."
  else
    result_warn "Updated with $ERRS error(s)."
  fi
  press_any
  exec "$PANEL_PATH"
}

# ════════════════════════════════════════════════════════════════
#  [M]  MONITOR (live connections only)
# ════════════════════════════════════════════════════════════════
screen_monitor() {
  draw_header; draw_dashboard
  section "$Y" "📡   LIVE CONNECTION MONITOR"
  local PORT=$(get_port)
  echo -e "  ${W}  UDP peers talking to port $PORT:${NC}\n"

  local PEERS=""
  if command -v conntrack &>/dev/null; then
    PEERS=$(conntrack -L -p udp -n 2>/dev/null | python3 -c "
import sys, re
port = $PORT
for line in sys.stdin:
    pairs = re.findall(r'(src|dst|sport|dport)=(\S+)', line)
    src_idx = [i for i, (k, _) in enumerate(pairs) if k == 'src']
    if len(src_idx) < 2:
        continue
    orig = dict(pairs[:src_idx[1]])
    reply = dict(pairs[src_idx[1]:])
    try:
        if port in (int(orig.get('dport', -1)), int(reply.get('sport', -1))):
            print(f\"{orig.get('src')}:{orig.get('sport')}  ->  server:{port}\")
    except ValueError:
        pass
" 2>/dev/null)
  fi
  if [ -z "$PEERS" ]; then
    PEERS=$(ss -anu 2>/dev/null | grep ":$PORT" | awk '{print $5"  ->  "$6}')
  fi

  if [ -z "$PEERS" ]; then
    echo -e "  ${DIM}  ┄ No active connections ┄${NC}"
  else
    echo -e "  ${DIM}  ┌─────────────────────────────────────────────────────────┐${NC}"
    echo "$PEERS" | sort -u | while IFS= read -r line; do
      printf "  ${DIM}  │${NC}  ${W}%-55s${NC}${DIM}│${NC}\n" "$line"
    done
    echo -e "  ${DIM}  └─────────────────────────────────────────────────────────┘${NC}"
  fi

  echo -e "\n  ${W}  Recent logs (last 20):${NC}\n"
  journalctl -u zivpn -n 20 --no-pager 2>/dev/null | sed 's/^/    /' \
    | sed "s/[Ee][Rr][Rr][Oo][Rr]/${R}&${NC}/g" \
    | sed "s/[Cc]onnect\|[Aa]uth/${G}&${NC}/g" || echo -e "  ${DIM}  No logs.${NC}"
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [P]  CHANGE PORT
# ════════════════════════════════════════════════════════════════
screen_change_port() {
  draw_header; draw_dashboard
  section "$C" "🔌   CHANGE LISTEN PORT"
  local curr=$(get_port)
  echo -e "  ${DIM}  Current port:${NC}  ${W}$curr/udp${NC}\n"
  echo -ne "  ${DW}New port${NC}  ${DIM}(1024–65535, 0 to cancel)${NC}  ${DIM}▶${NC} "
  read -r np
  { [ "$np" = "0" ] || [ -z "$np" ]; } && return
  if ! [[ "$np" =~ ^[0-9]+$ ]] || [ "$np" -lt 1024 ] || [ "$np" -gt 65535 ]; then
    result_err "Invalid port."; press_any; return
  fi
  jq --arg p ":$np" '.listen = $p' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
  iptables -I INPUT -p udp --dport "$np" -j ACCEPT 2>/dev/null
  reload_svc
  result_ok "Port changed to ${W}$np${G}."
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [C]  CONFIG CHECK / REPAIR
# ════════════════════════════════════════════════════════════════
screen_config_check() {
  draw_header; draw_dashboard
  section "$C" "🔧   CONFIG CHECK & REPAIR"
  echo -e "  ${W}  Current config.json:${NC}\n"
  cat "$CONFIG_FILE" 2>/dev/null | sed 's/^/    /' \
    | sed "s/\"listen\"/${G}&${NC}/g" \
    | sed "s/\"cert\"\|\"key\"\|\"obfs\"/${Y}&${NC}/g" \
    | sed "s/\"auth\"/${C}&${NC}/g"
  echo ""
  echo -e "  ${DIM}  Checking required fields...${NC}"
  local ok=1
  for field in listen cert key obfs auth; do
    if jq -e ".$field" "$CONFIG_FILE" &>/dev/null; then
      echo -e "  ${G}  ✔ $field${NC}"
    else
      echo -e "  ${R}  ✘ $field${NC}"; ok=0
    fi
  done
  if jq -e '.auth.config' "$CONFIG_FILE" &>/dev/null; then
    echo -e "  ${G}  ✔ auth.config${NC}"
  else
    echo -e "  ${R}  ✘ auth.config${NC}"; ok=0
  fi
  [ -f "/etc/zivpn/zivpn.crt" ] && echo -e "  ${G}  ✔ cert file${NC}" || echo -e "  ${R}  ✘ cert file missing${NC}"
  [ -f "/etc/zivpn/zivpn.key" ] && echo -e "  ${G}  ✔ key file${NC}"  || echo -e "  ${R}  ✘ key file missing${NC}"

  if [ "$ok" -eq 0 ]; then
    echo ""
    if confirm_yn "Config has errors. Auto-repair now?"; then
      ensure_config
      local current_passwords=$(jq -c '[.auth.config // [] | .[]]' "$CONFIG_FILE" 2>/dev/null || echo "[]")
      cat > "$CONFIG_FILE" << CONF
{
  "listen": ":5667",
  "cert": "/etc/zivpn/zivpn.crt",
  "key": "/etc/zivpn/zivpn.key",
  "obfs": "zivpn",
  "auth": {
    "mode": "passwords",
    "config": $current_passwords
  }
}
CONF
      reload_svc
      result_ok "Config repaired."
    fi
  else
    echo ""
    result_ok "Config looks healthy."
  fi
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [I]  ABOUT
# ════════════════════════════════════════════════════════════════
screen_about() {
  draw_header
  echo ""
  section "$C" "ℹ   ABOUT  NOOBS ZIVPN UDP PANEL"
  echo -e "  ${DIM}  ┌─────────────────────────┬──────────────────────────────┐${NC}"
  printf  "  ${DIM}  │${NC}  %-23s  ${DIM}│${NC}  ${W}%-28s${DIM}│${NC}\n" "Panel Version"    "$PANEL_VERSION"
  printf  "  ${DIM}  │${NC}  %-23s  ${DIM}│${NC}  ${W}%-28s${DIM}│${NC}\n" "Repository"       "github.com/autobot-sys/ZIV-WEB"
  printf  "  ${DIM}  │${NC}  %-23s  ${DIM}│${NC}  ${W}%-28s${DIM}│${NC}\n" "Protocol"         "ZIVPN UDP"
  printf  "  ${DIM}  │${NC}  %-23s  ${DIM}│${NC}  ${W}%-28s${DIM}│${NC}\n" "Obfs Key"         "zivpn"
  printf  "  ${DIM}  │${NC}  %-23s  ${DIM}│${NC}  ${W}%-28s${DIM}│${NC}\n" "Auth Mode"        "auth.passwords"
  printf  "  ${DIM}  │${NC}  %-23s  ${DIM}│${NC}  ${W}%-28s${DIM}│${NC}\n" "Binary"           "/usr/local/bin/zivpn"
  printf  "  ${DIM}  │${NC}  %-23s  ${DIM}│${NC}  ${W}%-28s${DIM}│${NC}\n" "Config"           "/etc/zivpn/config.json"
  printf  "  ${DIM}  │${NC}  %-23s  ${DIM}│${NC}  ${W}%-28s${DIM}│${NC}\n" "Panel Command"    "zivudp"
  printf  "  ${DIM}  │${NC}  %-23s  ${DIM}│${NC}  ${W}%-28s${DIM}│${NC}\n" "Original Creator" "Zahid Islam"
  printf  "  ${DIM}  │${NC}  %-23s  ${DIM}│${NC}  ${W}%-28s${DIM}│${NC}\n" "Panel by"         "PowerMX / autobot-sys"
  echo -e "  ${DIM}  └─────────────────────────┴──────────────────────────────┘${NC}"
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [W]  WEB PANEL (install / manage)
# ════════════════════════════════════════════════════════════════
webpanel_running() { systemctl is-active --quiet zivpanel 2>/dev/null; }
webpanel_get_port() {
  python3 -c "import json; d=json.load(open('$WEBPANEL_CONF')); print(d.get('port',8080))" 2>/dev/null || echo 8080
}
webpanel_write_service() {
  local port="$1"
  mkdir -p /etc/systemd/system
  cat > "$WEBPANEL_SVC" << UNIT
[Unit]
Description=NOOBS ZIVPN Web Panel
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $WEBPANEL_PY $port
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}

install_webpanel() {
  draw_header
  section "$M" "🌐  INSTALL / UPDATE WEB PANEL"
  echo -ne "  ${DW}Web panel port${NC} [8080]: "
  read -r wp_port
  wp_port=${wp_port:-8080}
  echo -ne "  ${DW}Admin password${NC} [admin]: "
  read -r wp_pass
  wp_pass=${wp_pass:-admin}

  wget -q --timeout=20 "$REPO_RAW/panel/webpanel.py" -O "$WEBPANEL_PY"
  if [ ! -s "$WEBPANEL_PY" ]; then
    result_err "Download failed"
    press_any
    return
  fi

  python3 -c "
import json, hashlib
c={'port':$wp_port,'pass_hash':hashlib.sha256('$wp_pass'.encode()).hexdigest()}
json.dump(c,open('$WEBPANEL_CONF','w'),indent=2)
"
  [ -f "$META_FILE" ] || echo '{}' > "$META_FILE"

  if systemctl list-unit-files 2>/dev/null | grep -q '^zivmon\.service'; then
    echo -e "  ${DIM}Retiring legacy zivmon monitor (superseded by the web panel's own loop)...${NC}"
    systemctl stop zivmon 2>/dev/null
    systemctl disable zivmon 2>/dev/null
    rm -f /etc/systemd/system/zivmon.service /usr/local/bin/zivmon
    systemctl daemon-reload
  fi

  webpanel_write_service "$wp_port"
  systemctl daemon-reload
  systemctl enable zivpanel
  systemctl restart zivpanel

  sleep 2
  if webpanel_running; then
    echo -e "  ${G}✔ zivpanel is running — expiry is enforced automatically.${NC}"
  else
    echo -e "  ${Y}⚠ zivpanel failed to start; check: journalctl -u zivpanel -n 30${NC}"
  fi

  iptables -I INPUT -p tcp --dport "$wp_port" -j ACCEPT 2>/dev/null
  local IP=$(server_ip)
  echo ""
  echo -e "  ${G}  ╔═══════════════════════════════════════════════╗${NC}"
  echo -e "  ${G}  ║     🌐  WEB PANEL INSTALLED  ✔               ║${NC}"
  echo -e "  ${G}  ╠═══════════════════════════════════════════════╣${NC}"
  printf  "  ${G}  ║${NC}  ${DW}URL      :${NC}  ${C}%-31s${G}  ║${NC}\n" "http://${IP}:${wp_port}"
  printf  "  ${G}  ║${NC}  ${DW}Password :${NC}  ${W}%-31s${G}  ║${NC}\n" "$wp_pass"
  echo -e "  ${G}  ╚═══════════════════════════════════════════════╝${NC}"
  press_any
}

screen_webpanel() {
  while true; do
    draw_header
    echo ""
    section "$M" "🌐   WEB PANEL CONTROL"
    local IP=$(server_ip)
    local PORT=$(webpanel_get_port)
    local INSTALLED=0
    [ -f "$WEBPANEL_PY" ] && [ -f "$WEBPANEL_SVC" ] && INSTALLED=1

    if [ $INSTALLED -eq 1 ]; then
      echo -e "  ${DIM}  ┌──────────────────────────────────────────────────┐${NC}"
      if webpanel_running; then
        printf  "  ${DIM}  │${NC}  %-16s ${G}%-16s${NC}  ${DIM}│${NC}\n" "Web Panel" "RUNNING"
      else
        printf  "  ${DIM}  │${NC}  %-16s ${R}%-16s${NC}  ${DIM}│${NC}\n" "Web Panel" "STOPPED"
      fi
      printf    "  ${DIM}  │${NC}  %-16s ${C}%-16s${NC}  ${DIM}│${NC}\n" "URL" "http://${IP}:${PORT}"
      printf    "  ${DIM}  │${NC}  %-16s ${Y}%-16s${NC}  ${DIM}│${NC}\n" "Port" "${PORT}"
      echo -e "  ${DIM}  └──────────────────────────────────────────────────┘${NC}"
    else
      echo -e "  ${Y}  Web panel is not installed yet.${NC}"
    fi

    echo ""
    if [ $INSTALLED -eq 0 ]; then
      echo -e "  ${G}  [1]${NC}  Install Web Panel"
    else
      echo -e "  ${G}  [1]${NC}  Start Web Panel"
      echo -e "  ${R}  [2]${NC}  Stop Web Panel"
      echo -e "  ${Y}  [3]${NC}  Restart Web Panel"
      echo -e "  ${C}  [4]${NC}  Change Web Panel Password"
      echo -e "  ${C}  [5]${NC}  Change Web Panel Port"
      echo -e "  ${R}  [6]${NC}  Uninstall Web Panel"
    fi
    echo -e "  ${DIM}  [0]${NC}  Back to Main Menu"
    echo ""
    echo -ne "  ${M}▶${NC}  Select: "
    read -r wc

    case "$wc" in
      1)
        if [ $INSTALLED -eq 0 ]; then
          install_webpanel
        else
          systemctl start zivpanel
          sleep 1
          webpanel_running && result_ok "Web panel started → http://${IP}:${PORT}" || result_err "Failed to start"
          press_any
        fi ;;
      2) systemctl stop zivpanel; result_ok "Web panel stopped."; press_any ;;
      3) systemctl restart zivpanel; sleep 1; webpanel_running && result_ok "Web panel restarted" || result_err "Restart failed"; press_any ;;
      4)
        echo -ne "  ${DW}New password${NC}: "; read -r new_wp_pass
        new_wp_pass=$(echo "$new_wp_pass" | xargs)
        [ -z "$new_wp_pass" ] && { result_err "Password empty"; press_any; continue; }
        python3 -c "import json, hashlib; d=json.load(open('$WEBPANEL_CONF')); d['pass_hash']=hashlib.sha256('$new_wp_pass'.encode()).hexdigest(); json.dump(d,open('$WEBPANEL_CONF','w'),indent=2)"
        systemctl restart zivpanel
        result_ok "Password updated."
        press_any ;;
      5)
        echo -ne "  ${DW}New port${NC}: "; read -r new_wp_port
        if ! [[ "$new_wp_port" =~ ^[0-9]+$ ]] || [ "$new_wp_port" -lt 1024 ] || [ "$new_wp_port" -gt 65535 ]; then
          result_err "Invalid port"; press_any; continue
        fi
        python3 -c "import json; d=json.load(open('$WEBPANEL_CONF')); d['port']=$new_wp_port; json.dump(d,open('$WEBPANEL_CONF','w'),indent=2)"
        webpanel_write_service "$new_wp_port"
        systemctl restart zivpanel
        iptables -I INPUT -p tcp --dport "$new_wp_port" -j ACCEPT 2>/dev/null
        result_ok "Port changed to ${W}$new_wp_port${G}. Access: http://${IP}:${new_wp_port}"
        press_any ;;
      6)
        if confirm_yn "Uninstall web panel?"; then
          systemctl stop zivpanel zivmon 2>/dev/null
          systemctl disable zivpanel zivmon 2>/dev/null
          rm -f "$WEBPANEL_SVC" "$WEBPANEL_PY" "$WEBPANEL_CONF" /etc/systemd/system/zivmon.service
          rm -f /usr/local/bin/zivmon
          systemctl daemon-reload
          result_ok "Web panel uninstalled."
          press_any; return
        fi ;;
      0) return ;;
      *) echo -e "\n  ${R}  ✘  Invalid option.${NC}"; sleep 1 ;;
    esac
  done
}

# ════════════════════════════════════════════════════════════════
#  MAIN MENU
# ════════════════════════════════════════════════════════════════
main_menu() {
  ensure_config

  local BC='\033[1;36m'

  _mi() {
    local c="$1" k="$2" d="$3" kp
    [[ ${#k} -eq 1 ]] && kp="[${k}] " || kp="[${k}]"
    printf "  ${DIM}║${NC}  ${c}%s${NC}  %-48s${DIM}║${NC}\n" "$kp" "$d"
  }

  _ms() {
    local iw="$1" icon="$2" title="$3"
    local pad=$(( 56 - 2 - iw - 2 - ${#title} ))
    printf "  ${DIM}║${NC}  ${BC}%s  %s${NC}%*s${DIM}║${NC}\n" \
      "$icon" "$title" "$pad" ""
  }

  local TOP BOT EMP LIN
  TOP="  ${DIM}╔════════════════════════════════════════════════════════╗${NC}"
  BOT="  ${DIM}╚════════════════════════════════════════════════════════╝${NC}"
  EMP="  ${DIM}║                                                        ║${NC}"
  LIN="  ${DIM}║  ────────────────────────────────────────────────────  ║${NC}"

  while true; do
    draw_header
    draw_dashboard

    echo -e "$TOP"
    echo -e "$EMP"

    _ms 2 "👥" "USER MANAGEMENT"
    echo -e "$LIN"
    _mi "$G"   1  "List All Users"
    _mi "$G"   2  "Add User  ·  validity days"
    _mi "$G"   3  "Bulk Add"
    _mi "$Y"   4  "Trial User  (auto-expires)"
    _mi "$R"   5  "Remove Single User"
    _mi "$R"   6  "Remove Multiple Users"
    _mi "$R"   7  "Clear ALL Users"
    echo -e "$EMP"

    _ms 2 "🔧" "SERVICE CONTROL"
    echo -e "$LIN"
    _mi "$G"   8  "Start ZIVPN"
    _mi "$R"   9  "Stop  ZIVPN"
    _mi "$Y"  10  "Restart ZIVPN"
    _mi "$M"   u  "Auto-Update from GitHub"
    echo -e "$EMP"

    _ms 2 "🌐" "WEB PANEL"
    echo -e "$LIN"
    _mi "$M"   w  "Web Panel  (install / manage)"
    echo -e "$EMP"

    _ms 2 "🛠" "TOOLS"
    echo -e "$LIN"
    _mi "$C"   m  "Live Monitor"
    _mi "$C"   p  "Change Listen Port"
    _mi "$Y"   c  "Config Check & Repair"
    _mi "$W"   i  "About / Info"
    echo -e "$EMP"

    _mi "$DR"  q  "Exit"
    echo -e "$EMP"
    echo -e "$BOT"

    echo ""
    echo -ne "  ${C}▶  ${NC}Select option: "
    read -r choice

    case "$choice" in
      1)       screen_list         ;;
      2)       screen_add_user     ;;
      3)       screen_bulk_add     ;;
      4)       screen_trial_user   ;;
      5)       screen_remove_user  ;;
      6)       screen_bulk_remove  ;;
      7)       screen_clear_all    ;;
      8)       screen_start        ;;
      9)       screen_stop         ;;
      10)      screen_restart      ;;
      u|U)     screen_autoupdate   ;;
      w|W)     screen_webpanel     ;;
      m|M)     screen_monitor      ;;
      p|P)     screen_change_port  ;;
      c|C)     screen_config_check ;;
      i|I)     screen_about        ;;
      q|Q|0)
        clear
        echo -e "\n  ${C}  ★  NOOBS ZIVPN UDP PANEL — Goodbye!  ★${NC}\n"
        exit 0 ;;
      *)
        echo -e "\n  ${R}  ✘  Invalid option — try again.${NC}\n"
        sleep 1 ;;
    esac
  done
}

main_menu
