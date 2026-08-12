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
ACCT_BIN="/usr/local/bin/zivacctd"
ACCT_SVC="/etc/systemd/system/zivacct.service"
REPO_RAW="https://raw.githubusercontent.com/autobot-sys/ZIV-WEB/main"

# ── Colours ──────────────────────────────────────────────────────
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

step()  { echo -e "\n${Y}[$1/$TOTAL]${NC} $2"; }
ok()    { echo -e "  ${G}✔ $*${NC}"; }
fail()  { echo -e "  ${R}✘ $* — exiting.${NC}"; exit 1; }
warn()  { echo -e "  ${Y}⚠ $* (continuing)${NC}"; }

TOTAL=9

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

# ── Step 9: Install accounting daemon (zivacctd) ─────────────────
step 9 "Installing accounting daemon (zivacctd)..."

# 9.1 Install build dependencies
apt-get install -y -qq gcc make pkg-config \
  libnetfilter-queue-dev libnetfilter-conntrack-dev libmnl-dev libnfnetlink-dev \
  || fail "Failed to install accounting daemon build dependencies"

# 9.2 Write C source
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

struct flow_key {
    uint32_t src_ip;
    uint16_t src_port;
};

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
        if (e->key.src_ip == ip && e->key.src_port == port)
            return e;
        e = e->next;
    }
    return NULL;
}

void add_flow(uint32_t ip, uint16_t port, const char *user) {
    unsigned int idx = hash_key(ip, port);
    struct flow_entry *e = calloc(1, sizeof(*e));
    e->key.src_ip = ip;
    e->key.src_port = port;
    strncpy(e->user, user, 63);
    e->next = flow_hash[idx];
    flow_hash[idx] = e;
}

void remove_flow(uint32_t ip, uint16_t port) {
    unsigned int idx = hash_key(ip, port);
    struct flow_entry *e = flow_hash[idx], *prev = NULL;
    while (e) {
        if (e->key.src_ip == ip && e->key.src_port == port) {
            if (prev) prev->next = e->next;
            else flow_hash[idx] = e->next;
            free(e);
            return;
        }
        prev = e;
        e = e->next;
    }
}

struct user_counters *find_user(const char *user) {
    struct user_counters *u = user_list;
    while (u) {
        if (strcmp(u->user, user) == 0) return u;
        u = u->next;
    }
    return NULL;
}

void add_user_bytes(const char *user, uint64_t up, uint64_t down) {
    struct user_counters *u = find_user(user);
    if (!u) {
        u = calloc(1, sizeof(*u));
        strncpy(u->user, user, 63);
        u->next = user_list;
        user_list = u;
    }
    u->up_bytes += up;
    u->down_bytes += down;
}

void load_passwords() {
    FILE *f = fopen(CONFIG_FILE, "r");
    if (!f) return;
    char line[256];
    int in_config = 0;
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
    for (int i = 0; i < len; i++) {
        decoded[i] = payload[i] ^ key[i % key_len];
    }
    decoded[len] = '\0';
    for (int i = 0; i < pass_count; i++) {
        if (strstr((char *)decoded, passwords[i])) {
            strncpy(out, passwords[i], out_len);
            free(decoded);
            return 0;
        }
    }
    free(decoded);
    return -1;
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
        if (!find_flow(ip->saddr, udp->source)) {
            add_flow(ip->saddr, udp->source, user);
        }
        pthread_mutex_unlock(&lock);
    }
accept:
    return nfq_set_verdict(qh, nfq_get_msg_packet_id(nfa), NF_ACCEPT, 0, NULL);
}

void *nfq_thread(void *arg) {
    struct nfq_handle *h;
    struct nfq_q_handle *qh;
    int fd;
    char buf[65536];
    h = nfq_open();
    if (!h) { perror("nfq_open"); exit(1); }
    nfq_unbind_pf(h, AF_INET);
    nfq_bind_pf(h, AF_INET);
    qh = nfq_create_queue(h, NFQUEUE_NUM, &nfq_callback, NULL);
    if (!qh) { perror("nfq_create_queue"); exit(1); }
    nfq_set_mode(qh, NFQNL_COPY_PACKET, 0xffff);
    fd = nfq_fd(h);
    while (1) {
        int rv = recv(fd, buf, sizeof(buf), 0);
        if (rv > 0) nfq_handle_packet(h, buf, rv);
    }
    return NULL;
}

