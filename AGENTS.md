# Shadowsocks for HarmonyOS NEXT — Agent Guide

## Project overview

A native Shadowsocks client for **HarmonyOS NEXT (5.x)**, which has no Android
runtime. It is a subproject of the shadowsocks-android repository (this
directory is `harmony/` in that repo) and shares the same Rust core
(`shadowsocks-rust`) with the Android app through a C ABI + NAPI bridge.

- **App layer**: ArkTS/ArkUI, Stage model, API 12+ (`compatibleSdkVersion
  5.0.0(12)`), bundle `com.xbt.project`, version 5.3.5,
  GPL-3.0-or-later.
- **Native layer**: the Rust crate `native/sslocal-ffi` path-depends on
  `../../../core/src/main/rust/shadowsocks-rust/crates/shadowsocks-service`
  (i.e. `<repo-root>/core/...` — the checkout one level above this directory
  must contain the `core/` module for any Rust build to work).
- **Bridge**: a C++ NAPI shim (`entry/src/main/cpp/napi_init.cpp`) is compiled
  by CMake into `libsslocal.so`, linked against the Rust staticlib
  `libsslocal_core.a`.

## Repository layout

```
AppScope/app.json5            application-level config (bundle name, version)
entry/                        main (and only) HAP module
  build-profile.json5         stageMode; external native build via CMake, arm64-v8a only
  src/main/
    module.json5              EntryAbility + SsVpnExtensionAbility (type: vpn),
                              permissions: INTERNET, GET_NETWORK_INFO
    ets/entryability/         EntryAbility.ets — UIAbility entry; registers the
                              ability context in AppStorage (see AppContext.ets)
    ets/pages/                Index.ets (profile list + connect + stats bar),
                              ProfileEdit.ets (profile form, method/route/plugin
                              pickers), Subscription.ets (subscription management),
                              VpnGrant.ts (undocumented updateVpnAuthorizedState
                              shim for the emulator's missing consent app)
    ets/model/                Profile.ets (SIP002 ss:// parsing, config
                              serialization), ProfileStore.ets (multi-profile
                              list + selection), Subscription.ets (subscription
                              fetch/parse: base64 ss:// lists and SIP008 JSON),
                              Routes.ets (policy-route constants ↔ ACL files),
                              TrafficStats.ets (cross-process stats bridge),
                              JsonStore.ets (JSON-file persistence), AppContext.ets
    ets/vpnability/           SsVpnExtensionAbility.ets — VpnExtensionAbility
                              that drives the native core in tun mode; deploys
                              the route's ACL file and hosts the flow-stat
                              endpoint
    resources/rawfile/acl/    ACL files for policy routes, copied verbatim from
                              shadowsocks-android's core/src/main/assets/acl
    cpp/napi_init.cpp         NAPI shim; exports the libsslocal.so module
    cpp/CMakeLists.txt        builds libsslocal.so, links libsslocal_core.a
    cpp/types/libsslocal/     ArkTS typings (Index.d.ts) for libsslocal.so
  src/test/                   ArkTS unit tests (hypium): ss:// URL parsing
                              (incl. SIP003 plugin query), SOCKS and tun config
                              serialization (incl. ACL injection, plugin fields),
                              subscription body parsing
  src/ohosTest/               on-device tests: NAPI surface (incl. startTunFd),
                              SOCKS tunnel e2e (emulator-capable, run by CI),
                              VPN/tun e2e (real devices only)
native/
  sslocal-ffi/                Rust crate: C ABI over shadowsocks-service
    src/lib.rs                extern "C" API: sslocal_start, sslocal_start_tun_fd,
                              sslocal_stop, sslocal_is_running, sslocal_last_error,
                              sslocal_version; single-instance model; intercepts
                              SIP003 plugin fields before handing the config to
                              shadowsocks-service
    src/plugin.rs             SIP003 plugin dispatch + loopback forwarder
    src/obfs.rs               simple-obfs http/tls client wrappers, vendored
                              from meow-rs (GPL-3.0)
    src/v2ray_plugin.rs       v2ray-plugin ws(+tls) client, adapted from
                              meow-rs on top of the meow-transport crate
    tests/e2e.rs              in-process server + sslocal via the C ABI + SOCKS5
                              round-trip through the encrypted tunnel
    tests/e2e_plugin.rs       same, with the connection obfuscated through the
                              in-process simple-obfs plugin (fake obfs server
                              shim in front of the in-process ssserver)
    examples/net_helper.rs    helper binary used by the tun e2e
  build-ohos.sh               cross-compile the Rust core for
                              aarch64-unknown-linux-ohos; installs the staticlib
                              into entry/libs/arm64-v8a/
  sign-hap-debug.sh           ad-hoc debug signing with the OpenHarmony sample
                              signing materials (no Huawei account)
  ohos-cc-wrapper.sh          zig cc shim so `cargo check` works without the
                              OHOS NDK (compile-only; final linking needs the SDK)
  tun-e2e-linux.sh            tun packet-routing e2e (Linux + root)
  run-tun-e2e-docker.sh       runs the tun e2e in a privileged container
                              (works from macOS; needs cargo-zigbuild + Docker)
ci/
  hos-emulator-e2e.sh         on-device e2e driver: builds + signs both HAPs,
                              boots/unlocks the emulator, installs, runs the
                              ohosTest suites against a host-side ssserver
  package-hos-toolchain.sh    packs the DevEco tools + emulator image and
                              uploads them to the private CI bucket
  r2-env.sh                   sourced helper: derives S3 credentials for that
                              bucket from R2_API_TOKEN + R2_ENDPOINT
test-e2e-host.sh              host-side verification entry point (see Testing)
```

