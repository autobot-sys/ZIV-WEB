#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  NOOBS ZIVPN UDP PANEL  —  zivudp
#  Repo    : https://github.com/autobot-sys/ZIV-WEB
#  Panel   : PowerMX / autobot-sys
# ═══════════════════════════════════════════════════════════════

PANEL_VERSION="2.1.0"
CONFIG_FILE="/etc/zivpn/config.json"
DB_FILE="/etc/zivpn/users.db"
USERS_JSON="/etc/zivpn/users.json"
TIMEAPI_URL="https://timeapi.io/api/Time/current/zone?timeZone=UTC"
BIN_PATH="/usr/local/bin/zivpn"
PANEL_PATH="/usr/local/bin/zivudp"
REPO_RAW="https://raw.githubusercontent.com/autobot-sys/ZIV-WEB/main"

# ── Colours ──────────────────────────────────────────────────────
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'
M='\033[1;35m'; C='\033[1;36m'; W='\033[1;37m'; DR='\033[0;31m'
DG='\033[0;32m'; DY='\033[0;33m'; DC='\033[0;36m'; DW='\033[0;37m'
DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# ── Root check ───────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && { echo -e "\n  ${R}✘  Run as root: sudo zivudp${NC}\n"; exit 1; }

# ── Ensure jq installed ───────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo -e "${Y}Installing jq...${NC}"
  apt-get install -y jq -qq &>/dev/null
fi


ensure_users_json() {
  mkdir -p /etc/zivpn
  [ -f "$USERS_JSON" ] || echo '{"users":[]}' > "$USERS_JSON"
}

utc_now() {
  curl -fsSL --max-time 5 "$TIMEAPI_URL" 2>/dev/null | jq -r '.dateTime // empty' \
    || date -u +"%Y-%m-%dT%H:%M:%SZ"
}

user_stats() {
  ensure_users_json
  jq -r '
    .users as $u |
    {
      total: ($u|length),
      active: ($u|map(select(.enabled==true))|length),
      expired: ($u|map(select(.enabled==false))|length)
    }' "$USERS_JSON"
}

# ════════════════════════════════════════════════════════════════
#  CORE HELPERS — ALL USE CORRECT auth.config JSON PATH
# ════════════════════════════════════════════════════════════════

svc_running() { systemctl is-active --quiet zivpn; }

# Ensure config has the correct structure before any operation
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
  # Repair config if auth block is missing
  if ! jq -e '.auth' "$CONFIG_FILE" &>/dev/null; then
    jq '. + {"auth": {"mode": "passwords", "config": []}}' "$CONFIG_FILE" > /tmp/zv_fix.json \
      && mv /tmp/zv_fix.json "$CONFIG_FILE"
  fi
  if ! jq -e '.auth.config' "$CONFIG_FILE" &>/dev/null; then
    jq '.auth.config = []' "$CONFIG_FILE" > /tmp/zv_fix.json \
      && mv /tmp/zv_fix.json "$CONFIG_FILE"
  fi
  [ ! -f "$DB_FILE" ] && touch "$DB_FILE"
}

# Get all passwords from correct JSON path
get_passwords() {
  ensure_config
  jq -r '.auth.config[]' "$CONFIG_FILE" 2>/dev/null
}

# Add a password
add_password() {
  local pass="$1"
  ensure_config
  jq --arg p "$pass" '.auth.config += [$p]' "$CONFIG_FILE" > /tmp/zv_tmp.json \
    && mv /tmp/zv_tmp.json "$CONFIG_FILE"
}

# Remove a password
remove_password() {
  local pass="$1"
  ensure_config
  jq --arg p "$pass" '.auth.config -= [$p]' "$CONFIG_FILE" > /tmp/zv_tmp.json \
    && mv /tmp/zv_tmp.json "$CONFIG_FILE"
}

