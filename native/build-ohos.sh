#!/usr/bin/env bash
#
# Cross-compiles the Rust sslocal core for HarmonyOS/OpenHarmony and drops the
# static library where the DevEco CMake build expects it
# (harmony/entry/libs/<abi>/libsslocal_core.a).
#
# Requires the OpenHarmony native SDK (aka OHOS NDK):
#   export OHOS_NDK_HOME=/path/to/ohos-sdk/native
# and the Rust target:
#   rustup target add aarch64-unknown-linux-ohos
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRATE_DIR="$SCRIPT_DIR/sslocal-ffi"
LIBS_DIR="$SCRIPT_DIR/../entry/libs"

TARGET="${TARGET:-aarch64-unknown-linux-ohos}"
ABI="${ABI:-arm64-v8a}"
PROFILE="${PROFILE:-release}"

# Locate the OpenHarmony native SDK. Honour OHOS_NDK_HOME, else fall back to the
# command-line-tools layout (…/command-line-tools/sdk/default/openharmony/native).
if [[ -z "${OHOS_NDK_HOME:-}" ]]; then
    for candidate in \
        "$HOME/Downloads/command-line-tools/sdk/default/openharmony/native" \
        "$HOME/command-line-tools/sdk/default/openharmony/native"; do
        [[ -d "$candidate" ]] && OHOS_NDK_HOME="$candidate" && break
    done
fi
: "${OHOS_NDK_HOME:?Set OHOS_NDK_HOME to the OpenHarmony native SDK directory (…/openharmony/native)}"

LLVM_BIN="$OHOS_NDK_HOME/llvm/bin"
CLANG_WRAPPER="$LLVM_BIN/$TARGET-clang"
[[ -x "$CLANG_WRAPPER" ]] || CLANG_WRAPPER="$LLVM_BIN/${TARGET}-clang.sh"
[[ -x "$CLANG_WRAPPER" ]] || { echo "OHOS clang wrapper not found under $LLVM_BIN" >&2; exit 1; }

TARGET_UPPER=$(echo "$TARGET" | tr 'a-z-' 'A-Z_')
export "CC_${TARGET//-/_}"="$CLANG_WRAPPER"
export "AR_${TARGET//-/_}"="$LLVM_BIN/llvm-ar"
export "CARGO_TARGET_${TARGET_UPPER}_LINKER"="$CLANG_WRAPPER"
export "CARGO_TARGET_${TARGET_UPPER}_AR"="$LLVM_BIN/llvm-ar"

cd "$CRATE_DIR"
CARGO_FLAGS=()
[[ "$PROFILE" == "release" ]] && CARGO_FLAGS+=(--release)
# `${arr[@]+"${arr[@]}"}` because bash 3.2 (macOS) aborts under `set -u` when
# an empty array is expanded — which is exactly the PROFILE=debug case.
cargo build --target "$TARGET" ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} "$@"

mkdir -p "$LIBS_DIR/$ABI"
cp "$CRATE_DIR/target/$TARGET/$PROFILE/libsslocal_core.a" "$LIBS_DIR/$ABI/"
echo "Installed $LIBS_DIR/$ABI/libsslocal_core.a"
