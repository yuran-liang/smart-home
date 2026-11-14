#!/bin/sh
# Keep traffic that arrives through Tailscale (a guest using this node as an exit node) away from
# every private network: the guest may reach the internet and nothing else.
#
# The rules go into the raw table, which Tailscale does not touch, and are checked before
# connection tracking and before the FORWARD chain, where Tailscale accepts its own traffic.
#
# Usage: firewall.sh [own tailscale address]
# The address is the one exception inside the Tailscale range: the node answers DNS queries of
# its guests there.
set -eu

OWN_IP=${1:-}

# The host kernel has no legacy raw table; use the nftables back end of iptables
IPT=iptables-nft
IP6T=ip6tables-nft

rule() {
    # Insert the rule at the top unless it is there already
    $IPT -t raw -C PREROUTING "$@" 2> /dev/null || $IPT -t raw -I PREROUTING 1 "$@"
}
rule6() {
    $IP6T -t raw -C PREROUTING "$@" 2> /dev/null || $IP6T -t raw -I PREROUTING 1 "$@"
}

# Inserted last, so it ends up first: the own address is accepted before the range is dropped
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 127.0.0.0/8 100.64.0.0/10; do
    rule -i tailscale0 -d "$net" -j DROP
done
if [ -n "$OWN_IP" ]; then
    rule -i tailscale0 -d "$OWN_IP" -j ACCEPT
fi

if command -v "$IP6T" > /dev/null 2>&1; then
    for net in fc00::/7 fe80::/10 ::1/128; do
        rule6 -i tailscale0 -d "$net" -j DROP || true
    done
fi