# Clear all passwords
clear_passwords() {
  ensure_config
  jq '.auth.config = []' "$CONFIG_FILE" > /tmp/zv_tmp.json \
    && mv /tmp/zv_tmp.json "$CONFIG_FILE"
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
  echo -e "${C}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║                                                          ║"
  echo "  ║   ███╗   ██╗ ██████╗  ██████╗ ██████╗ ███████╗           ║"
  echo "  ║   ████╗  ██║██╔═══██╗██╔═══██╗██╔══██╗██╔════╝           ║"
  echo "  ║   ██╔██╗ ██║██║   ██║██║   ██║██████╔╝███████╗           ║"
  echo "  ║   ██║╚██╗██║██║   ██║██║   ██║██╔══██╗╚════██║           ║"
  echo "  ║   ██║ ╚████║╚██████╔╝╚██████╔╝██████╔╝███████║           ║"
  echo "  ║   ╚═╝  ╚═══╝ ╚═════╝  ╚═════╝ ╚═════╝ ╚══════╝           ║"
  echo -e "  ║${NC}                                                          ${C}║${NC}"
  echo -e "  ${C}║${NC}  ${Y}${BOLD}  ━━━━━━ Z I V P N  U D P  P A N E L ━━━━━━   ${NC}  ${C}       ║${NC}"
  echo -e "  ${C}║${NC}  ${DIM}     @ARDVAK == https://t.me/noobsvpn  -  v${PANEL_VERSION}${NC}  ${C}   ║${NC}"
  echo -e "${C}  ╚══════════════════════════════════════════════════════════╝${NC}"
}

draw_dashboard() {
  ensure_config
  local CNT; CNT=$(pwd_count)
  local IP; IP=$(server_ip)
  local PORT; PORT=$(get_port)
  local SVC_TXT SVC_COL

  if svc_running; then
    SVC_TXT="RUNNING"; SVC_COL="${G}"
  else
    SVC_TXT="STOPPED"; SVC_COL="${R}"
  fi

  echo ""
  echo -e "${DIM}  ┌──────────────────────────────┬──────────────────────────────┐${NC}"
  printf  "  ${DIM}│${NC}  ${DW}Service${NC}  ${SVC_COL}%-20s${NC}  ${DIM}│${NC}  ${DW}IP${NC}      ${W}%-20s${NC}  ${DIM}│${NC}\n" "$SVC_TXT" "$IP"
  printf  "  ${DIM}│${NC}  ${DW}Port   ${NC}  ${Y}%-20s${NC}  ${DIM}│${NC}  ${DW}Relay${NC}   ${W}%-20s${NC}  ${DIM}│${NC}\n" "${PORT}/udp" "6000-19999/udp"
  printf  "  ${DIM}│${NC}  ${DW}Obfs   ${NC}  ${C}%-20s${NC}  ${DIM}│${NC}  ${DW}Users${NC}   ${Y}%-20s${NC}  ${DIM}│${NC}\n" "zivpn" "${CNT} active"
  echo -e "${DIM}  └──────────────────────────────┴──────────────────────────────┘${NC}"
  echo ""
}

section() {
  local col="$1" title="$2"
  echo -e "  ${col}┌──────────────────────────────────────────────────────┐${NC}"
  printf  "  ${col}│${NC}  ${BOLD}${W}%-52s${NC}${col}│${NC}\n" "$title"
  echo -e "  ${col}└──────────────────────────────────────────────────────┘${NC}"
  echo ""
}