static int conntrack_cb(enum nf_conntrack_msg_type type,
                        struct nf_conntrack *ct, void *data) {
    if (type != NFCT_T_UPDATE && type != NFCT_T_DESTROY)
        return NFCT_CB_CONTINUE;
    uint32_t src_ip, dst_ip;
    uint16_t src_port, dst_port;
    uint64_t orig_bytes, reply_bytes;
    if (nfct_get_attr_u32(ct, ATTR_ORIG_IPV4_SRC, &src_ip) < 0 ||
        nfct_get_attr_u16(ct, ATTR_ORIG_PORT_SRC, &src_port) < 0 ||
        nfct_get_attr_u32(ct, ATTR_ORIG_IPV4_DST, &dst_ip) < 0 ||
        nfct_get_attr_u16(ct, ATTR_ORIG_PORT_DST, &dst_port) < 0)
        return NFCT_CB_CONTINUE;
    uint32_t client_ip;
    uint16_t client_port;
    if (dst_port == SERVICE_PORT) {
        client_ip = src_ip; client_port = src_port;
    } else if (src_port == SERVICE_PORT) {
        client_ip = dst_ip; client_port = dst_port;
    } else {
        return NFCT_CB_CONTINUE;
    }
    if (nfct_get_attr_u64(ct, ATTR_ORIG_COUNTER_BYTES, &orig_bytes) < 0)
        orig_bytes = 0;
    if (nfct_get_attr_u64(ct, ATTR_REPL_COUNTER_BYTES, &reply_bytes) < 0)
        reply_bytes = 0;
    pthread_mutex_lock(&lock);
    struct flow_entry *e = find_flow(client_ip, client_port);
    if (e) {
        uint64_t d_up = orig_bytes - e->orig_bytes;
        uint64_t d_down = reply_bytes - e->reply_bytes;
        e->orig_bytes = orig_bytes;
        e->reply_bytes = reply_bytes;
        add_user_bytes(e->user, d_up, d_down);
        if (type == NFCT_T_DESTROY) {
            remove_flow(client_ip, client_port);
        }
    }
    pthread_mutex_unlock(&lock);
    return NFCT_CB_CONTINUE;
}

void *conntrack_thread(void *arg) {
    struct nfct_handle *h = nfct_open(CONNTRACK, NFCT_ALL_CT_GROUPS);
    if (!h) { perror("nfct_open"); exit(1); }
    nfct_callback_register(h, NFCT_T_ALL, conntrack_cb, NULL);
    while (1) {
        int ret = nfct_catch(h);
        if (ret == -1) usleep(100000);
    }
    return NULL;
}

void write_meta() {
    // Preserve existing metadata if present; this minimal version rewrites only counters.
    FILE *out = fopen(META_FILE, "w");
    if (!out) return;
    pthread_mutex_lock(&lock);
    fprintf(out, "{\n");
    struct user_counters *u = user_list;
    int first = 1;
    while (u) {
        if (!first) fprintf(out, ",\n");
        fprintf(out, "  \"%s\": {\n", u->user);
        fprintf(out, "    \"data_used_bytes\": %llu,\n", (unsigned long long)(u->up_bytes + u->down_bytes));
        fprintf(out, "    \"device_limit\": 0,\n");
        fprintf(out, "    \"data_limit_bytes\": 0,\n");
        fprintf(out, "    \"expiry\": null\n");
        fprintf(out, "  }");
        first = 0;
        u = u->next;
    }
    pthread_mutex_unlock(&lock);
    fprintf(out, "\n}\n");
    fclose(out);
}

void *writer_thread(void *arg) {
    while (1) {
        sleep(5);
        write_meta();
    }
    return NULL;
}

void signal_handler(int sig) {
    write_meta();
    exit(0);
}

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

# 9.3 Compile
echo -e "  ${DIM}Compiling zivacctd...${NC}"
gcc -O3 -march=native -o "$ACCT_BIN" /tmp/zivacctd.c \
  -lnetfilter_queue -lnetfilter_conntrack -lmnl -lnfnetlink -lpthread \
  || fail "Compilation of zivacctd failed."
rm -f /tmp/zivacctd.c
chmod +x "$ACCT_BIN"
ok "Accounting daemon compiled and installed"

# 9.4 Create systemd service
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
systemctl enable zivacct 2>/dev/null
systemctl start  zivacct

# 9.5 Add NFQUEUE rule for first UDP packet
iptables -C INPUT -p udp --dport 5667 -m state --state NEW -j NFQUEUE --queue-num 0 2>/dev/null || \
  iptables -I INPUT 1 -p udp --dport 5667 -m state --state NEW -j NFQUEUE --queue-num 0
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

sleep 2
if systemctl is-active --quiet zivacct; then
  ok "Accounting daemon running"
else
  warn "Accounting daemon failed to start. Check journalctl -u zivacct"
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
printf "${G}║${NC}  %-20s ${W}%-31s${G}║${NC}\n" "Accounting"    "zivacctd (auto)"
printf "${G}║${NC}  %-20s ${W}%-31s${G}║${NC}\n" "Repo"          "github.com/autobot-sys/ZIV-WEB"
echo -e "${G}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${Y}▶  Type ${W}zivudp${Y} to open the terminal management panel.${NC}"
echo -e "  ${Y}▶  Run  ${W}zivudp → [w]${Y} to set up the web panel.${NC}"
echo ""
