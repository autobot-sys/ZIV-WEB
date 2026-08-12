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