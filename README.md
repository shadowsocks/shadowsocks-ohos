# Shadowsocks for HarmonyOS NEXT

[![Lint](https://github.com/shadowsocks/shadowsocks-ohos/actions/workflows/lint.yml/badge.svg)](https://github.com/shadowsocks/shadowsocks-ohos/actions/workflows/lint.yml)
[![Core tests](https://github.com/shadowsocks/shadowsocks-ohos/actions/workflows/test-core.yml/badge.svg)](https://github.com/shadowsocks/shadowsocks-ohos/actions/workflows/test-core.yml)
[![Cross-compile](https://github.com/shadowsocks/shadowsocks-ohos/actions/workflows/test-cross.yml/badge.svg)](https://github.com/shadowsocks/shadowsocks-ohos/actions/workflows/test-cross.yml)
[![Tun e2e](https://github.com/shadowsocks/shadowsocks-ohos/actions/workflows/test-tun.yml/badge.svg)](https://github.com/shadowsocks/shadowsocks-ohos/actions/workflows/test-tun.yml)

A native HarmonyOS NEXT (ArkTS/ArkUI, Stage model) client, sharing the Rust
core (`shadowsocks-rust`) with the Android app through a C ABI + NAPI bridge.

> HarmonyOS 2–4 devices run Android APKs and are covered by the main project's
> GMS-free `freedom` flavor. This subproject targets **HarmonyOS NEXT (5.x)**,
> which has no Android runtime.

## Layout

```
harmony/
├── AppScope/                  application-level config
├── entry/                     main HAP module
│   └── src/main
│       ├── ets/
│       │   ├── entryability/  UIAbility entry
│       │   ├── pages/         ArkUI (profile form, ss:// import, connect)
│       │   ├── model/         Profile (SIP002 parsing) + persistence
│       │   └── vpnability/    VpnExtensionAbility driving the native core
│       └── cpp/               NAPI shim (libsslocal.so) around the Rust core
└── native/
    ├── sslocal-ffi/           Rust crate: C ABI over shadowsocks-service
    ├── build-ohos.sh          cross-compile for aarch64-unknown-linux-ohos
    └── ohos-cc-wrapper.sh     zig-based C shim for SDK-less `cargo check`
```

The Rust crate path-depends on `core/src/main/rust/shadowsocks-rust` — the
same submodule the Android app builds, so both platforms ship the same core.

## Building

Prerequisites:

* DevEco Studio 5.x with the HarmonyOS NEXT SDK (API 12+)
* Rust with `rustup target add aarch64-unknown-linux-ohos`
* The OpenHarmony native SDK, exported as `OHOS_NDK_HOME=…/ohos-sdk/native`

Steps:

1. `native/build-ohos.sh` — builds `libsslocal_core.a` and installs it into
   `entry/libs/arm64-v8a/` where the CMake NAPI build links it.
2. `ohpm install` to resolve dependencies (needs the ohpm registry).
3. Build the HAP with the command-line tools (or DevEco Studio):

   ```sh
   export DEVECO_SDK_HOME=<command-line-tools>/sdk
   hvigorw assembleHap --mode module -p product=default -p buildMode=debug
   ```

   This compiles the ArkTS, builds `libsslocal.so` (NAPI shim + Rust core) via
   CMake/Ninja, and emits `entry/build/default/outputs/default/entry-default-unsigned.hap`.

### Debug signing (no Huawei account)

For a debug/emulator build, sign locally with the OpenHarmony sample signing
materials that ship in the SDK — DevEco's auto-sign uses the same scheme:

```sh
native/sign-hap-debug.sh entry/build/default/outputs/default/entry-default-unsigned.hap
```

This signs a debug provisioning profile for the app's bundle and signs +
verifies the HAP, producing `entry-default-signed.hap`. A Huawei developer
account is only needed for release signing / store distribution.

### Running on the emulator

`hdc -t <target> install entry-default-signed.hap` then launch the app. The
HarmonyOS emulator needs a system image installed via DevEco / `Emulator
-install`, which downloads from Huawei's servers.

## Testing

* **Host e2e (no HarmonyOS SDK needed)** — `./test-e2e-host.sh`, which runs
  three independent steps; pass names to run a subset (`./test-e2e-host.sh
  cross tun`):
  1. `tests` — Rust test suite, including `tests/e2e.rs`: an in-process
     shadowsocks server, an sslocal instance driven through the same C ABI the
     NAPI bridge uses, and a SOCKS5 round-trip through the encrypted tunnel.
  2. `cross` — cross-compile check that the whole core builds for
     `aarch64-unknown-linux-ohos` (real SDK clang if present, else a zig cc
     shim for the C bits).
  3. `tun` — **tun packet-routing e2e** (Linux, `/dev/net/tun`, root or
     passwordless sudo): sends a real TCP flow into a tun device and asserts it
     round-trips through the tunnel. On non-Linux hosts run it in a privileged
     container with `native/run-tun-e2e-docker.sh`.

  Each step is also its own CI workflow, so a red badge names the surface that
  broke: `test-core.yml`, `test-cross.yml`, `test-tun.yml`, plus `lint.yml` for
  rustfmt/clippy/shellcheck. All four gate every pull request.
* **ArkTS unit tests** — `entry/src/test` (hypium) covers `ss://` URL parsing
  and both SOCKS and tun config serialization. Run from DevEco Studio, or
  headless with `hvigorw test --mode module -p module=entry -p product=default`
  — **on macOS or Windows**: the runner drives the SDK's previewer, which does
  not work on Linux.
* **On-device e2e (emulator)** — `ci/hos-emulator-e2e.sh` builds and debug-signs
  both HAPs, boots the HarmonyOS emulator, installs them and runs
  `entry/src/ohosTest` against a shadowsocks server on the host:

  ```sh
  HOS_TOOLS=~/workspace/command-line-tools HOS_IMAGES=~/Library/Huawei/Sdk \
      ci/hos-emulator-e2e.sh
  ```

  `SocksE2e.test.ets` is the real end-to-end case: it starts the core in SOCKS
  mode through the NAPI bridge and fetches a marker page that is only reachable
  from the far end of the tunnel (a companion spec asserts it is unreachable
  without it). `SslocalNativeTest` covers the rest of the NAPI surface.
  `VpnE2e.test.ets` is skipped here — the public emulator image never delivers
  guest traffic to `vpn-tun`, so it is a real-device test (see
  `docs/hos-emulator-vpn.md` §2a).
* **CI** — one workflow per surface, so a failure names what broke:

  | workflow | what it runs | where |
  |---|---|---|
  | `lint.yml` | rustfmt, clippy, shellcheck | hosted Linux |
  | `test-core.yml` | Rust unit tests + host e2e tunnels | hosted Linux |
  | `test-cross.yml` | `aarch64-unknown-linux-ohos` build check | hosted Linux |
  | `test-tun.yml` | tun packet-routing e2e | hosted Linux |

  All four gate every push and pull request. Common setup — the shared
  `shadowsocks-rust` checkout, the toolchain and the cargo cache — lives in the
  composite action `.github/actions/rust-core`, which is also where the core's
  pinned ref is defined.

  Anything needing the **HarmonyOS SDK** — the HAP build, debug signing, the
  ArkTS unit tests and the on-device suites — is **not** in CI: Huawei's DevEco
  command-line tools are behind an account + region gate
  (`docs/hos-emulator-vpn.md` §4) and cannot be redistributed, so a runner
  cannot obtain them. Run those locally (see the steps above and
  `ci/hos-emulator-e2e.sh`).

  Those jobs did run for a while, fed from a private S3/R2 bucket. The tooling
  for that is still here — `ci/package-hos-toolchain.sh` packs and uploads a
  bundle, `ci/r2-env.sh` derives S3 credentials from a Cloudflare API token —
  and the workflows themselves are one `git revert` away in the history. What
  it costs to bring back: ~5.5 GB in the bucket, two repository secrets
  (`R2_API_TOKEN`, `R2_ENDPOINT`), and for the emulator a self-hosted
  Apple-silicon runner, since the emulator needs HVF and no GitHub-hosted
  runner provides it.

## Tun mode

`SsVpnExtensionAbility` installs a default route and hands the tun fd from
`VpnConnection.create()` to the core via `sslocal.startTunFd`. The core's tun
stack (smoltcp) terminates each TCP/UDP flow off the tun and re-establishes it
through the shadowsocks tunnel — the role tun2socks plays in the Android
client. The interface name is recovered from the fd (TUNGETIFF) so the tun
crate can read the interface address. Verified end-to-end by the tun
packet-routing e2e above.

## Status and known gaps

* **Server-connection bypass**: handled via `VpnConnection.protectProcessNet()`
  (API 22+), which keeps every socket the VPN-extension process creates — the
  native core included — outside the tunnel, so the default route cannot loop
  the server connection back into the tun. On API < 22 runtimes the API does
  not exist and there is no per-socket hook into the core yet (shadowsocks-rust
  only wires its protect callback on Android); the ability logs a warning and
  the server must be reachable through a more specific route. The host tun e2e
  models the bypass by running the server in a separate network namespace.
* Third-party VPN apps on HarmonyOS NEXT require Huawei's approval for the
  VPN extension capability before store distribution.
* SIP003 plugins run **in-process** (external plugin binaries cannot be
  spawned on HarmonyOS): `obfs-local`/`simple-obfs` (http/tls) and
  `v2ray-plugin` (websocket, optional TLS) are built into the core; any other
  plugin name is rejected, and UDP does not pass through a plugin.
