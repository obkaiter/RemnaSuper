// SPDX-License-Identifier: GPL-2.0
/*
 * RemnaSuper traffic shaper.
 *
 * Download packets are paced with EDT on an fq root qdisc. Upload packets
 * cannot be delayed at ingress, so a small token-bucket backlog is allowed
 * and excess packets are dropped to make TCP/QUIC reduce their send rate.
 */

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/pkt_cls.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#define RS_MAX_PORTS 32
#define RS_MAX_RULES 32
#define RS_NS_PER_SECOND 1000000000ULL
#define RS_DOWNLOAD_BACKLOG_NS 2000000000ULL
#define RS_UPLOAD_BACKLOG_NS 200000000ULL

struct rs_rule {
    __u32 mode;              /* 0=disabled, 1=per-IP, 2=dynamic, 3=shared */
    __u32 port_count;
    __u32 ports[RS_MAX_PORTS];
    __u64 download_rate;     /* bytes per second */
    __u64 upload_rate;
    __u64 penalty_rate;
    __u64 burst_bytes;
    __u64 window_ns;
    __u64 penalty_ns;
};

struct rs_user_key {
    __u32 address[4];
    __u32 rule_id;
    __u32 padding;
};

struct rs_ip_key {
    __u32 address[4];
};

struct rs_state {
    struct bpf_spin_lock lock;
    __u32 padding;
    __u64 window_bytes;
    __u64 window_started;
    __u64 penalty_until;
    __u64 next_departure;
    __u64 total_bytes;
    __u64 total_packets;
    __u64 dropped_packets;
    __u32 penalized;
    __u32 reserved;
};

struct rs_vlan_header {
    __be16 tci;
    __be16 encapsulated_proto;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u32);
    __type(value, __u32);
} port_rules SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, RS_MAX_RULES);
    __type(key, __u32);
    __type(value, struct rs_rule);
} rules SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, struct rs_ip_key);
    __type(value, __u8);
} whitelist SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, struct rs_user_key);
    __type(value, struct rs_state);
} download_states SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, struct rs_user_key);
    __type(value, struct rs_state);
} upload_states SEC(".maps");

static __always_inline int rs_parse_packet(
    void *data, void *data_end, __u32 direction,
    struct rs_user_key *user, __u16 *service_port)
{
    struct ethhdr *eth = data;
    __be16 protocol;
    __u64 offset = sizeof(*eth);
    __u8 transport_protocol;
    void *transport;

    if ((void *)(eth + 1) > data_end)
        return -1;

    protocol = eth->h_proto;

    /* Support up to two VLAN tags without an unbounded verifier loop. */
    if (protocol == bpf_htons(ETH_P_8021Q) ||
        protocol == bpf_htons(ETH_P_8021AD)) {
        struct rs_vlan_header *vlan = data + offset;
        if ((void *)(vlan + 1) > data_end)
            return -1;
        protocol = vlan->encapsulated_proto;
        offset += sizeof(*vlan);
    }
    if (protocol == bpf_htons(ETH_P_8021Q) ||
        protocol == bpf_htons(ETH_P_8021AD)) {
        struct rs_vlan_header *vlan = data + offset;
        if ((void *)(vlan + 1) > data_end)
            return -1;
        protocol = vlan->encapsulated_proto;
        offset += sizeof(*vlan);
    }

    if (protocol == bpf_htons(ETH_P_IP)) {
        struct iphdr *ip = data + offset;
        __u32 header_length;

        if ((void *)(ip + 1) > data_end || ip->ihl < 5)
            return -1;
        header_length = (__u32)ip->ihl * 4;
        if ((void *)ip + header_length > data_end)
            return -1;

        /* Non-initial fragments do not carry transport ports. */
        if (ip->frag_off & bpf_htons(IP_OFFSET))
            return -1;

        user->address[0] = direction == 0 ? ip->daddr : ip->saddr;
        transport_protocol = ip->protocol;
        transport = (void *)ip + header_length;
    } else if (protocol == bpf_htons(ETH_P_IPV6)) {
        struct ipv6hdr *ip6 = data + offset;

        if ((void *)(ip6 + 1) > data_end)
            return -1;
        if (direction == 0)
            __builtin_memcpy(user->address, &ip6->daddr, 16);
        else
            __builtin_memcpy(user->address, &ip6->saddr, 16);
        transport_protocol = ip6->nexthdr;
        transport = ip6 + 1;
    } else {
        return -1;
    }

    if (transport_protocol == IPPROTO_TCP) {
        struct tcphdr *tcp = transport;
        if ((void *)(tcp + 1) > data_end)
            return -1;
        *service_port = bpf_ntohs(direction == 0 ? tcp->source : tcp->dest);
        return 0;
    }

