# Enabling VPN support on the HarmonyOS NEXT emulator

This document collects what we learned (2026-07-24) about why VPN apps cannot
start on the public HarmonyOS NEXT emulator image, and the working ways around
it. Tested on the HarmonyOS 6.1.1 (API 24, SoftwareVersion 6.1.0.125)
`phone_all_arm` emulator image from the command-line-tools 6.1.1.280.

## 1. Why VPN start fails on the emulator

`vpnExtension.startVpnExtensionAbility(want)` rejects with "bundle not exist".

hilog shows the failure is **client-side, in the calling app's own process**
(tag `C015b0/NETMANAGER_EXT`, then `C01342/ServiceExt`):

```
NETMANAGER_EXT: StartVpnExtensionAbility SelfAppName = Shadowsocks 0
ServiceExt: [AMC599]name:com.huawei.hmos.vpndialog VpnServiceExtAbility, userId:-1
BMSCommon: bundle not exist -n com.huawei.hmos.vpndialog
```

The gating code lives in `/system/lib64/module/net/libvpnextension.z.so`
(the `@kit.NetworkKit` `vpnExtension` napi module), function
`ProcessPermissionRequests` (vaddr `0xeefc`):

1. Rejects if the target bundle is not the caller itself
   ("Not allowed to start other bundleName vpn!").
2. Queries DataShare
   `datashare:///com.ohos.settingsdata/entry/settingsdata/SETTINGSDATA?Proxy=true&key=vpnext_mode`
   with the app's bundleName.
3. **If the returned value is `"1"` → skip the dialog entirely** and fall
   through to the real IPC `NetworkVpnClient::StartVpnExtensionAbility`
   (plus an EDM check: `persist.edm.vpn_disable` throws error 201
   "disallowed setting up vpn" when set).
4. Otherwise it rewrites the want to
   `com.huawei.hmos.vpndialog/VpnServiceExtAbility` and
   `AbilityManagerClient.ConnectAbility` it — that bundle is absent from the
   public emulator image, so the start dies.

So the system consent app `com.huawei.hmos.vpndialog` (a
ServiceExtensionAbility, present on retail HarmonyOS phones) writes
`vpnext_mode = "1"` for the bundle when the user approves; the emulator image
simply does not ship it (`/system/app` contains AmsDialog, CommonDialog,
NotificationDialog, PowerDialog, etc., but no vpndialog HAP).

There is also a second, service-side dialog path in
`libnet_vpn_manager.z.so` (`NetworkVpnService::RequestVpnPermission` →
`ShowVpnDialog`), gated by the same `vpnext_mode` check (cached in-memory) and
by `persist.vpn.isPermissionCheckDefaultOpen`. It never fired in our tests.

### Things that do NOT gate the dialog

- `/system/etc/communication/netmanager_enhanced/vpn/allow_connect_vpn.json`
  (`allowConnectVpnBundleName`, `allowVpnStartWithoutCheckPermissions`,
  `isPermissionCheckDefaultOpen`). Parsed by `libnetcopilot_service.z.so` and
  consumed service-side only (the `isPermissionCheckDefaultOpen` key just
  seeds the persist param at boot). Adding our bundle had **no effect** on the
  client-side dialog.
- `/data/service/el1/public/netmanager/vpn_config.json` — this is the saved
  *active-VPN profile state* used to restore the running VPN across netmanager
  restarts (`RecoverVpnConfig`/`DestroyVpn`), not an allow list.
- `hdc shell param set persist.vpn.isPermissionCheckDefaultOpen` — the shell
  user (uid 2000) may not set persist params (errNum 1001).
- `hdc smode` — "Cannot set root run mode in undebuggable version" (release
  image, no root shell).

## 2. The workaround: settingsdata grant rows

The check reads the settingsdata store and skips the dialog when the queried
value is `"1"`. Two ways to satisfy it:

