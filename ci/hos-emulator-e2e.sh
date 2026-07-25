#!/usr/bin/env bash
#
# On-device verification of the HarmonyOS NEXT app against the HarmonyOS
# emulator: builds and debug-signs both HAPs, boots an emulator instance,
# installs, and runs the ohosTest suites against a host-side shadowsocks
# server.
#
# Everything the guest talks to is bound to the **host's loopback**, which the
# emulator reaches as 10.0.2.2 through QEMU's user-mode network:
#
#   ssserver 127.0.0.1:18388          the tunnel endpoint
#   http.server 127.0.0.1:18800       the marker page, only reachable through
#                                     that tunnel (see SocksE2e.test.ets)
#
# The VPN e2e (VpnE2e.test.ets) is deliberately not run: the public emulator
# image never delivers guest traffic to vpn-tun (docs/hos-emulator-vpn.md §2a),
# so it is a real-device test.
#
# Requires (all provided by ci/package-hos-toolchain.sh on a CI runner):
#   HOS_TOOLS   the DevEco command-line-tools directory (hvigorw, ohpm, sdk,
#               emulator, toolchains/hdc)
#   HOS_IMAGES  emulator image root, i.e. the parent of system-image/
#   ssserver    on PATH, or SSSERVER pointing at the binary
#
# Env knobs:
#   HOS_INSTANCE      emulator instance name (default: ss_ci)
#   HOS_OS_VERSION    image version         (default: HarmonyOS 6.1.1(24))
#   HOS_TARGET        hdc target            (default: 127.0.0.1:5555)
#   KEEP_EMULATOR=1   leave the emulator running on exit
#   SKIP_EMULATOR=1   use an already-running emulator (local iteration)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

: "${HOS_TOOLS:?set HOS_TOOLS to the command-line-tools directory}"
HOS_INSTANCE="${HOS_INSTANCE:-ss_ci}"
HOS_OS_VERSION="${HOS_OS_VERSION:-HarmonyOS 6.1.1(24)}"
HOS_TARGET="${HOS_TARGET:-127.0.0.1:5555}"
BUNDLE="com.xbt.project"

export DEVECO_SDK_HOME="$HOS_TOOLS/sdk"
export OHOS_SDK_HOME="$HOS_TOOLS/sdk/default/openharmony"
export OHOS_NDK_HOME="${OHOS_NDK_HOME:-$OHOS_SDK_HOME/native}"
HDC="$OHOS_SDK_HOME/toolchains/hdc"
EMULATOR="$HOS_TOOLS/emulator/Emulator"
HVIGORW="$HOS_TOOLS/bin/hvigorw"

WORK="$(mktemp -d)"
PIDS=()

cleanup() {
    local status=$?
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    if [[ $status -ne 0 && -f "$WORK/hilog.txt" ]]; then
        echo "=== device log (tail) ==="
        tail -100 "$WORK/hilog.txt" || true
    fi
    if [[ -z "${SKIP_EMULATOR:-}" && -z "${KEEP_EMULATOR:-}" ]]; then
        "$EMULATOR" -stop "$HOS_INSTANCE" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
    exit $status
}
trap cleanup EXIT

step() { echo ""; echo "=== $* ==="; }

# --------------------------------------------------------------------------
step "1/6 build the native core"
native/build-ohos.sh

step "2/6 build and sign both HAPs"
[[ -d oh_modules ]] || "$HOS_TOOLS/bin/ohpm" install
"$HVIGORW" --no-daemon assembleHap --mode module -p product=default -p buildMode=debug
"$HVIGORW" --no-daemon assembleHap --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug
APP_HAP="entry/build/default/outputs/default/entry-default-unsigned.hap"
TEST_HAP="entry/build/default/outputs/ohosTest/entry-ohosTest-unsigned.hap"
native/sign-hap-debug.sh "$APP_HAP"
native/sign-hap-debug.sh "$TEST_HAP"

# --------------------------------------------------------------------------
step "3/6 host-side shadowsocks server and marker page"
printf 'shadowsocks-ohos e2e OK\n' > "$WORK/e2e.txt"
SSSERVER="${SSSERVER:-$(command -v ssserver)}"
"$SSSERVER" -s 127.0.0.1:18388 -k shadowsocks-ohos-e2e -m aes-256-gcm -v \
    > "$WORK/ssserver.log" 2>&1 &
PIDS+=($!)
python3 -m http.server 18800 --bind 127.0.0.1 --directory "$WORK" \
    > "$WORK/http.log" 2>&1 &
PIDS+=($!)
sleep 1
# Sanity-check the host side before blaming the guest for a failed fetch.
curl -sf -m 5 http://127.0.0.1:18800/e2e.txt | grep -q 'e2e OK'
echo "marker page served on 127.0.0.1:18800, ssserver on 127.0.0.1:18388"

