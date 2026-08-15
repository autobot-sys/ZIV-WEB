#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  NOOBS ZIVPN UDP PANEL  —  zivudp
#  Repo    : https://github.com/autobot-sys/ZIV-WEB
#  Version : 4.0.0 (with accounting daemon integration)
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
  local -A pkg_for=(
    [jq]=jq
    [python3]=python3
    [iptables]=iptables
    [conntrack]=conntrack-tools
    [curl]=curl
    [wget]=wget
    [openssl]=openssl
    [gcc]=gcc
    [pkg-config]=pkg-config
  )
  local missing=()
  for cmd in "${!pkg_for[@]}"; do
    command -v "$cmd" &>/dev/null || missing+=("${pkg_for[$cmd]}")
  done
  # Add dev libraries needed for zivacctd
  dpkg -s libnetfilter-queue-dev &>/dev/null || missing+=("libnetfilter-queue-dev")
  dpkg -s libnetfilter-conntrack-dev &>/dev/null || missing+=("libnetfilter-conntrack-dev")
  dpkg -s libmnl-dev &>/dev/null || missing+=("libmnl-dev")
  dpkg -s libnfnetlink-dev &>/dev/null || missing+=("libnfnetlink-dev")

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${Y}Installing missing dependencies: ${missing[*]}...${NC}"
    apt-get update -qq &>/dev/null
    apt-get install -y -qq "${missing[@]}" &>/dev/null
  fi
  modprobe nf_conntrack &>/dev/null || true
}
ensure_dependencies

