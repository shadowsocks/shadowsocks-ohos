#!/usr/bin/env bash
#
# Genuine tun packet-routing e2e (Linux, root/CAP_NET_ADMIN required).
#
# Proves that IP packets sent into a tun device are terminated by the
# shadowsocks tun stack and re-established through the encrypted tunnel:
#
#   client ──▶ tun sstun0 ──▶ sslocal (tun mode) ──ss──▶ ss server ──▶ echo
#            (root netns)                                  (server netns)
#
# The shadowsocks server runs in a separate network namespace so its outbound
# connection to the echo target does not loop back into the tun. The client and
# the sslocal core (fed the tun fd via the same C ABI the HarmonyOS NAPI layer
# uses) run in the root namespace.
#
# Run it inside a privileged container: see run-tun-e2e-docker.sh.
set -euo pipefail

HELPER="${NET_HELPER:-/work/net_helper}"
PASSWORD="tun-e2e-password"
METHOD="aes-256-gcm"
MESSAGE="hello-through-the-tun-packet-router"

[[ -x "$HELPER" ]] || { echo "helper binary not found/executable: $HELPER" >&2; exit 1; }

PIDS=()
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
    for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
    ip netns pids ssns 2>/dev/null | xargs -r kill 2>/dev/null || true
    ip netns del ssns 2>/dev/null || true
    ip link del sstun0 2>/dev/null || true
    ip link del veth-r 2>/dev/null || true
}
trap cleanup EXIT

echo "=== setting up server network namespace ==="
ip netns add ssns
ip link add veth-r type veth peer name veth-s
ip link set veth-s netns ssns
ip addr add 10.0.0.1/24 dev veth-r
ip link set veth-r up
ip netns exec ssns ip addr add 10.0.0.2/24 dev veth-s
ip netns exec ssns ip link set veth-s up
ip netns exec ssns ip link set lo up
ip netns exec ssns ip addr add 10.9.9.9/32 dev lo

echo "=== creating tun device in root namespace ==="
ip tuntap add dev sstun0 mode tun
ip addr add 10.10.0.1/24 dev sstun0
ip link set sstun0 up
# only the echo target is routed into the tun; the ss server (10.0.0.2) stays on veth
ip route add 10.9.9.9/32 dev sstun0

echo "=== starting echo + shadowsocks server in server namespace ==="
ip netns exec ssns "$HELPER" echo 10.9.9.9:9 &
PIDS+=($!)
SRV_CFG="{\"server\":\"10.0.0.2\",\"server_port\":8388,\"password\":\"$PASSWORD\",\"method\":\"$METHOD\"}"
ip netns exec ssns "$HELPER" server "$SRV_CFG" &
PIDS+=($!)

echo "=== starting sslocal in tun mode (root namespace) ==="
TUN_CFG="{\"locals\":[{\"protocol\":\"tun\"}],\"server\":\"10.0.0.2\",\"server_port\":8388,\"password\":\"$PASSWORD\",\"method\":\"$METHOD\",\"mode\":\"tcp_and_udp\"}"
RUST_LOG="${RUST_LOG:-info}" "$HELPER" tun "$TUN_CFG" sstun0 &
PIDS+=($!)

sleep 2

echo "=== client: TCP round-trip to 10.9.9.9:9 through the tun ==="
if "$HELPER" client 10.9.9.9:9 "$MESSAGE"; then
    echo ""
    echo "========================================"
    echo "  TUN PACKET ROUTING E2E PASSED"
    echo "========================================"
    exit 0
else
    echo ""
    echo "  TUN PACKET ROUTING E2E FAILED" >&2
    exit 1
fi