# --------------------------------------------------------------------------
if [[ -z "${SKIP_EMULATOR:-}" ]]; then
    step "4/6 boot the emulator"
    "$EMULATOR" -license accept >/dev/null
    # Where the (large, signed) system images live; the emulator defaults to
    # ~/Library/Huawei/Sdk, which is not where CI unpacks them.
    IMAGE_ROOT=()
    [[ -n "${HOS_IMAGES:-}" ]] && IMAGE_ROOT=(-imageRoot "$HOS_IMAGES")
    if ! "$EMULATOR" -list 2>/dev/null | grep -qx "$HOS_INSTANCE"; then
        "$EMULATOR" -create "$HOS_INSTANCE" -deviceType Phone \
            -osVersion "$HOS_OS_VERSION" -memory 4 -storage 6 \
            ${IMAGE_ROOT[@]+"${IMAGE_ROOT[@]}"}
    fi
    "$EMULATOR" -start "$HOS_INSTANCE" -bootmode coldboot \
        ${IMAGE_ROOT[@]+"${IMAGE_ROOT[@]}"} > "$WORK/emulator.log" 2>&1 &
    PIDS+=($!)
else
    step "4/6 using the already-running emulator"
fi

# The emulator often fails to register with hdc on its own; connect explicitly.
# (`tconn` says "Connect OK" the first time and "Target is connected, repeat
# operation" afterwards, so the target list is what we poll.)
step "5/6 wait for the device"
started=$SECONDS
until "$HDC" list targets 2>/dev/null | grep -q "$HOS_TARGET"; do
    [[ $((SECONDS - started)) -lt 300 ]] || { echo "emulator did not come up"; exit 1; }
    "$HDC" tconn "$HOS_TARGET" >/dev/null 2>&1 || true
    sleep 5
done
# ... and for the package manager to be ready to take an install.
until "$HDC" -t "$HOS_TARGET" shell "bm dump -a" 2>/dev/null | grep -q "ID:"; do
    [[ $((SECONDS - started)) -lt 300 ]] || { echo "device never became ready"; exit 1; }
    sleep 5
done
"$HDC" -t "$HOS_TARGET" shell hilog > "$WORK/hilog.txt" 2>&1 &
PIDS+=($!)

# A freshly booted image comes up locked, and `aa test` refuses to launch the
# test ability then ("The device screen is locked ... cannot be unlocked
# automatically" in developer mode). Wake it, stop it dimming again mid-run,
# and swipe the lock screen away (coordinates suit the phone profile's
# 1320x2856 screen).
"$HDC" -t "$HOS_TARGET" shell "power-shell wakeup" >/dev/null
"$HDC" -t "$HOS_TARGET" shell "power-shell timeout -o 2147483647" >/dev/null
"$HDC" -t "$HOS_TARGET" shell "uinput -T -m 660 2400 660 900 200" >/dev/null
sleep 2

"$HDC" -t "$HOS_TARGET" install -r "${APP_HAP%-unsigned.hap}-signed.hap"
"$HDC" -t "$HOS_TARGET" install -r "${TEST_HAP%-unsigned.hap}-signed.hap"

# --------------------------------------------------------------------------
step "6/6 run the on-device suites"
# SslocalNativeTest: NAPI surface. SocksE2eTest: the tunnel round-trip.
# VpnE2eTest is excluded on purpose (real hardware only, see the header).
#
# -s timeout raises hypium's 5s per-spec default; -w bounds `aa test` itself so
# a wedged test process fails the job instead of hanging it. Note that
# Hypium.setTimeConfig() is *not* a timeout setter — it installs a system-time
# provider that hypium calls .getRealTime() on, and passing a number there
# breaks the reporter and hangs the run.
RESULT="$WORK/aa-test.log"
"$HDC" -t "$HOS_TARGET" shell "aa test -b $BUNDLE -m entry_test \
    -s unittest OpenHarmonyTestRunner \
    -s class SslocalNativeTest,SocksE2eTest \
    -s timeout 60000 -w 300" 2>&1 | tee "$RESULT"

grep -q "^OHOS_REPORT_CODE: 0" "$RESULT" \
    || { echo "on-device tests FAILED"; grep -E "OHOS_REPORT_RESULT|Timeout" "$RESULT"; exit 1; }
# A run that reports zero tests must not pass silently.
grep -qE "OHOS_REPORT_RESULT: stream=Tests run: [1-9]" "$RESULT" \
    || { echo "no tests ran"; exit 1; }

echo ""
echo "host-side ssserver saw:"
grep -c "established tcp tunnel" "$WORK/ssserver.log" || true
echo ""
echo "========================================"
echo "  HarmonyOS on-device e2e PASSED"
echo "========================================"