# ═══════════════════════════════════════════════════════════════
#  CORE HELPERS — CONFIG & METADATA
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
  if ! jq -e '.auth' "$CONFIG_FILE" &>/dev/null; then
    jq '. + {"auth": {"mode": "passwords", "config": []}}' "$CONFIG_FILE" > /tmp/zv_fix.json && mv /tmp/zv_fix.json "$CONFIG_FILE"
  fi
  if ! jq -e '.auth.config' "$CONFIG_FILE" &>/dev/null; then
    jq '.auth.config = []' "$CONFIG_FILE" > /tmp/zv_fix.json && mv /tmp/zv_fix.json "$CONFIG_FILE"
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
    local visible_length label_len=${#label} value_len=${#value}
    local max_value_len pad_total
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

# ═══════════════════════════════════════════════════════════════
#  ALL SCREEN FUNCTIONS (1-10, u, m, p, c, i, w)
#  (Kept identical to original except for minor text changes)
# ═══════════════════════════════════════════════════════════════
# ... [PASTE ALL ORIGINAL SCREEN FUNCTIONS HERE] ...

# ═══════════════════════════════════════════════════════════════
#  ACCOUNTING DAEMON MANAGEMENT
# ═══════════════════════════════════════════════════════════════
write_acct_source() {
  cat > /tmp/zivacctd.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <linux/netfilter.h>
#include <libnetfilter_queue/libnetfilter_queue.h>
#include <libnetfilter_conntrack/libnetfilter_conntrack.h>
#include <libmnl/libmnl.h>

#define MAX_PASSWORDS 2048
#define HASH_SIZE 4096
#define OBFS_KEY "zivpn"
#define SERVICE_PORT 5667
#define NFQUEUE_NUM 0
#define META_FILE "/etc/zivpn/users_meta.json"
#define CONFIG_FILE "/etc/zivpn/config.json"

struct flow_key { uint32_t src_ip; uint16_t src_port; };
struct flow_entry {
    struct flow_key key;
    char user[64];
    uint64_t orig_bytes;
    uint64_t reply_bytes;
    struct flow_entry *next;
};
struct user_counters {
    char user[64];
    uint64_t up_bytes;
    uint64_t down_bytes;
    struct user_counters *next;
};
struct flow_entry *flow_hash[HASH_SIZE];
struct user_counters *user_list = NULL;
pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
char passwords[MAX_PASSWORDS][64];
int pass_count = 0;

unsigned int hash_key(uint32_t ip, uint16_t port) {
    return (ip ^ (port * 2654435761u)) % HASH_SIZE;
}
struct flow_entry *find_flow(uint32_t ip, uint16_t port) {
    unsigned int idx = hash_key(ip, port);
    struct flow_entry *e = flow_hash[idx];
    while (e) {
        if (e->key.src_ip == ip && e->key.src_port == port) return e;
        e = e->next;
    }
    return NULL;
}
void add_flow(uint32_t ip, uint16_t port, const char *user) {
    unsigned int idx = hash_key(ip, port);
    struct flow_entry *e = calloc(1, sizeof(*e));
    e->key.src_ip = ip; e->key.src_port = port;
    strncpy(e->user, user, 63);
    e->next = flow_hash[idx]; flow_hash[idx] = e;
}
void remove_flow(uint32_t ip, uint16_t port) {
    unsigned int idx = hash_key(ip, port);
    struct flow_entry *e = flow_hash[idx], *prev = NULL;
    while (e) {
        if (e->key.src_ip == ip && e->key.src_port == port) {
            if (prev) prev->next = e->next; else flow_hash[idx] = e->next;
            free(e); return;
        }
        prev = e; e = e->next;
    }
}
struct user_counters *find_user(const char *user) {
    struct user_counters *u = user_list;
    while (u) { if (strcmp(u->user, user) == 0) return u; u = u->next; }
    return NULL;
}
void add_user_bytes(const char *user, uint64_t up, uint64_t down) {
    struct user_counters *u = find_user(user);
    if (!u) {
        u = calloc(1, sizeof(*u));
        strncpy(u->user, user, 63);
        u->next = user_list; user_list = u;
    }
    u->up_bytes += up; u->down_bytes += down;
}
void load_passwords() {
    FILE *f = fopen(CONFIG_FILE, "r");
    if (!f) return;
    char line[256]; int in_config = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, "\"config\"")) { in_config = 1; continue; }
        if (in_config && strstr(line, "]")) break;
        if (in_config) {
            char *p = strchr(line, '"');
            if (p) {
                p++;
                char *q = strchr(p, '"');
                if (q) {
                    *q = '\0';
                    if (pass_count < MAX_PASSWORDS) {
                        strncpy(passwords[pass_count], p, 63);
                        pass_count++;
                    }
                }
            }
        }
    }
    fclose(f);
}
int extract_password(const unsigned char *payload, int len, char *out, int out_len) {
    const char *key = OBFS_KEY;
    int key_len = strlen(key);
    unsigned char *decoded = malloc(len + 1);
    for (int i = 0; i < len; i++) decoded[i] = payload[i] ^ key[i % key_len];
    decoded[len] = '\0';
    for (int i = 0; i < pass_count; i++) {
        if (strstr((char *)decoded, passwords[i])) {
            strncpy(out, passwords[i], out_len);
            free(decoded); return 0;
        }
    }
    free(decoded); return -1;
}
static int nfq_callback(struct nfq_q_handle *qh, struct nfgenmsg *nfmsg,
                        struct nfq_data *nfa, void *data) {
    struct nfqnl_msg_packet_hdr *ph = nfq_get_msg_packet_hdr(nfa);
    if (!ph) return -1;
    unsigned char *payload;
    int len = nfq_get_payload(nfa, &payload);
    if (len <= 0) goto accept;
    struct iphdr *ip = (struct iphdr *)payload;
    if (ip->protocol != IPPROTO_UDP) goto accept;
    struct udphdr *udp = (struct udphdr *)(payload + ip->ihl * 4);
    if (ntohs(udp->dest) != SERVICE_PORT) goto accept;
    int udp_len = ntohs(udp->len) - sizeof(struct udphdr);
    unsigned char *udp_payload = (unsigned char *)(udp + 1);
    char user[64];
    if (extract_password(udp_payload, udp_len, user, sizeof(user)) == 0) {
        pthread_mutex_lock(&lock);
        if (!find_flow(ip->saddr, udp->source)) add_flow(ip->saddr, udp->source, user);
        pthread_mutex_unlock(&lock);
    }
accept:
    return nfq_set_verdict(qh, nfq_get_msg_packet_id(nfa), NF_ACCEPT, 0, NULL);
}
void *nfq_thread(void *arg) {
    struct nfq_handle *h; struct nfq_q_handle *qh; int fd; char buf[65536];
    h = nfq_open(); if (!h) { perror("nfq_open"); exit(1); }
    nfq_unbind_pf(h, AF_INET); nfq_bind_pf(h, AF_INET);
    qh = nfq_create_queue(h, NFQUEUE_NUM, &nfq_callback, NULL);
    if (!qh) { perror("nfq_create_queue"); exit(1); }
    nfq_set_mode(qh, NFQNL_COPY_PACKET, 0xffff);
    fd = nfq_fd(h);
    while (1) { int rv = recv(fd, buf, sizeof(buf), 0); if (rv > 0) nfq_handle_packet(h, buf, rv); }
    return NULL;
}
static int conntrack_cb(enum nf_conntrack_msg_type type,
                        struct nf_conntrack *ct, void *data) {
    if (type != NFCT_T_UPDATE && type != NFCT_T_DESTROY) return NFCT_CB_CONTINUE;
    uint32_t src_ip, dst_ip; uint16_t src_port, dst_port; uint64_t orig_bytes, reply_bytes;
    if (nfct_get_attr_u32(ct, ATTR_ORIG_IPV4_SRC, &src_ip) < 0 ||
        nfct_get_attr_u16(ct, ATTR_ORIG_PORT_SRC, &src_port) < 0 ||
        nfct_get_attr_u32(ct, ATTR_ORIG_IPV4_DST, &dst_ip) < 0 ||
        nfct_get_attr_u16(ct, ATTR_ORIG_PORT_DST, &dst_port) < 0)
        return NFCT_CB_CONTINUE;
    uint32_t client_ip; uint16_t client_port;
    if (dst_port == SERVICE_PORT) { client_ip = src_ip; client_port = src_port; }
    else if (src_port == SERVICE_PORT) { client_ip = dst_ip; client_port = dst_port; }
    else return NFCT_CB_CONTINUE;
    if (nfct_get_attr_u64(ct, ATTR_ORIG_COUNTER_BYTES, &orig_bytes) < 0) orig_bytes = 0;
    if (nfct_get_attr_u64(ct, ATTR_REPL_COUNTER_BYTES, &reply_bytes) < 0) reply_bytes = 0;
    pthread_mutex_lock(&lock);
    struct flow_entry *e = find_flow(client_ip, client_port);
    if (e) {
        uint64_t d_up = orig_bytes - e->orig_bytes;
        uint64_t d_down = reply_bytes - e->reply_bytes;
        e->orig_bytes = orig_bytes; e->reply_bytes = reply_bytes;
        add_user_bytes(e->user, d_up, d_down);
        if (type == NFCT_T_DESTROY) remove_flow(client_ip, client_port);
    }
    pthread_mutex_unlock(&lock);
    return NFCT_CB_CONTINUE;
}
void *conntrack_thread(void *arg) {
    struct nfct_handle *h = nfct_open(CONNTRACK, NFCT_ALL_CT_GROUPS);
    if (!h) { perror("nfct_open"); exit(1); }
    nfct_callback_register(h, NFCT_T_ALL, conntrack_cb, NULL);
    while (1) { int ret = nfct_catch(h); if (ret == -1) usleep(100000); }
    return NULL;
}
void write_meta() {
    FILE *out = fopen(META_FILE, "w");
    if (!out) return;
    pthread_mutex_lock(&lock);
    fprintf(out, "{\n");
    struct user_counters *u = user_list; int first = 1;
    while (u) {
        if (!first) fprintf(out, ",\n");
        fprintf(out, "  \"%s\": {\n", u->user);
        fprintf(out, "    \"data_used_bytes\": %llu,\n", (unsigned long long)(u->up_bytes + u->down_bytes));
        fprintf(out, "    \"device_limit\": 0,\n");
        fprintf(out, "    \"data_limit_bytes\": 0,\n");
        fprintf(out, "    \"expiry\": null\n");
        fprintf(out, "  }");
        first = 0; u = u->next;
    }
    pthread_mutex_unlock(&lock);
    fprintf(out, "\n}\n");
    fclose(out);
}
void *writer_thread(void *arg) {
    while (1) { sleep(5); write_meta(); }
    return NULL;
}
void signal_handler(int sig) { write_meta(); exit(0); }
int main() {
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    load_passwords();
    pthread_t t_nfq, t_ct, t_writer;
    pthread_create(&t_nfq, NULL, nfq_thread, NULL);
    pthread_create(&t_ct, NULL, conntrack_thread, NULL);
    pthread_create(&t_writer, NULL, writer_thread, NULL);
    pthread_join(t_nfq, NULL);
    pthread_join(t_ct, NULL);
    pthread_join(t_writer, NULL);
    return 0;
}
EOF
}

