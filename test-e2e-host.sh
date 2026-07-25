#!/usr/bin/env bash
#
# Host-side verification of the HarmonyOS NEXT subproject's native core. Three
# independent steps, run all together by default or one at a time by name:
#
#   tests  cargo test — includes tests/e2e.rs, a genuine end-to-end tunnel
#          test: an in-process shadowsocks server, an sslocal instance driven
#          through the same C ABI the NAPI layer uses, and a SOCKS5 round-trip
#          through the encrypted tunnel to an echo server.
#   cross  cargo check --target aarch64-unknown-linux-ohos — proves the whole
#          core (shadowsocks-service + FFI) compiles for OpenHarmony. Uses the
#          real OHOS SDK clang when OHOS_NDK_HOME is set, otherwise falls back
#          to a zig-based compile-only shim for the C bits (blake3).
#   tun    a real TCP flow into a tun device, asserted to round-trip through
#          the tunnel. Needs Linux, /dev/net/tun and CAP_NET_ADMIN.
#
# Usage:
#   ./test-e2e-host.sh              # all three
#   ./test-e2e-host.sh tests        # just the Rust suite
#   ./test-e2e-host.sh cross tun    # any subset, in the order given
#
# CI runs each step as its own workflow (.github/workflows/test-*.yml) so a
# failure names the surface that broke; this script stays the single place that
# defines how each one runs.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRATE_DIR="$SCRIPT_DIR/native/sslocal-ffi"

STEPS=("$@")
[[ ${#STEPS[@]} -gt 0 ]] || STEPS=(tests cross tun)

step_tests() {
    echo "=== host tests (incl. SOCKS5 e2e round-trip) ==="
    cd "$CRATE_DIR"
    cargo test
}

step_cross() {
    echo "=== cross-compile check for aarch64-unknown-linux-ohos ==="
    cd "$CRATE_DIR"
    if ! rustup target list --installed | grep -q aarch64-unknown-linux-ohos; then
        rustup target add aarch64-unknown-linux-ohos
    fi
    # Prefer the real OpenHarmony SDK clang; fall back to a zig cc shim for the
    # C bits (blake3) when the SDK is absent.
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
}

step_tun() {
    echo "=== tun packet-routing e2e ==="
    # Genuine IP-packet round-trip through the tun stack. Needs Linux,
    # iproute2, /dev/net/tun and CAP_NET_ADMIN — root, or passwordless sudo
    # (which is what CI runners and most Linux dev boxes have). On other hosts,
    # run it in a container with native/run-tun-e2e-docker.sh instead.
    local as_root=()
    local skip=""
    if [[ "$(uname -s)" != "Linux" ]]; then
        skip="not Linux"
    elif ! command -v ip >/dev/null; then
        skip="iproute2 (ip) not installed"
    elif [[ ! -c /dev/net/tun ]]; then
        skip="/dev/net/tun is missing"
    elif [[ "$(id -u)" == "0" ]]; then
        skip=""
    elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
        as_root=(sudo)
    else
        skip="needs root or passwordless sudo"
    fi

    # A skip must not look like a pass where the environment can support the
    # test: CI sets TUN_E2E_REQUIRED=1 so a missing prerequisite fails the job.
    if [[ -n "$skip" ]]; then
        if [[ -n "${TUN_E2E_REQUIRED:-}" ]]; then
            echo "tun e2e cannot run ($skip) but TUN_E2E_REQUIRED is set" >&2
            return 1
        fi
        echo "SKIPPED ($skip); use run-tun-e2e-docker.sh on other hosts"
        return 0
    fi

    # build the helper as the invoking user, run the namespace setup as root
    cd "$CRATE_DIR"
    cargo build --release --example net_helper
    "${as_root[@]+"${as_root[@]}"}" env \
        NET_HELPER="$CRATE_DIR/target/release/examples/net_helper" \
        RUST_LOG="${RUST_LOG:-info}" \
        bash "$SCRIPT_DIR/native/tun-e2e-linux.sh"
}

for step in "${STEPS[@]}"; do
    case "$step" in
        tests|cross|tun) "step_$step" ;;
        *) echo "unknown step '$step' (want: tests, cross, tun)" >&2; exit 2 ;;
    esac
    echo ""
done

echo "========================================"
echo "  HarmonyOS core verification PASSED"
echo "  steps: ${STEPS[*]}"
echo "========================================"