# ════════════════════════════════════════════════════════════════
#  [1]  LIST USERS
# ════════════════════════════════════════════════════════════════
screen_list() {
  draw_header; draw_dashboard
  section "$B" "👥   USER / PASSWORD LIST"

  mapfile -t PWDS < <(get_passwords)
  if [ ${#PWDS[@]} -eq 0 ]; then
    echo -e "  ${DIM}  ┄ No passwords configured. Use [2] to add users. ┄${NC}"
  else
    echo -e "  ${DIM}  ┌──────┬────────────────────────────────────────────┐${NC}"
    echo -e "  ${DIM}  │  No  │  Password                                  │${NC}"
    echo -e "  ${DIM}  ├──────┼────────────────────────────────────────────┤${NC}"
    local i=1
    for p in "${PWDS[@]}"; do
      printf "  ${DIM}  │${NC}  ${G}%-4s${DIM}│${NC}  ${W}%-44s${DIM}│${NC}\n" "$i" "$p"
      ((i++))
    done
    echo -e "  ${DIM}  └──────┴────────────────────────────────────────────┘${NC}"
    echo -e "\n  ${DIM}  Total:${NC} ${Y}${#PWDS[@]} user(s)${NC}"
  fi

  # Client app connection info
  local IP; IP=$(server_ip)
  local PORT; PORT=$(get_port)
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
#  [2]  ADD USER
# ════════════════════════════════════════════════════════════════
screen_add_user() {
  draw_header; draw_dashboard
  section "$G" "➕   ADD NEW USER"

  echo -ne "  ${DW}Password${NC}  ${DIM}▶${NC} "
  read -r new_pass
  new_pass=$(echo "$new_pass" | xargs 2>/dev/null)

  [ -z "$new_pass" ] && { result_err "Password cannot be empty."; press_any; return; }

  # Check duplicate
  if get_passwords | grep -qxF "$new_pass"; then
    result_warn "Password '${W}$new_pass${Y}' already exists."; press_any; return
  fi

  add_password "$new_pass"
  echo "$new_pass|permanent|unlimited|$(date +%Y-%m-%d)" >> "$DB_FILE"
  reload_svc

  local IP; IP=$(server_ip)
  echo ""
  echo -e "  ${G}  ╔═══════════════════════════════════════════════╗${NC}"
  echo -e "  ${G}  ║     🎉  USER ADDED SUCCESSFULLY  🎉           ║${NC}"
  echo -e "  ${G}  ╠═══════════════════════════════════════════════╣${NC}"
  printf  "  ${G}  ║${NC}  ${DW}Password  :${NC}  ${W}%-31s${G}  ║${NC}\n" "$new_pass"
  printf  "  ${G}  ║${NC}  ${DW}Server IP :${NC}  ${W}%-31s${G}  ║${NC}\n" "$IP"
  printf  "  ${G}  ║${NC}  ${DW}Port      :${NC}  ${W}%-31s${G}  ║${NC}\n" "Any in 6000–19999"
  printf  "  ${G}  ║${NC}  ${DW}Obfs      :${NC}  ${W}%-31s${G}  ║${NC}\n" "zivpn"
  echo -e "  ${G}  ╚═══════════════════════════════════════════════╝${NC}"
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [3]  BULK ADD
# ════════════════════════════════════════════════════════════════
screen_bulk_add() {
  draw_header; draw_dashboard
  section "$G" "📋   BULK ADD PASSWORDS"

  echo -e "  ${DIM}  Enter passwords separated by commas.${NC}"
  echo -e "  ${DIM}  Example: alice,bob123,vpnuser99${NC}\n"
  echo -ne "  ${DW}Passwords${NC}  ${DIM}▶${NC} "
  read -r input

  [ -z "$input" ] && { result_err "No input given."; press_any; return; }

  IFS=',' read -r -a incoming <<< "$input"
  local added=0 skipped=0

  for np in "${incoming[@]}"; do
    np=$(echo "$np" | xargs 2>/dev/null)
    [ -z "$np" ] && continue
    if get_passwords | grep -qxF "$np"; then
      ((skipped++))
    else
      add_password "$np"
      echo "$np|permanent|unlimited|$(date +%Y-%m-%d)" >> "$DB_FILE"
      ((added++))
    fi
  done

  reload_svc
  result_ok "$added password(s) added. Service reloaded."
  [ $skipped -gt 0 ] && echo -e "  ${Y}  ⊘  $skipped duplicate(s) skipped.${NC}"
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [4]  TRIAL USER
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
  add_password "$pass"
  reload_svc

  local IP; IP=$(server_ip)
  echo ""
  echo -e "  ${Y}  ╔═══════════════════════════════════════════════╗${NC}"
  echo -e "  ${Y}  ║     ⏱  TRIAL USER CREATED                    ║${NC}"
  echo -e "  ${Y}  ╠═══════════════════════════════════════════════╣${NC}"
  printf  "  ${Y}  ║${NC}  ${DW}Password  :${NC}  ${W}%-31s${Y}  ║${NC}\n" "$pass"
  printf  "  ${Y}  ║${NC}  ${DW}Server IP :${NC}  ${W}%-31s${Y}  ║${NC}\n" "$IP"
  printf  "  ${Y}  ║${NC}  ${DW}Duration  :${NC}  ${W}%-31s${Y}  ║${NC}\n" "$mins minutes"
  printf  "  ${Y}  ║${NC}  ${DW}Obfs      :${NC}  ${W}%-31s${Y}  ║${NC}\n" "zivpn"
  echo -e "  ${Y}  ╚═══════════════════════════════════════════════╝${NC}"
  echo -e "\n  ${DIM}  Auto-expiring in $mins minutes...${NC}"

  # Background expiry
  (
    sleep $((mins * 60))
    remove_password "$pass"
    systemctl restart zivpn 2>/dev/null
  ) &

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
  sed -i "/^${removed}|/d" "$DB_FILE" 2>/dev/null || true
  reload_svc
  result_ok "User '${W}$removed${G}' removed. Service reloaded."
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
    s=$(echo "$s" | xargs 2>/dev/null)
    [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -ge 1 ] && [ "$s" -le "${#PWDS[@]}" ] && to_rm[$((s-1))]=1
  done

  for idx in "${!to_rm[@]}"; do
    remove_password "${PWDS[$idx]}"
    sed -i "/^${PWDS[$idx]}|/d" "$DB_FILE" 2>/dev/null || true
    ((cnt++))
  done

  reload_svc
  result_ok "$cnt user(s) removed. Service reloaded."
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
    result_ok "All users cleared. Service reloaded."
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
  local TMP; TMP=$(mktemp -d)

  # Panel
  echo -ne "  ${C}⟳${NC}  Panel (zivudp.sh)..."
  if wget -q --timeout=20 "$REPO_RAW/panel/zivudp.sh" -O "$TMP/zivudp.sh" && [ -s "$TMP/zivudp.sh" ]; then
    cp "$TMP/zivudp.sh" "$PANEL_PATH" && chmod +x "$PANEL_PATH"
    echo -e "  ${G}✔${NC}"
  else
    echo -e "  ${R}✘ failed${NC}"; ((ERRS++))
  fi

  # Installer
  echo -ne "  ${C}⟳${NC}  Installer (install.sh)..."
  if wget -q --timeout=20 "$REPO_RAW/install.sh" -O "$TMP/install.sh" && [ -s "$TMP/install.sh" ]; then
    cp "$TMP/install.sh" /etc/zivpn/install.sh && chmod +x /etc/zivpn/install.sh
    echo -e "  ${G}✔${NC}"
  else
    echo -e "  ${R}✘ failed${NC}"; ((ERRS++))
  fi

  # ZIVPN binary
  local ARCH; ARCH=$(uname -m)
  local BIN_ARCH; case $ARCH in x86_64|amd64) BIN_ARCH="amd64";; aarch64|arm64) BIN_ARCH="arm64";; *) BIN_ARCH="amd64";; esac
  echo -ne "  ${C}⟳${NC}  Binary (zivpn)..."
  if wget -q --timeout=30 \
      "https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-$BIN_ARCH" \
      -O "$TMP/zivpn_new" && [ -s "$TMP/zivpn_new" ]; then
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
    result_ok "All components updated. Re-run zivudp to load new panel."
  else
    result_warn "Updated with $ERRS error(s). Check internet connection."
  fi
  press_any
  # Reload self if panel was updated
  exec "$PANEL_PATH"
}

# ════════════════════════════════════════════════════════════════
#  [M]  MONITOR
# ════════════════════════════════════════════════════════════════
screen_monitor() {
  draw_header; draw_dashboard
  section "$Y" "📡   LIVE CONNECTION MONITOR"

  local PORT; PORT=$(get_port)
  echo -e "  ${W}  UDP connections on port $PORT:${NC}\n"
  local CONNS; CONNS=$(ss -anu 2>/dev/null | grep ":$PORT")

  if [ -z "$CONNS" ]; then
    echo -e "  ${DIM}  ┄ No active connections ┄${NC}"
  else
    echo -e "  ${DIM}  ┌─────────────────────────────┬─────────────────────────────┐${NC}"
    echo -e "  ${DIM}  │  Local                      │  Peer                       │${NC}"
    echo -e "  ${DIM}  ├─────────────────────────────┼─────────────────────────────┤${NC}"
    echo "$CONNS" | awk '{printf "  \033[2m  │\033[0m  \033[1;32m%-27s\033[0m  \033[2m│\033[0m  \033[1;37m%-27s\033[0m  \033[2m│\033[0m\n", $5, $6}'
    echo -e "  ${DIM}  └─────────────────────────────┴─────────────────────────────┘${NC}"
  fi

  echo -e "\n  ${W}  Recent logs (last 20):${NC}\n"
  journalctl -u zivpn -n 20 --no-pager 2>/dev/null \
    | sed 's/^/    /' \
    | sed "s/[Ee][Rr][Rr][Oo][Rr]/${R}&${NC}/g" \
    | sed "s/[Cc]onnect\|[Aa]uth/${G}&${NC}/g" \
    || echo -e "  ${DIM}  No logs.${NC}"
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [P]  CHANGE PORT
# ════════════════════════════════════════════════════════════════
screen_change_port() {
  draw_header; draw_dashboard
  section "$C" "🔌   CHANGE LISTEN PORT"

  local curr; curr=$(get_port)
  echo -e "  ${DIM}  Current port:${NC}  ${W}$curr/udp${NC}\n"
  echo -ne "  ${DW}New port${NC}  ${DIM}(1024–65535, 0 to cancel)${NC}  ${DIM}▶${NC} "
  read -r np

  { [ "$np" = "0" ] || [ -z "$np" ]; } && return
  if ! [[ "$np" =~ ^[0-9]+$ ]] || [ "$np" -lt 1024 ] || [ "$np" -gt 65535 ]; then
    result_err "Invalid port."; press_any; return
  fi

  jq --arg p ":$np" '.listen = $p' "$CONFIG_FILE" > /tmp/zv_tmp.json && mv /tmp/zv_tmp.json "$CONFIG_FILE"
  iptables -I INPUT -p udp --dport "$np" -j ACCEPT 2>/dev/null || true
  reload_svc
  result_ok "Port changed to ${W}$np${G}. Service reloaded."
  press_any
}

# ════════════════════════════════════════════════════════════════
#  [C]  CONFIG CHECK / REPAIR
# ════════════════════════════════════════════════════════════════
screen_config_check() {
  draw_header; draw_dashboard
  section "$C" "🔧   CONFIG CHECK & REPAIR"

  echo -e "  ${W}  Current config.json:${NC}\n"
  cat "$CONFIG_FILE" 2>/dev/null | sed 's/^/    /' | \
    sed "s/\"listen\"/${G}&${NC}/g" | \
    sed "s/\"cert\"\|\"key\"\|\"obfs\"/${Y}&${NC}/g" | \
    sed "s/\"auth\"/${C}&${NC}/g"

  echo ""
  echo -e "  ${DIM}  Checking required fields...${NC}"
  local ok=1
  jq -e '.listen'     "$CONFIG_FILE" &>/dev/null && echo -e "  ${G}  ✔ listen${NC}"      || { echo -e "  ${R}  ✘ listen${NC}";     ok=0; }
  jq -e '.cert'       "$CONFIG_FILE" &>/dev/null && echo -e "  ${G}  ✔ cert${NC}"        || { echo -e "  ${R}  ✘ cert${NC}";       ok=0; }
  jq -e '.key'        "$CONFIG_FILE" &>/dev/null && echo -e "  ${G}  ✔ key${NC}"         || { echo -e "  ${R}  ✘ key${NC}";        ok=0; }
  jq -e '.obfs'       "$CONFIG_FILE" &>/dev/null && echo -e "  ${G}  ✔ obfs${NC}"        || { echo -e "  ${R}  ✘ obfs${NC}";       ok=0; }
  jq -e '.auth'       "$CONFIG_FILE" &>/dev/null && echo -e "  ${G}  ✔ auth${NC}"        || { echo -e "  ${R}  ✘ auth${NC}";       ok=0; }
  jq -e '.auth.config' "$CONFIG_FILE" &>/dev/null && echo -e "  ${G}  ✔ auth.config${NC}" || { echo -e "  ${R}  ✘ auth.config${NC}"; ok=0; }
  [ -f "/etc/zivpn/zivpn.crt" ] && echo -e "  ${G}  ✔ cert file${NC}" || echo -e "  ${R}  ✘ cert file missing${NC}"
  [ -f "/etc/zivpn/zivpn.key" ] && echo -e "  ${G}  ✔ key file${NC}"  || echo -e "  ${R}  ✘ key file missing${NC}"

  if [ "$ok" -eq 0 ]; then
    echo ""
    if confirm_yn "Config has errors. Auto-repair now?"; then
      ensure_config
      # Force correct auth structure
      local current_passwords
      current_passwords=$(jq -c '[.auth.config // [] | .[]]' "$CONFIG_FILE" 2>/dev/null || echo "[]")
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
      result_ok "Config repaired. Service reloaded."
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
#  [W]  WEB PANEL
# ════════════════════════════════════════════════════════════════
WEBPANEL_PY="/etc/zivpn/webpanel.py"
WEBPANEL_CONF="/etc/zivpn/webpanel.conf"
WEBPANEL_SVC="/etc/systemd/system/zivpanel.service"

webpanel_running() { systemctl is-active --quiet zivpanel 2>/dev/null; }

webpanel_get_port() {
  python3 -c "
import json
try:
    d=json.load(open('$WEBPANEL_CONF'))
    print(d.get('port',8080))
except:
    print(8080)
" 2>/dev/null
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
ExecStart=/usr/bin/python3 /etc/zivpn/webpanel.py $port
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}

webpanel_ensure_service() {
  local port="${1:-$(webpanel_get_port)}"
  [ -f "$WEBPANEL_SVC" ] || webpanel_write_service "$port"
}

screen_webpanel() {
  while true; do
    draw_header
    echo ""
    section "$M" "🌐   WEB PANEL CONTROL"

    local IP; IP=$(server_ip)
    local PORT; PORT=$(webpanel_get_port)
    local INSTALLED=0
    [ -f "$WEBPANEL_PY" ] && [ -f "$WEBPANEL_SVC" ] && INSTALLED=1

    # Status row
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
      echo -e "  ${G}  [1]${NC}  Install & Start Web Panel"
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
          # ── Install ───────────────────────────────────────────
          draw_header; echo ""; section "$M" "🌐   INSTALL WEB PANEL"

          echo -ne "  ${DW}Web panel port${NC}  ${DIM}(default 8080)${NC}  ${DIM}▶${NC} "
          read -r wp_port
          wp_port=${wp_port:-8080}
          if ! [[ "$wp_port" =~ ^[0-9]+$ ]] || [ "$wp_port" -lt 1024 ] || [ "$wp_port" -gt 65535 ]; then
            result_err "Invalid port. Using 8080."; wp_port=8080
          fi

          echo -ne "  ${DW}Panel password${NC}  ${DIM}(default: admin)${NC}  ${DIM}▶${NC} "
          read -r wp_pass
          wp_pass=${wp_pass:-admin}

          echo -e "\n  ${DIM}  Downloading webpanel.py from GitHub...${NC}"
          wget -q --timeout=20 "$REPO_RAW/panel/webpanel.py" -O "$WEBPANEL_PY" 2>/dev/null
          if [ ! -s "$WEBPANEL_PY" ]; then
            result_err "Download failed. Check internet or push webpanel.py to repo."
            press_any; continue
          fi

          # Write panel config with hashed password
          python3 -c "
import json, hashlib
c={'port':$wp_port,'pass_hash':hashlib.sha256('$wp_pass'.encode()).hexdigest()}
json.dump(c,open('$WEBPANEL_CONF','w'),indent=2)
"
          webpanel_write_service "$wp_port"
          # Open firewall
          iptables -I INPUT -p tcp --dport "$wp_port" -j ACCEPT 2>/dev/null || true

          webpanel_ensure_service "$wp_port"
          systemctl enable zivpanel 2>/dev/null
          systemctl start  zivpanel
          sleep 1

          local new_ip; new_ip=$(server_ip)
          echo ""
          echo -e "  ${G}  ╔═══════════════════════════════════════════════╗${NC}"
          echo -e "  ${G}  ║     🌐  WEB PANEL INSTALLED  ✔               ║${NC}"
          echo -e "  ${G}  ╠═══════════════════════════════════════════════╣${NC}"
          printf  "  ${G}  ║${NC}  ${DW}URL      :${NC}  ${C}%-31s${G}  ║${NC}\n" "http://${new_ip}:${wp_port}"
          printf  "  ${G}  ║${NC}  ${DW}Password :${NC}  ${W}%-31s${G}  ║${NC}\n" "$wp_pass"
          echo -e "  ${G}  ╚═══════════════════════════════════════════════╝${NC}"
          press_any
        else
          webpanel_ensure_service "$PORT"
          systemctl start zivpanel
          sleep 1
          webpanel_running && result_ok "Web panel started → http://${IP}:${PORT}" \
                           || result_err "Failed to start. Check: journalctl -u zivpanel -n 20"
          press_any
        fi ;;

      2)
        systemctl stop zivpanel
        result_ok "Web panel stopped."
        press_any ;;

      3)
        webpanel_ensure_service "$PORT"
        systemctl restart zivpanel
        sleep 1
        webpanel_running && result_ok "Web panel restarted → http://${IP}:${PORT}" \
                         || result_err "Restart failed."
        press_any ;;

      4)
        draw_header; echo ""; section "$C" "🔑   CHANGE WEB PANEL PASSWORD"
        echo -ne "  ${DW}New password${NC}  ${DIM}▶${NC} "
        read -r new_wp_pass
        new_wp_pass=$(echo "$new_wp_pass" | xargs 2>/dev/null)
        if [ -z "$new_wp_pass" ]; then
          result_err "Password cannot be empty."; press_any; continue
        fi
        python3 -c "
import json, hashlib
try:
    d=json.load(open('$WEBPANEL_CONF'))
except:
    d={'port':8080}
d['pass_hash']=hashlib.sha256('$new_wp_pass'.encode()).hexdigest()
json.dump(d,open('$WEBPANEL_CONF','w'),indent=2)
"
        systemctl restart zivpanel 2>/dev/null
        result_ok "Password updated. Web panel restarted."
        press_any ;;

      5)
        draw_header; echo ""; section "$C" "🔌   CHANGE WEB PANEL PORT"
        echo -ne "  ${DW}New port${NC}  ${DIM}(1024–65535)${NC}  ${DIM}▶${NC} "
        read -r new_wp_port
        if ! [[ "$new_wp_port" =~ ^[0-9]+$ ]] || [ "$new_wp_port" -lt 1024 ] || [ "$new_wp_port" -gt 65535 ]; then
          result_err "Invalid port."; press_any; continue
        fi
        python3 -c "