compile_acct() {
  write_acct_source
  echo -e "  ${DIM}  Compiling zivacctd...${NC}"
  gcc -O3 -march=native -o "$ACCT_BIN" /tmp/zivacctd.c \
    -lnetfilter_queue -lnetfilter_conntrack -lmnl -lnfnetlink -lpthread
  if [ $? -ne 0 ]; then
    result_err "Compilation failed."
    press_any
    return 1
  fi
  chmod +x "$ACCT_BIN"
  rm -f /tmp/zivacctd.c
  result_ok "zivacctd compiled."
  return 0
}

install_acct_daemon() {
  draw_header
  section "$M" "🧮  INSTALL ACCOUNTING DAEMON"
  confirm_yn "Proceed with installation?" || { result_warn "Cancelled."; press_any; return; }
  ensure_dependencies
  compile_acct || { press_any; return; }
  cat > "$ACCT_SVC" << EOF
[Unit]
Description=ZIVPN Accounting Daemon
After=network.target zivpn.service
Requires=zivpn.service

[Service]
Type=simple
ExecStart=$ACCT_BIN
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable zivacct
  systemctl start zivacct
  local PORT=$(get_port)
  iptables -C INPUT -p udp --dport "$PORT" -m state --state NEW -j NFQUEUE --queue-num 0 2>/dev/null || \
    iptables -I INPUT 1 -p udp --dport "$PORT" -m state --state NEW -j NFQUEUE --queue-num 0
  sleep 2
  if acct_running; then
    result_ok "Accounting daemon installed and running."
  else
    result_err "Daemon failed to start. Check: journalctl -u zivacct -n 30"
  fi
  press_any
}