Generated/ignored paths: `entry/libs/` (Rust staticlib output), `**/build`,
`.hvigor/`, `oh_modules/`, `native/sslocal-ffi/target`, `native/.tun-e2e`.

## Technology stack and runtime architecture

- ArkTS/ArkUI (Stage model) + C++ NAPI + Rust (`shadowsocks-service`, tokio,
  smoltcp for the tun stack).
- Build orchestration: **hvigor** (`hvigorw`), dependencies via **ohpm**.
  Root `oh-package.json5` has only devDependencies (`@ohos/hypium`,
  `@ohos/hamock`); `entry/oh-package.json5` maps `libsslocal.so` to the local
  typings package.
- Runtime flow: `EntryAbility` shows `Index.ets` (the profile list, mirroring
  shadowsocks-android's main screen); connecting starts
  `SsVpnExtensionAbility`, which creates the system VPN via
  `vpnExtension.createVpnConnection` (default route 0.0.0.0/0, tun address
  172.19.0.1/30, DNS 1.1.1.1), then hands the tun fd to the core with
  `sslocal.startTunFd(profile.toTunConfig(aclPath), tunFd)`. The core's
  smoltcp-based tun stack terminates TCP/UDP flows and re-establishes them
  through the shadowsocks tunnel — the role tun2socks plays in the Android
  client. `sslocal_start_tun_fd` **dups** the descriptor so the core owns its
  own copy: the tun device closes the fd it was given when the runtime is torn
  down (in the background, see `sslocal_stop`), while `VpnConnection.destroy()`
  closes the app's — sharing one number would risk a second close landing on an
  unrelated descriptor.
- **Policy routes**: each profile carries a `route` (the same constants as
  shadowsocks-android's `Acl`: `all`, `bypass-lan`, `bypass-china`,
  `bypass-lan-china`, `gfwlist`, `china-list`). For any route ≠ `all` the VPN
  ability deploys the matching rawfile ACL (`resources/rawfile/acl/<name>.acl`,
  copied from shadowsocks-android) to `filesDir/acl/` and injects it as the
  core config's top-level `acl` field; the core then connects matching
  destinations directly instead of through the tunnel.
- **Traffic stats**: the core (built with `local-flow-stat`) reports
  cumulative tx/rx counters to a loopback TCP endpoint every 500 ms (16-byte
  little-endian u64 pair, the wire format shadowsocks-android's
  TrafficMonitor consumes). The VPN ability hosts that endpoint
  (`TCPSocketServer`, first free port from 65080 up) via
  `sslocal.setStatAddress` and persists each sample through
  `TrafficStatsStore`; the UI process polls it once a second and computes
  rates from consecutive samples.
- **Server-connection bypass**: `VpnConnection.protectProcessNet()` (API 22+)
  keeps every socket the VPN-extension process creates (the native core
  included) outside the tunnel. On API < 22 there is no per-socket hook; the
  ability logs a warning and the server must be reachable through a more
  specific route.
- **SIP003 plugins**: profiles carry `plugin`/`pluginOpts` (parsed from the
  `?plugin=` query of ss:// URLs, editable in ProfileEdit) which the
  serializers emit as the standard `plugin`/`plugin_opts` server fields.
  `sslocal-ffi` intercepts those fields before `Config::load_from_str` —
  external plugin processes cannot be spawned on HarmonyOS, so known plugins
  run **in-process**: for each server entry with a plugin it starts a
  loopback TCP forwarder (127.0.0.1, ephemeral port) that dials the real
  server and wraps the stream in the obfuscation layer, then rewrites the
  entry's `server`/`server_port` to the forwarder and strips the plugin
  fields, exactly as if an external `obfs-local` were running. Supported
  names: `obfs-local`/`simple-obfs`/`obfs` (`obfs=http|tls;obfs-host=…`) and
  `v2ray-plugin` (`mode=websocket`, optional `tls`, `host`, `path`,
  `header=K:V`, `skip-cert-verify`); any other name fails the start with
  `SSLOCAL_ERR_BAD_CONFIG`. The obfuscation code is reused from
  [meow-rs](https://github.com/madeye/meow-rs) (GPL-3.0): the
  `meow-transport` crate (git dependency, tag v0.18.0, TLS + WebSocket
  layers) plus `simple_obfs.rs`/`v2ray_plugin.rs` vendored/adapted into
  `native/sslocal-ffi/src/` — do not "upgrade" the vendored copies blindly;
  `obfs.rs` carries a local fix in `HttpObfs::poll_read` (a 0-byte
  header-only read must not surface as EOF to `copy_bidirectional`). UDP is
  not transported through plugins (neither plugin supports it upstream).
- NAPI surface (see `entry/src/main/cpp/types/libsslocal/Index.d.ts`):
  `start(configJson)`, `startTunFd(configJson, tunFd)`,
  `setStatAddress(addr)`, `stop()`,
  `isRunning()`, `lastError()`, `version()`. C ABI return codes are defined in
  `native/sslocal-ffi/src/lib.rs` (`SSLOCAL_OK = 0`, negative on error; call
  `lastError()` for the message). Only one instance may run at a time.
  `setStatAddress("127.0.0.1:port")` makes the next started instance report
  cumulative tx/rx counters (16 bytes, two native-endian u64, every 500ms) to
  that loopback TCP address, like shadowsocks-android's traffic-stat channel.

## Build

Prerequisites:

- DevEco Studio 5.x with the HarmonyOS NEXT SDK (API 12+)
- Rust with `rustup target add aarch64-unknown-linux-ohos`
- OpenHarmony native SDK: `export OHOS_NDK_HOME=…/ohos-sdk/native`
  (or `…/command-line-tools/sdk/default/openharmony/native`)

Steps (order matters — the CMake build fails if the staticlib is missing):

1. `native/build-ohos.sh` — builds `libsslocal_core.a` (release by default;
   override with `TARGET`/`ABI`/`PROFILE` env vars) and installs it into
   `entry/libs/arm64-v8a/`.
2. `ohpm install`.
3. Build the HAP:

   ```sh
   export DEVECO_SDK_HOME=<command-line-tools>/sdk
   hvigorw assembleHap --mode module -p product=default -p buildMode=debug
   ```

   Output: `entry/build/default/outputs/default/entry-default-unsigned.hap`.
4. Debug-sign without a Huawei account:
   `native/sign-hap-debug.sh <unsigned.hap>` → `entry-default-signed.hap`.
   Release signing / store distribution needs a Huawei developer account;
   third-party VPN apps also need Huawei's approval for the VPN extension
   capability.
5. Install/run: `hdc -t <target> install entry-default-signed.hap`.

## Testing

- **`./test-e2e-host.sh [tests|cross|tun ...]`** — host-side verification, no
  HarmonyOS SDK needed. All three steps by default, or any subset by name (CI
  runs one per workflow, so this stays the single definition of each):
  1. `cargo test` in `native/sslocal-ffi` (includes `tests/e2e.rs`: a genuine
     end-to-end SOCKS5 round-trip through an in-process shadowsocks server,
     driving sslocal through the same C ABI the NAPI layer uses).
  2. `cargo check --target aarch64-unknown-linux-ohos` (real OHOS SDK clang if
     `OHOS_NDK_HOME` is set, else the zig cc shim).
  3. Tun packet-routing e2e (`native/tun-e2e-linux.sh`): a real TCP flow into
     a tun device, asserted to round-trip through the tunnel. Needs Linux,
     `/dev/net/tun` and CAP_NET_ADMIN — run as root, or as any user with
     passwordless sudo (the script escalates itself); on macOS run it via
     `native/run-tun-e2e-docker.sh` (Docker + cargo-zigbuild), which builds
     the helper for the host architecture so the container runs it natively.
- **CI** — one workflow per surface, so a failure names what broke instead of
  pointing at one big job:
  - `lint.yml` — rustfmt, clippy (`--no-deps`; the path-dependency would
    otherwise be linted too) and shellcheck over every script.
  - `test-core.yml` — `./test-e2e-host.sh tests`.
  - `test-cross.yml` — `./test-e2e-host.sh cross` (with `mlugg/setup-zig`).
  - `test-tun.yml` — `./test-e2e-host.sh tun` with `TUN_E2E_REQUIRED=1`, so a
    missing `/dev/net/tun` fails the job instead of skipping quietly.

  All four gate every push and pull request. Shared setup — the sibling
  `shadowsocks-rust` checkout (this crate path-depends on it), the Rust
  toolchain and the cargo cache — lives in the composite action
  `.github/actions/rust-core`, whose `ref` input is the single place the core's
  pin is defined; keep it in step with shadowsocks-android's submodule.

  **Nothing that needs the HarmonyOS SDK runs in CI**: the HAP build, debug
  signing, the ArkTS unit tests and the on-device suites are all local-only,
  because Huawei's DevEco command-line tools are neither publicly downloadable
  (`docs/hos-emulator-vpn.md` §4) nor redistributable. Do not add a workflow
  that assumes a runner can fetch them.

  There was such a setup — the tools came from a private S3/R2 bucket — and it
  was removed once the bucket was emptied. `ci/package-hos-toolchain.sh` (packs
  and uploads a bundle) and `ci/r2-env.sh` (derives S3 credentials from a
  Cloudflare API token, since R2 takes the token's ID plus the SHA-256 of its
  value) survive as the tooling to restore it; the workflows are in the history
  of the commit that removed them. Facts worth keeping from that round, should
  it come back:
  - The Linux toolchain must be stored as Huawei's zip **verbatim** — it holds
    19 paths differing only in case, which a case-insensitive filesystem
    collapses, so it can never be repacked on macOS.
  - On Linux, `restool`'s `libimage_transcoder_shared.so` links against libGL
    (`libgl1` must be installed before `@CompileResource`).
  - The ArkTS unit tests cannot run on Linux at all: their runner drives the
    SDK previewer, whose Linux build is missing `libshared_libz.so` entirely
    and links `libhilog.so` while the SDK ships only `libhilog_linux.so`. The
    specs silently never execute — a deliberately failing spec produces no
    output — so a Linux "pass" would be meaningless.
  - The emulator needs HVF and is macOS/Windows-only, so no GitHub-hosted
    runner can run it; only a self-hosted Apple-silicon machine can.

- **ArkTS unit tests** — `entry/src/test` (hypium): `ss://` URL parsing, both
  SOCKS and tun config serialization (including ACL injection), subscription
  body parsing. Run from DevEco Studio or headless:
  `hvigorw test --mode module -p module=entry -p product=default`
  (failures show up as `Error in <test name>` lines).
- **On-device tests** — `entry/src/ohosTest`, run from DevEco Studio or
  headless via **`ci/hos-emulator-e2e.sh`** (`HOS_TOOLS=<command-line-tools>
  HOS_IMAGES=~/Library/Huawei/Sdk ci/hos-emulator-e2e.sh`), which builds and
  signs both HAPs, boots + unlocks the emulator, installs, starts a host-side
  `ssserver` and marker page, and runs the suites. `SKIP_EMULATOR=1` reuses an
  already-running emulator, `KEEP_EMULATOR=1` leaves it up.
  - `SslocalNativeTest` — NAPI surface, including `startTunFd` rejection paths.
  - `SocksE2eTest` — the emulator-capable e2e: the core is started in SOCKS
    mode and a marker page is fetched *through* the tunnel, addressed as
    `127.0.0.1:18800` so only the host-side `ssserver` can resolve it; a
    second spec asserts the guest cannot reach it directly.
  - `VpnE2eTest` — excluded from CI: the emulator never delivers guest traffic
    to `vpn-tun` (`docs/hos-emulator-vpn.md` §2a), so it needs real hardware.
  Writing on-device tests: raise hypium's 5s per-spec timeout with
  `-s timeout <ms>` on `aa test`, **never** `Hypium.setTimeConfig()` (it sets a
  system-time provider, and a number there hangs the whole run); never close a
  `TCPSocket` whose `connect()` is still in flight (it kills the test process
  silently); a freshly booted image must be unlocked before `aa test` can
  launch anything.

## Code style and conventions

- Documentation and comments are in English; follow the shadowsocks project
  conventions.
- C/C++ and ArkTS source files carry the GPL-3.0 copyright header block seen
  in existing files — keep it on new files.
- Rust: edition 2021, `publish = false`; the crate is a standalone workspace
  (`[workspace]` in its Cargo.toml). Default features `local-tun` (direct
  tun-device support) and `local-flow-stat` (traffic-stat reporting) must
  stay on for the HarmonyOS app.
- ArkTS: Stage-model idioms, imports from `@kit.*` kits; the native module is
  imported as `import sslocal from 'libsslocal.so'`. State flows:
  `Profile` ↔ `ProfileStore` (persistence) ↔ JSON config consumed by the core.
- Persistence uses `JsonStore` (JSON files under `filesDir/store/`, atomic
  tmp+rename writes), **not** @ohos.data.preferences: preferences rejects
  contexts without a bound ability ("401 context is invalid" on API 24) and
  is unsafe to share across processes, while the UI and VPN-extension
  processes must exchange state. Both abilities belong to the same HAP, so
  their `filesDir` is the same directory.
- Pages must not declare a `context` property/getter: it collides with the
  component framework's internal field and silently resolves to `undefined`.
  Use `abilityContext()` from `model/AppContext.ets` (the real UIAbility
  context registered by `EntryAbility`); the deprecated `getContext(this)`
  returns a context that API 24 runtimes reject in data-kit calls.
- The host-side unit-test runtime (`hvigorw test`) has no native util codecs —
  `util.Base64Helper`, `util.TextDecoder/TextEncoder` and
  `util.generateRandomUUID` are unavailable there. `Profile.ets` therefore
  implements base64/UTF-8/uuid in pure ArkTS; keep it that way.
- Keep the three config serializers in sync: `Profile.toTunConfig()` /
  SOCKS config in `entry/src/main/ets/model/Profile.ets`, their unit tests in
  `entry/src/test/`, and the parsing in the Rust core
  (`Config::load_from_str(text, ConfigType::Local)`).

## Security considerations

- Profiles contain server passwords; they are persisted by `ProfileStore`
  via the app sandbox — do not log them or add them to any external channel.
- Never read or copy signing material beyond what `native/sign-hap-debug.sh`
  handles; the debug signing materials are the public OpenHarmony samples,
  not real credentials.
- The VPN runs a default route capturing all device traffic; any change to
  routing in `SsVpnExtensionAbility` must preserve the server-connection
  bypass (`protectProcessNet`), otherwise the tunnel loops on itself.
- Do not weaken cipher defaults; the core is built with `aead-cipher` and
  `aead-cipher-2022` only (no stream ciphers).

## Known gaps

- SIP003 plugins: only the built-in `obfs-local` (simple-obfs http/tls) and
  `v2ray-plugin` (mode=websocket, optional TLS) are supported, run in-process
  by the native core (see "SIP003 plugins" above); other plugin names are
  rejected (external plugin processes cannot be spawned on HarmonyOS). UDP
  does not pass through plugins (neither plugin supports UDP upstream either);
  with a plugin active, UDP associations time out.
- No `custom-rules` route (shadowsocks-android's user-edited ACL); only the
  six preset routes.
- Starting the VPN normally requires the system consent app
  `com.huawei.hmos.vpndialog`, which is **absent from the public OpenHarmony
  emulator image**. Working around it requires writing the settingsdata
  grant (`vpnext_mode → "1"` plus a bundle-keyed row) into the userdata
  settingsdata DB offline; `Index.ets` additionally calls the undocumented
  `vpnExtension.updateVpnAuthorizedState` (via `pages/VpnGrant.ts`) as a
  best-effort runtime grant (ineffective on the 6.1.1 emulator build — the
  write never reaches the queried store). The full VPN flow (tun routing,
  stats, ACL) is verified working on the 6.1.1 emulator with the grant rows
  present. Background and recipes: `docs/hos-emulator-vpn.md`.
- The UI's connected state is local to the page: it does not survive an app
  restart (no VPN-state query is wired up yet).
- API < 22 runtimes lack `protectProcessNet`; see the bypass note above.
- HarmonyOS 2–4 devices run Android APKs and are out of scope (covered by the
  main project's `freedom` flavor).