    if (transport_protocol == IPPROTO_UDP) {
        struct udphdr *udp = transport;
        if ((void *)(udp + 1) > data_end)
            return -1;
        *service_port = bpf_ntohs(direction == 0 ? udp->source : udp->dest);
        return 0;
    }

    return -1;
}

static __always_inline int rs_shape(
    struct __sk_buff *skb, __u32 direction, void *state_map)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct rs_user_key key = {};
    struct rs_ip_key ip_key = {};
    struct rs_state empty = {};
    struct rs_state *state;
    struct rs_rule *rule;
    __u16 service_port = 0;
    __u32 port_key;
    __u32 wildcard = 0;
    __u32 *rule_id;
    __u64 now;
    __u64 rate;
    __u64 departure = 0;
    __u64 delay;
    __u64 backlog_limit;
    __u64 configured_download;
    __u64 configured_upload;
    __u64 configured_penalty;
    __u64 configured_burst;
    __u64 configured_window;
    __u64 configured_penalty_time;
    __u32 mode;
    int action = TC_ACT_OK;

    if (rs_parse_packet(data, data_end, direction, &key, &service_port) < 0)
        return TC_ACT_OK;

    __builtin_memcpy(ip_key.address, key.address, sizeof(ip_key.address));
    if (bpf_map_lookup_elem(&whitelist, &ip_key))
        return TC_ACT_OK;

    port_key = service_port;
    rule_id = bpf_map_lookup_elem(&port_rules, &port_key);
    if (!rule_id)
        rule_id = bpf_map_lookup_elem(&port_rules, &wildcard);
    if (!rule_id || *rule_id >= RS_MAX_RULES)
        return TC_ACT_OK;

    key.rule_id = *rule_id;
    rule = bpf_map_lookup_elem(&rules, rule_id);
    if (!rule || rule->mode == 0)
        return TC_ACT_OK;

    /* Do not dereference a second map value while holding the state lock. */
    mode = rule->mode;
    configured_download = rule->download_rate;
    configured_upload = rule->upload_rate;
    configured_penalty = rule->penalty_rate;
    configured_burst = rule->burst_bytes;
    configured_window = rule->window_ns;
    configured_penalty_time = rule->penalty_ns;

    if (mode == 3)
        __builtin_memset(key.address, 0, sizeof(key.address));

    state = bpf_map_lookup_elem(state_map, &key);
    if (!state) {
        bpf_map_update_elem(state_map, &key, &empty, BPF_NOEXIST);
        state = bpf_map_lookup_elem(state_map, &key);
        if (!state)
            return TC_ACT_OK;
    }

    now = bpf_ktime_get_ns();
    bpf_spin_lock(&state->lock);

    state->total_bytes += skb->len;
    state->total_packets++;

    if (mode == 2) {
        if (state->penalized && now >= state->penalty_until) {
            state->penalized = 0;
            state->penalty_until = 0;
            state->window_started = now;
            state->window_bytes = 0;
        }

        if (!state->penalized) {
            if (!state->window_started ||
                now - state->window_started >= configured_window) {
                state->window_started = now;
                state->window_bytes = 0;
            }
            state->window_bytes += skb->len;
            if (state->window_bytes > configured_burst) {
                state->penalized = 1;
                state->penalty_until = now + configured_penalty_time;
            }
        }
    }

    rate = direction == 0 ? configured_download : configured_upload;
    if (mode == 2 && state->penalized)
        rate = configured_penalty;

    if (!rate) {
        state->dropped_packets++;
        action = TC_ACT_SHOT;
        goto unlock;
    }

    departure = state->next_departure;
    if (departure < now)
        departure = now;

    backlog_limit = direction == 0 ?
        RS_DOWNLOAD_BACKLOG_NS : RS_UPLOAD_BACKLOG_NS;
    if (departure - now > backlog_limit) {
        state->dropped_packets++;
        action = TC_ACT_SHOT;
        goto unlock;
    }

    delay = ((__u64)skb->len * RS_NS_PER_SECOND) / rate;
    departure += delay;
    state->next_departure = departure;

unlock:
    bpf_spin_unlock(&state->lock);

    if (action == TC_ACT_OK && direction == 0)
        skb->tstamp = departure;
    return action;
}

SEC("classifier/download")
int rs_download(struct __sk_buff *skb)
{
    return rs_shape(skb, 0, &download_states);
}

SEC("classifier/upload")
int rs_upload(struct __sk_buff *skb)
{
    return rs_shape(skb, 1, &upload_states);
}

char LICENSE[] SEC("license") = "GPL";
