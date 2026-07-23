#!/usr/bin/env bash
#
# Builds the static musl helper and runs the tun packet-routing e2e
# (tun-e2e-linux.sh) inside a privileged Linux container. Works from macOS
# hosts, where a Linux tun device cannot be created directly.
#
# Requires: cargo-zigbuild (+ zig) and a running Docker daemon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRATE_DIR="$SCRIPT_DIR/sslocal-ffi"
TARGET="x86_64-unknown-linux-musl"
OUT_DIR="$SCRIPT_DIR/.tun-e2e"

echo "=== building static musl helper ($TARGET) ==="
rustup target list --installed | grep -q "$TARGET" || rustup target add "$TARGET"
( cd "$CRATE_DIR" && cargo zigbuild --release --target "$TARGET" --example net_helper )

mkdir -p "$OUT_DIR"
cp "$CRATE_DIR/target/$TARGET/release/examples/net_helper" "$OUT_DIR/net_helper"
cp "$SCRIPT_DIR/tun-e2e-linux.sh" "$OUT_DIR/tun-e2e-linux.sh"
chmod +x "$OUT_DIR/net_helper" "$OUT_DIR/tun-e2e-linux.sh"

# Any Linux image with iproute2 (incl. `ip netns`) works. Override with E2E_IMAGE.
# When using a bare image (e.g. ubuntu), install iproute2 first via E2E_PREP.
E2E_IMAGE="${E2E_IMAGE:-ubuntu:24.04}"
E2E_PREP="${E2E_PREP:-apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq iproute2 >/dev/null 2>&1}"

# If the container needs an HTTP proxy to reach the internet (e.g. for the apt
# install above), set E2E_PROXY to an address reachable from inside the
# container — for a proxy on the host, http://host.lima.internal:<port>.
# harmony/native/http-proxy.py starts a throwaway forward proxy for this when
# the host's usual proxy port is taken:
#   python3 harmony/native/http-proxy.py 18081 &
#   E2E_PROXY=http://host.lima.internal:18081 bash native/run-tun-e2e-docker.sh
PROXY_ARGS=()
if [[ -n "${E2E_PROXY:-}" ]]; then
    PROXY_ARGS=(-e "http_proxy=$E2E_PROXY" -e "https_proxy=$E2E_PROXY")
fi

echo "=== running e2e in privileged container ($E2E_IMAGE) ==="
exec docker run --rm --privileged \
    --device /dev/net/tun \
    "${PROXY_ARGS[@]}" \
    -v "$OUT_DIR:/work" \
    -e NET_HELPER=/work/net_helper \
    -e "RUST_LOG=${RUST_LOG:-info}" \
    --entrypoint bash \
    "$E2E_IMAGE" \
    -c "{ $E2E_PREP ; } ; bash /work/tun-e2e-linux.sh"