screen_accounting() {
  while true; do
    draw_header
    echo ""
    section "$M" "🧮   ACCOUNTING DAEMON"
    local INSTALLED=0
    [ -f "$ACCT_BIN" ] && [ -f "$ACCT_SVC" ] && INSTALLED=1
    if [ $INSTALLED -eq 1 ]; then
      if acct_running; then
        echo -e "  ${DIM}  Status:${NC}  ${G}RUNNING${NC}"
      else
        echo -e "  ${DIM}  Status:${NC}  ${R}STOPPED${NC}"
      fi
    else
      echo -e "  ${Y}  Accounting daemon is not installed.${NC}"
    fi
    echo ""
    if [ $INSTALLED -eq 0 ]; then
      echo -e "  ${G}  [1]${NC}  Install Accounting Daemon"
    else
      echo -e "  ${G}  [1]${NC}  Start / Restart"
      echo -e "  ${R}  [2]${NC}  Stop"
      echo -e "  ${Y}  [3]${NC}  Recompile (update)"
      echo -e "  ${R}  [4]${NC}  Uninstall"
    fi
    echo -e "  ${DIM}  [0]${NC}  Back to Main Menu"
    echo ""
    echo -ne "  ${M}▶${NC}  Select: "
    read -r ac
    case "$ac" in
      1)
        if [ $INSTALLED -eq 0 ]; then install_acct_daemon; else systemctl restart zivacct; sleep 1; acct_running && result_ok "Restarted" || result_err "Failed"; press_any; fi ;;
      2) systemctl stop zivacct; result_ok "Stopped."; press_any ;;
      3) compile_acct && systemctl restart zivacct && result_ok "Recompiled & restarted." || result_err "Failed"; press_any ;;
      4)
        if confirm_yn "Uninstall accounting daemon?"; then
          systemctl stop zivacct 2>/dev/null
          systemctl disable zivacct 2>/dev/null
          rm -f "$ACCT_B
