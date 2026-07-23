#!/usr/bin/env bash
#
# Host-side verification of the HarmonyOS NEXT subproject's native core:
#
#  1. cargo test — includes tests/e2e.rs, a genuine end-to-end tunnel test:
#     an in-process shadowsocks server, an sslocal instance driven through
#     the same C ABI the NAPI layer uses, and a SOCKS5 round-trip through the
#     encrypted tunnel to an echo server.
#  2. cargo check --target aarch64-unknown-linux-ohos — proves the whole core
#     (shadowsocks-service + FFI) compiles for OpenHarmony. Uses the real OHOS
#     SDK clang when OHOS_NDK_HOME is set, otherwise falls back to a zig-based
#     compile-only shim for the C bits (blake3).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/native/sslocal-ffi"

echo "=== 1/2 host tests (incl. SOCKS5 e2e round-trip) ==="
cargo test

echo "=== 2/3 cross-compile check for aarch64-unknown-linux-ohos ==="
if ! rustup target list --installed | grep -q aarch64-unknown-linux-ohos; then
    rustup target add aarch64-unknown-linux-ohos
fi
# Prefer the real OpenHarmony SDK clang; fall back to a zig cc shim for the C
# bits (blake3) when the SDK is absent.
if [[ -z "${OHOS_NDK_HOME:-}" ]]; then
    for candidate in \
        "$HOME/Downloads/command-line-tools/sdk/default/openharmony/native" \
        "$HOME/command-line-tools/sdk/default/openharmony/native"; do
        [[ -d "$candidate" ]] && OHOS_NDK_HOME="$candidate" && break
    done
fi
if [[ -n "${OHOS_NDK_HOME:-}" ]]; then
    export CC_aarch64_unknown_linux_ohos="$OHOS_NDK_HOME/llvm/bin/aarch64-unknown-linux-ohos-clang"
elif command -v zig >/dev/null; then
    export CC_aarch64_unknown_linux_ohos="$SCRIPT_DIR/native/ohos-cc-wrapper.sh"
else
    echo "Neither OHOS_NDK_HOME nor zig available; skipping C shim" >&2
fi
cargo check --target aarch64-unknown-linux-ohos

echo "=== 3/3 tun packet-routing e2e ==="
# Genuine IP-packet round-trip through the tun stack. Needs Linux + root
# (CAP_NET_ADMIN, /dev/net/tun). On other hosts, run it in a container with
# harmony/native/run-tun-e2e-docker.sh instead.
if [[ "$(uname -s)" == "Linux" && "$(id -u)" == "0" ]] && command -v ip >/dev/null; then
    cargo build --release --example net_helper
    NET_HELPER="$SCRIPT_DIR/native/sslocal-ffi/target/release/examples/net_helper" \
        bash "$SCRIPT_DIR/native/tun-e2e-linux.sh"
else
    echo "SKIPPED (needs Linux + root); use run-tun-e2e-docker.sh on other hosts"
fi

echo ""
echo "========================================"
echo "  HarmonyOS core verification PASSED"
echo "========================================"