import json
try:
    d=json.load(open('$WEBPANEL_CONF'))
except:
    d={}
d['port']=$new_wp_port
json.dump(d,open('$WEBPANEL_CONF','w'),indent=2)
"
        iptables -I INPUT -p tcp --dport "$new_wp_port" -j ACCEPT 2>/dev/null || true
        webpanel_write_service "$new_wp_port"
        systemctl restart zivpanel 2>/dev/null
        result_ok "Port changed to ${W}$new_wp_port${G}. Access: http://${IP}:${new_wp_port}"
        press_any ;;

      6)
        if confirm_yn "Uninstall web panel?"; then
          systemctl stop    zivpanel 2>/dev/null
          systemctl disable zivpanel 2>/dev/null
          rm -f "$WEBPANEL_SVC" "$WEBPANEL_PY" "$WEBPANEL_CONF"
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
  while true; do
    draw_header
    draw_dashboard

    echo -e "  ${DIM}  ┌── 👥  USER MANAGEMENT ──────────────────────────────┐${NC}"
    echo -e "  ${DIM}  │${NC}  ${G}[1]${NC}  List All Users + Connection Info              ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${G}[2]${NC}  Add User                                      ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${G}[3]${NC}  Bulk Add  ${DIM}(comma-separated)${NC}                    ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${Y}[4]${NC}  Trial User  ${DIM}(auto-expires 1–60 min)${NC}           ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${R}[5]${NC}  Remove Single User                             ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${R}[6]${NC}  Remove Multiple Users                          ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${R}[7]${NC}  Clear ALL Users                                ${DIM}│${NC}"
    echo -e "  ${DIM}  ├── ⚙  SERVICE CONTROL ───────────────────────────────┤${NC}"
    echo -e "  ${DIM}  │${NC}  ${G}[8]${NC}  Start ZIVPN                                    ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${R}[9]${NC}  Stop  ZIVPN                                    ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${Y}[10]${NC} Restart ZIVPN                                  ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${M}[u]${NC}  Auto-Update from GitHub  ${DIM}⟳${NC}                    ${DIM}│${NC}"
    echo -e "  ${DIM}  ├── 🌐  WEB PANEL ───────────────────────────────────┤${NC}"
    echo -e "  ${DIM}  │${NC}  ${M}[w]${NC}  Web Panel  ${DIM}(browser UI — install/manage)${NC}         ${DIM}│${NC}"
    echo -e "  ${DIM}  ├── 🛠  TOOLS ────────────────────────────────────────┤${NC}"
    echo -e "  ${DIM}  │${NC}  ${C}[m]${NC}  Live Connection Monitor                        ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${C}[p]${NC}  Change Listen Port                             ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${Y}[c]${NC}  Config Check & Repair                          ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${W}[i]${NC}  About / Info                                   ${DIM}│${NC}"
    echo -e "  ${DIM}  │${NC}  ${DR}[q]${NC}  Exit                                           ${DIM}│${NC}"
    echo -e "  ${DIM}  └────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -ne "  ${C}▶${NC}  Select option: "
    read -r choice

    case "$choice" in
      1)    screen_list        ;;
      2)    screen_add_user    ;;
      3)    screen_bulk_add    ;;
      4)    screen_trial_user  ;;
      5)    screen_remove_user ;;
      6)    screen_bulk_remove ;;
      7)    screen_clear_all   ;;
      8)    screen_start       ;;
      9)    screen_stop        ;;
      10)   screen_restart     ;;
      u|U)  screen_autoupdate  ;;
      w|W)  screen_webpanel    ;;
      m|M)  screen_monitor     ;;
      p|P)  screen_change_port ;;
      c|C)  screen_config_check;;
      i|I)  screen_about       ;;
      q|Q|0)
        clear
        echo -e "\n  ${C}  ★  NOOBS ZIVPN UDP PANEL — Goodbye!  ★${NC}\n"
        exit 0 ;;
      *)
        echo -e "\n  ${R}  ✘  Invalid option.${NC}"; sleep 1 ;;
    esac
  done
}

main_menu


# NOTE: enhanced users.json, expiry daemon, stats hooks added scaffold.