**(a) The app's own undocumented API — unreliable on the emulator build.**
`vpnExtension.updateVpnAuthorizedState(bundleName)` (absent from the SDK
d.ts) performs the designed write with no caller-identity check in native
code. On the 6.1.1 emulator the call returns 0 ("insert success" in hilog)
yet the immediately following query still returns zero rows ("go to first
row error") — the write never reaches the store the query reads. Worse,
when the dialog start fails the returned promise does not reject; it parks
on a DataShare observer (`RegisterObserver … vpnext_mode`), so an app's
catch-and-retry fallback never fires. We keep
`entry/src/main/ets/pages/VpnGrant.ts` as a harmless best-effort grant (it
may work on other builds), but it is **not** what makes the emulator work.

ArkTS note: the compiler rejects `vpnExtension as Record<...>`
(`arkts-no-ns-as-obj`), so the dynamic lookup lives in a plain-TypeScript
file (`VpnGrant.ts`), which compiles as TS where the cast is legal.

**(b) Offline grant rows in userdata — reliable (verified).** Insert into
`/data/app/el1/0/database/com.ohos.settingsdata/entry/rdb/settingsdata.db`
(tables `SETTINGSDATA` and `USER_SETTINGSDATA_100`, schema
`KEYWORD TEXT UNIQUE, VALUE TEXT`):

```sql
INSERT OR REPLACE INTO SETTINGSDATA (KEYWORD, VALUE) VALUES ('vpnext_mode', '1');
INSERT OR REPLACE INTO SETTINGSDATA (KEYWORD, VALUE) VALUES ('<your.bundle.name>', '1');
-- same two rows for USER_SETTINGSDATA_100
```

The userdata overlay (`~/.Huawei/Emulator/deployed/<name>/userdata.img.qcow2`)
is not signature-checked and persists across reboots. See §5 for the
offline-edit recipe (qemu-img convert ↔ privileged container mount; `cp` over
the existing file to keep inode/ownership, remove stale `-wal`/`-shm`). With
both rows present, `startVpnExtensionAbility` proceeds with no dialog
attempt (verified on 6.1.1: tun fd handed over, default route on `vpn-tun`,
`protectProcessNet` applied, traffic-stat endpoint up).

**Bundle rename to an allow-listed name does NOT bypass the dialog.** We
renamed the app to `com.xbt.project` (one of the five bundles in
`allow_connect_vpn.json`'s `allowConnectVpnBundleName`): the client-side
dialog was attempted exactly as before — that allow list is consumed
service-side only and matters on retail devices, not against the client-side
gate. The grant rows above are required regardless of the bundle name.

## 2a. Emulator limitation: no packets reach the tun

With the consent gate bypassed, the whole start flow succeeds on the
emulator — extension starts, `vpn-tun` is created (address 172.19.0.x, MTU
1500), the tun fd is handed to the core, `protectProcessNet` applies, the
stat endpoint listens, and the core reports "tun routing started". **But no
guest traffic is ever delivered to the tun on the public image**:

- `/proc/net/dev` counters for `vpn-tun` stay at 0 while apps generate
  traffic;
- a trace-level `ssserver` (host-side, verified logging with a local
  sslocal↔ssserver round-trip) records zero connections;
- fetches from the guest succeed anyway — they escape directly through the
  qemu slirp NAT;
- `/proc/net/route` never shows a default route via `vpn-tun` (only the
  /30 link route), although netsys logs `AddRoute … 0.0.0.0/0`.

So the missing consent app is not the only emulator gap: the policy routing
that should steer app traffic into the VPN interface does not take effect
(system-side; the same flow works on real devices). An HTTP-level e2e **over
the tun path** can therefore only pass on real hardware. Traffic handed to the
core directly — SOCKS mode — is unaffected, and that is what CI exercises on
the emulator (see below).

### On-device e2e recipe (works on a real device)

`entry/src/ohosTest/ets/test/VpnE2e.test.ets` is self-contained: it starts
`SsVpnExtensionAbility` from the test process (necessary — `aa test` tears
down a VPN started earlier from the UI), fetches a marker page
(`http://<host>:8000/e2e.txt` — set `MARKER_URL` at the top of the test to the
address of the machine serving it), then asserts the core's persisted flow
counters (`<filesDir>/store/traffic_stats.json`, see
`model/TrafficStats.ets`) moved. Host side:

```sh
ssserver -s 0.0.0.0:18388 -k test-password -m aes-256-gcm -U -v
python3 -m http.server 8000 --directory <dir-with-e2e.txt> --bind 0.0.0.0
# profile in the app: server 10.0.2.2:18388 (qemu host address), aes-256-gcm:test-password
hdc shell aa test -b com.xbt.project -m entry_test -s unittest OpenHarmonyTestRunner
```

Gotchas learned:

- hypium's default per-spec timeout is 5 s. Raise it with `-s timeout <ms>` on
  the `aa test` command line. **Not** with `Hypium.setTimeConfig(ms)`, despite
  the name: that installs a *system-time provider* object, which hypium later
  calls `.getRealTime()` on while reporting a finished spec. Handing it a
  number makes that call throw inside the reporter, and the run hangs after the
  spec body completes — the test process stays alive, logs nothing more, and
  `aa test` sits there until its own `-w` deadline.
- `aa test` disconnects a previously running VPN extension of the same bundle.
- A freshly booted image is **locked**, and `aa test` will not launch the test
  ability then ("The device screen is locked … cannot be unlocked
  automatically", because the image is in developer mode). Wake and unlock it
  first: `power-shell wakeup`, `power-shell timeout -o 2147483647` (so it does
  not dim again mid-run) and a swipe, `uinput -T -m 660 2400 660 900 200`.
- Closing a `TCPSocket` whose `connect()` is still in flight kills the test
  process outright — no JS error, no faultlog, just silence.
- The emulator's guest reaches the host at `10.0.2.2` and can also reach the
  host's LAN address directly via slirp, so a successful fetch alone proves
  nothing — the core's counters (or the server log) must be checked. The SOCKS
  e2e sidesteps this by fetching `127.0.0.1:18800`, an address only the
  host-side `ssserver` can resolve to the marker (see below).

### The e2e that *does* run on the emulator

Because §2a rules out any tun-based test here, the on-device test CI runs is
`entry/src/ohosTest/ets/test/SocksE2e.test.ets`: it starts the core in SOCKS
mode through the same NAPI entry point the app uses and pulls a marker page
through the tunnel, with a companion spec asserting the marker is unreachable
without it. `ci/hos-emulator-e2e.sh` drives the whole thing (build, sign, boot,
unlock, install, run) and is what `.github/workflows/hos-emulator.yml` invokes.

## 3. Emulator image signature verification

Every partition of the image has a signature file
(`image_signature/*.hwp7s`, PKCS#7). At every boot the host-side `Emulator`
binary verifies the base images (`CheckImage::CheckAllSign` →
`CheckImage::CheckSign`) and **refuses to boot if a base image was modified**.
Ext4 is used for all partitions (no dm-verity), so offline modification is
trivial — but the signature check defeats it.

Additional wrinkle: on each boot the emulator **re-creates the `system` (and
other read-only partitions') qcow2 overlays** from the signed base images, so
even patching only the instance's overlay does not survive a reboot. The
`userdata.img.qcow2` overlay does persist (installed apps, settings).

Conclusion: leave the base images and the `Emulator` binary pristine; any
runtime state belongs in userdata. (We did verify that patching
`CheckImage::CheckSign` in the Mach-O to `mov w0, #1; ret` at file offsets
`0xd3a954`/`0xd3a494` + ad-hoc re-sign works, but it is fragile and
unnecessary after the app-side fix — do not rely on it.)

## 4. Emulator image download region check

`Emulator -install` failed with "Currently, this capability is available only
in the Chinese mainland" even from a Shanghai egress IP. The download
endpoint (`https://device.harmonyos.com`) is selected by **locale**: with the
host locale `en_CN` the request is treated as international and refused.

Workaround — run the installer with a Chinese locale:

```sh
LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \
  Emulator -install -deviceType phone -osVersion "HarmonyOS 6.1.1(24)"
```

This downloaded the full 4.5 GB `phone_all_arm` image successfully.

## 5. Useful emulator/hdc recipes

- Tools live in `command-line-tools/`: `bin/hvigorw`, `bin/ohpm`,
  `sdk/default/openharmony/toolchains/hdc`, `emulator/Emulator`.
  Build: `DEVECO_SDK_HOME=<tools>/sdk hvigorw assembleHap --mode module -p
  product=default -p buildMode=debug`; sign with `native/sign-hap-debug.sh`
  (`OHOS_SDK_HOME=<tools>/sdk/default/openharmony`).
- The emulator often fails to auto-register with hdc
  ("can not get hdc executable" in `Emulator.log`); connect manually:
  `hdc tconn 127.0.0.1:5555`.
- UI automation: `hdc shell uitest dumpLayout` (layout JSON in
  `/data/local/tmp/`), `hdc shell "uitest uiInput click <x> <y>"`,
  `uitest uiInput keyEvent Back`.
- `hilog` streaming: run `hdc shell hilog > file` as a host-side background
  process (an in-shell `hilog &` blocks the hdc connection).
- Inspecting images offline: partitions are plain ext4; on macOS use a
  privileged Linux container (`docker run --privileged -v <imgdir>:/img
  debian:bookworm-slim`) with `mount -o loop,ro` (add `,noload` when the
  journal needs recovery), or `debugfs`. `qemu-img` (Homebrew `qemu`)
  converts between qcow2 overlays and raw.
- The userdata overlay (`~/.Huawei/Emulator/deployed/<name>/userdata.img.qcow2`)
  persists across boots and is **not** signature-checked; the settingsdata DB
  is at `/data/app/el1/0/database/com.ohos.settingsdata/entry/rdb/settingsdata.db`
  (tables `SETTINGSDATA`, `USER_SETTINGSDATA_100`, `USER_SETTINGSDATA_SECURE_100`;
  schema `KEYWORD TEXT UNIQUE, VALUE TEXT`).

## 6. References

- Reverse-engineering artifacts (disassembly of the functions cited above)
  were produced locally from the 6.1.1 emulator image; key offsets:
  - `libvpnextension.z.so`: `ProcessPermissionRequests` 0xeefc,
    `UpdateVpnAuthorize` 0xfecc, vpnext_mode URI string 0x5c9c,
    `"**vpndialog**"` marker 0x604d, `persist.edm.vpn_disable` 0x5c70.
  - `libnet_vpn_manager.z.so`: `RequestVpnPermission` 0x1dab0,
    `ShowVpnDialog` 0x1de50, `RecoverVpnConfig` 0x19878.
- The client-side gate can also be binary-patched away entirely (replace the
  first two instructions of `ProcessPermissionRequests` with `mov x0, xzr;
  ret` at file offset 0xdefc), which is what a "patched /system" approach
  would do — pointless now that the app-side grant works.
