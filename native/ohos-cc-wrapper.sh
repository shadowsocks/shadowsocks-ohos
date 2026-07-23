#!/bin/sh
# C cross-compiler shim for `cargo check --target *-unknown-linux-ohos` on
# hosts without the OpenHarmony native SDK. Uses zig cc with the equivalent
# musl target (OpenHarmony's libc is musl-based), stripping the ohos triple
# that zig does not know. Compile-only verification — final linking must use
# the real OHOS SDK clang (see build-ohos.sh).
target=aarch64-linux-musl

# filter out --target=<ohos triple> while keeping every other argument intact
n=$#
i=0
while [ "$i" -lt "$n" ]; do
    arg=$1
    shift
    i=$((i + 1))
    case "$arg" in
        --target=*) ;;
        *) set -- "$@" "$arg" ;;
    esac
done

exec zig cc -target "$target" "$@"
