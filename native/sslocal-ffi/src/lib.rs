/*******************************************************************************
 *                                                                             *
 *  Copyright (C) 2026 by Max Lv <max.c.lv@gmail.com>                          *
 *                                                                             *
 *  This program is free software: you can redistribute it and/or modify       *
 *  it under the terms of the GNU General Public License as published by       *
 *  the Free Software Foundation, either version 3 of the License, or          *
 *  (at your option) any later version.                                        *
 *                                                                             *
 *  This program is distributed in the hope that it will be useful,            *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of             *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the              *
 *  GNU General Public License for more details.                               *
 *                                                                             *
 *  You should have received a copy of the GNU General Public License          *
 *  along with this program. If not, see <http://www.gnu.org/licenses/>.       *
 *                                                                             *
 *******************************************************************************/

//! C ABI wrapper around `shadowsocks-service` so the HarmonyOS NEXT app can
//! drive an in-process sslocal instance through NAPI.
//!
//! All functions are safe to call from any thread. A single instance is
//! supported at a time, matching how the VPN extension ability uses it.
//!
//! SIP003 plugin fields (`plugin` / `plugin_opts`) on server entries are
//! handled in-process (see [`plugin`]): the plugin is replaced by a loopback
//! forwarder before the config reaches shadowsocks-service.

mod obfs;
mod plugin;
mod v2ray_plugin;

use std::ffi::{CStr, CString};
#[cfg(feature = "local-flow-stat")]
use std::net::SocketAddr;
use std::os::raw::{c_char, c_int};
use std::sync::Mutex;

use shadowsocks_service::config::{Config, ConfigType};
use tokio::runtime::Runtime;

/// Error codes returned by the C ABI.
pub const SSLOCAL_OK: c_int = 0;
pub const SSLOCAL_ERR_INVALID_ARG: c_int = -1;
pub const SSLOCAL_ERR_BAD_CONFIG: c_int = -2;
pub const SSLOCAL_ERR_ALREADY_RUNNING: c_int = -3;
pub const SSLOCAL_ERR_NOT_RUNNING: c_int = -4;
pub const SSLOCAL_ERR_RUNTIME: c_int = -5;

struct Instance {
    runtime: Runtime,
}

static INSTANCE: Mutex<Option<Instance>> = Mutex::new(None);
static LAST_ERROR: Mutex<Option<CString>> = Mutex::new(None);
#[cfg(feature = "local-flow-stat")]
static STAT_ADDR: Mutex<Option<SocketAddr>> = Mutex::new(None);

fn set_last_error(message: String) {
    let cstring = CString::new(message).unwrap_or_default();
    *LAST_ERROR.lock().unwrap() = Some(cstring);
}

fn parse_config_json(config_json: *const c_char) -> Result<serde_json::Value, c_int> {
    if config_json.is_null() {
        set_last_error("config_json is null".to_owned());
        return Err(SSLOCAL_ERR_INVALID_ARG);
    }
    let raw = unsafe { CStr::from_ptr(config_json) };
    let text = raw.to_str().map_err(|e| {
        set_last_error(format!("config_json is not valid UTF-8: {e}"));
        SSLOCAL_ERR_INVALID_ARG
    })?;
    serde_json::from_str(text).map_err(|e| {
        set_last_error(format!("invalid sslocal config: {e}"));
        SSLOCAL_ERR_BAD_CONFIG
    })
}

/// Where in the config JSON a plugin-bearing server entry lives. Local
/// configs address servers either as top-level "server"/"server_port" or as
/// entries of a "servers" array.
enum PluginSite {
    /// Top-level "server"/"server_port" form.
    TopLevel,
    /// Entry `i` of the "servers" array.
    Server(usize),
}

struct PluginSpec {
    site: PluginSite,
    kind: plugin::PluginKind,
    host: String,
    port: u16,
}

/// Collects SIP003 plugin specs from every server entry that declares a
/// "plugin" field, before the config is handed to shadowsocks-service.
fn extract_plugin_specs(json: &serde_json::Value) -> Result<Vec<PluginSpec>, c_int> {
    let mut specs = Vec::new();
    if json.get("plugin").is_some() {
        specs.push(extract_one_spec(json, PluginSite::TopLevel)?);
    }
    if let Some(servers) = json.get("servers").and_then(serde_json::Value::as_array) {
        for (i, entry) in servers.iter().enumerate() {
            if entry.get("plugin").is_some() {
                specs.push(extract_one_spec(entry, PluginSite::Server(i))?);
            }
        }
    }
    Ok(specs)
}

fn extract_one_spec(entry: &serde_json::Value, site: PluginSite) -> Result<PluginSpec, c_int> {
    let name = match entry.get("plugin").and_then(serde_json::Value::as_str) {
        Some(name) => name,
        None => {
            set_last_error("\"plugin\" must be a string".to_owned());
            return Err(SSLOCAL_ERR_BAD_CONFIG);
        }
    };
    let opts = entry
        .get("plugin_opts")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let kind = plugin::parse_plugin(name, opts).map_err(|e| {
        set_last_error(e.to_string());
        SSLOCAL_ERR_BAD_CONFIG
    })?;
    let host = match entry.get("server").and_then(serde_json::Value::as_str) {
        Some(host) => host.to_owned(),
        None => {
            set_last_error(format!("plugin \"{name}\" requires a \"server\" address"));
            return Err(SSLOCAL_ERR_BAD_CONFIG);
        }
    };
    let port = match entry
        .get("server_port")
        .and_then(serde_json::Value::as_u64)
        .and_then(|p| u16::try_from(p).ok())
    {
        Some(port) => port,
        None => {
            set_last_error(format!(
                "plugin \"{name}\" requires a valid \"server_port\""
            ));
            return Err(SSLOCAL_ERR_BAD_CONFIG);
        }
    };
    Ok(PluginSpec {
        site,
        kind,
        host,
        port,
    })
}

/// Starts a loopback forwarder per plugin-bearing server entry and rewrites
/// the entry to point at it, stripping the plugin fields so
/// shadowsocks-service never sees them. The forwarder tasks live on
/// `runtime` and are torn down when it is dropped.
fn apply_plugin_forwarders(
    runtime: &Runtime,
    json: &mut serde_json::Value,
    specs: Vec<PluginSpec>,
) -> Result<(), c_int> {
    for spec in specs {
        let PluginSpec {
            site,
            kind,
            host,
            port,
        } = spec;
        let local_port = match runtime.block_on(plugin::start_forwarder(kind, host.clone(), port)) {
            Ok(port) => port,
            Err(e) => {
                set_last_error(format!(
                    "failed to start plugin forwarder for {host}:{port}: {e}"
                ));
                return Err(SSLOCAL_ERR_RUNTIME);
            }
        };
        let entry = match site {
            PluginSite::TopLevel => &mut *json,
            PluginSite::Server(i) => &mut json["servers"][i],
        };
        entry["server"] = serde_json::Value::from("127.0.0.1");
        entry["server_port"] = serde_json::Value::from(local_port);
        if let Some(object) = entry.as_object_mut() {
            object.remove("plugin");
            object.remove("plugin_opts");
        }
    }
    Ok(())
}

/// Starts the instance from a config JSON value. `prepare` post-processes
/// the parsed [`Config`] (e.g. attaching a tun fd) before launch.
fn start_with_json(
    mut json: serde_json::Value,
    prepare: impl FnOnce(Config) -> Result<Config, c_int>,
) -> c_int {
    let specs = match extract_plugin_specs(&json) {
        Ok(specs) => specs,
        Err(code) => return code,
    };
    let mut guard = INSTANCE.lock().unwrap();
    if guard.is_some() {
        set_last_error("sslocal is already running".to_owned());
        return SSLOCAL_ERR_ALREADY_RUNNING;
    }
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            set_last_error(format!("failed to create tokio runtime: {e}"));
            return SSLOCAL_ERR_RUNTIME;
        }
    };
    // On any failure below the runtime is dropped, which tears down any
    // plugin forwarders spawned so far; no instance is stored.
    if let Err(code) = apply_plugin_forwarders(&runtime, &mut json, specs) {
        return code;
    }
    let config = match Config::load_from_str(&json.to_string(), ConfigType::Local) {
        Ok(config) => config,
        Err(e) => {
            set_last_error(format!("invalid sslocal config: {e}"));
            return SSLOCAL_ERR_BAD_CONFIG;
        }
    };
    #[cfg(feature = "local-flow-stat")]
    let config = attach_stat_address(config);
    let config = match prepare(config) {
        Ok(config) => config,
        Err(code) => return code,
    };
    runtime.spawn(async move {
        if let Err(e) = shadowsocks_service::run_local(config).await {
            log::error!("sslocal exited with error: {e}");
            set_last_error(format!("sslocal exited with error: {e}"));
        }
    });
    *guard = Some(Instance { runtime });
    SSLOCAL_OK
}

/// Wires the stat address set via `sslocal_set_stat_address` into the config,
/// so the core reports cumulative tx/rx counters to it the same way
/// shadowsocks-android's `local-flow-stat` channel does.
#[cfg(feature = "local-flow-stat")]
fn attach_stat_address(mut config: Config) -> Config {
    use shadowsocks_service::config::LocalFlowStatAddress;
    if let Some(addr) = *STAT_ADDR.lock().unwrap() {
        config.local_stat_addr = Some(LocalFlowStatAddress::TcpStreamAddr(addr));
    }
    config
}

/// Starts an sslocal instance from a JSON config (same schema as sslocal's
/// config file, `ConfigType::Local`). Returns 0 on success.
///
/// Server entries carrying SIP003 `plugin`/`plugin_opts` fields are served
/// by the built-in in-process plugins (obfs-local/simple-obfs, v2ray-plugin);
/// unsupported plugin names fail with `SSLOCAL_ERR_BAD_CONFIG`.
#[no_mangle]
pub extern "C" fn sslocal_start(config_json: *const c_char) -> c_int {
    match parse_config_json(config_json) {
        Ok(json) => start_with_json(json, Ok),
        Err(code) => code,
    }
}

/// Starts an sslocal instance that routes a tun device — handed out by
/// HarmonyOS `VpnConnection.create()` as a file descriptor — through the
/// shadowsocks tunnel. The config must declare a local with `"protocol":
/// "tun"`; this attaches `tun_fd` to it so the core reads/writes packets on
/// the already-configured interface instead of creating its own.
/// Requires the `local-tun` cargo feature (enabled by default).
#[no_mangle]
pub extern "C" fn sslocal_start_tun_fd(config_json: *const c_char, tun_fd: c_int) -> c_int {
    #[cfg(feature = "local-tun")]
    {
        use shadowsocks_service::config::ProtocolType;

        if tun_fd < 0 {
            set_last_error(format!("invalid tun file descriptor: {tun_fd}"));
            return SSLOCAL_ERR_INVALID_ARG;
        }
        let json = match parse_config_json(config_json) {
            Ok(json) => json,
            Err(code) => return code,
        };
        start_with_json(json, |mut config| {
            // Attach the fd to the tun local (preferred), else the sole local.
            let index = config
                .local
                .iter()
                .position(|l| l.config.protocol == ProtocolType::Tun)
                .or(if config.local.len() == 1 {
                    Some(0)
                } else {
                    None
                });
            match index {
                Some(i) => {
                    let instance = &mut config.local[i];
                    instance.config.protocol = ProtocolType::Tun;
                    instance.config.tun_device_fd = Some(tun_fd);
                    // The tun crate can only query the interface address (needed by
                    // the routing loop) when it knows the interface name. A wrapped
                    // fd carries no name, so recover it from the fd and inject it.
                    if instance.config.tun_interface_name.is_none() {
                        if let Some(name) = recover_tun_name(tun_fd) {
                            instance.config.tun_interface_name = Some(name);
                        }
                    }
                    Ok(config)
                }
                None => {
                    set_last_error(
                        "config must contain a local with \"protocol\": \"tun\"".to_owned(),
                    );
                    Err(SSLOCAL_ERR_BAD_CONFIG)
                }
            }
        })
    }
    #[cfg(not(feature = "local-tun"))]
    {
        let _ = (config_json, tun_fd);
        set_last_error("sslocal-ffi was built without the local-tun feature".to_owned());
        SSLOCAL_ERR_RUNTIME
    }
}

/// Recovers the name of the tun interface backing `fd` via TUNGETIFF, so the
/// underlying tun crate can look up the interface's address. Returns None if
/// the fd is not a tun device or the name is empty.
#[cfg(all(feature = "local-tun", target_os = "linux"))]
fn recover_tun_name(fd: c_int) -> Option<String> {
    const TUNGETIFF: libc::c_ulong = 0x8004_54d2;
    let mut ifr: libc::ifreq = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::ioctl(fd, TUNGETIFF as libc::Ioctl, &mut ifr) };
    if rc < 0 {
        return None;
    }
    let name: Vec<u8> = ifr
        .ifr_name
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8(name).ok().filter(|s| !s.is_empty())
}

#[cfg(all(feature = "local-tun", not(target_os = "linux")))]
fn recover_tun_name(_fd: c_int) -> Option<String> {
    None
}

/// Sets the loopback TCP address (e.g. "127.0.0.1:65080") the next started
/// instance reports cumulative tx/rx counters to, mirroring the traffic-stat
/// channel of shadowsocks-android. A null pointer or an empty string clears
/// the address. Takes effect on the next `sslocal_start*` call. Returns 0 on
/// success.
#[no_mangle]
pub extern "C" fn sslocal_set_stat_address(addr: *const c_char) -> c_int {
    #[cfg(feature = "local-flow-stat")]
    {
        if addr.is_null() {
            *STAT_ADDR.lock().unwrap() = None;
            return SSLOCAL_OK;
        }
        let text = match unsafe { CStr::from_ptr(addr) }.to_str() {
            Ok(text) => text,
            Err(e) => {
                set_last_error(format!("stat address is not valid UTF-8: {e}"));
                return SSLOCAL_ERR_INVALID_ARG;
            }
        };
        if text.is_empty() {
            *STAT_ADDR.lock().unwrap() = None;
            return SSLOCAL_OK;
        }
        match text.parse::<SocketAddr>() {
            Ok(socket_addr) => {
                *STAT_ADDR.lock().unwrap() = Some(socket_addr);
                SSLOCAL_OK
            }
            Err(e) => {
                set_last_error(format!("invalid stat address \"{text}\": {e}"));
                SSLOCAL_ERR_INVALID_ARG
            }
        }
    }
    #[cfg(not(feature = "local-flow-stat"))]
    {
        let _ = addr;
        set_last_error("sslocal-ffi was built without the local-flow-stat feature".to_owned());
        SSLOCAL_ERR_RUNTIME
    }
}

/// Stops the running instance. Returns 0 on success.
#[no_mangle]
pub extern "C" fn sslocal_stop() -> c_int {
    let mut guard = INSTANCE.lock().unwrap();
    match guard.take() {
        Some(instance) => {
            // Drop all spawned tasks without blocking the caller.
            instance.runtime.shutdown_background();
            SSLOCAL_OK
        }
        None => {
            set_last_error("sslocal is not running".to_owned());
            SSLOCAL_ERR_NOT_RUNNING
        }
    }
}

/// Returns 1 while an instance is running, 0 otherwise.
#[no_mangle]
pub extern "C" fn sslocal_is_running() -> c_int {
    INSTANCE.lock().unwrap().is_some() as c_int
}

/// Returns the last error message, or null if none occurred. The pointer is
/// valid until the next FFI call that records an error.
#[no_mangle]
pub extern "C" fn sslocal_last_error() -> *const c_char {
    match &*LAST_ERROR.lock().unwrap() {
        Some(message) => message.as_ptr(),
        None => std::ptr::null(),
    }
}

/// Returns the crate version as a static NUL-terminated string.
#[no_mangle]
pub extern "C" fn sslocal_version() -> *const c_char {
    static VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");
    VERSION.as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_not_null() {
        let version = sslocal_version();
        assert!(!version.is_null());
        let text = unsafe { CStr::from_ptr(version) }.to_str().unwrap();
        assert_eq!(text, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn start_rejects_null_and_garbage() {
        assert_eq!(sslocal_start(std::ptr::null()), SSLOCAL_ERR_INVALID_ARG);
        let garbage = CString::new("not json").unwrap();
        assert_eq!(sslocal_start(garbage.as_ptr()), SSLOCAL_ERR_BAD_CONFIG);
        assert!(!sslocal_last_error().is_null());
    }

    #[test]
    fn start_rejects_unsupported_plugin() {
        let config = CString::new(
            r#"{"server":"127.0.0.1","server_port":8388,"password":"p","method":"aes-256-gcm","plugin":"kcptun"}"#,
        )
        .unwrap();
        assert_eq!(sslocal_start(config.as_ptr()), SSLOCAL_ERR_BAD_CONFIG);
        assert!(!sslocal_last_error().is_null());
    }

    #[test]
    fn stop_without_start_fails() {
        assert_eq!(sslocal_stop(), SSLOCAL_ERR_NOT_RUNNING);
    }

    #[cfg(feature = "local-flow-stat")]
    #[test]
    fn set_stat_address_parses_and_clears() {
        // garbage is rejected (and leaves the stored address untouched)
        let garbage = CString::new("not an address").unwrap();
        assert_eq!(
            sslocal_set_stat_address(garbage.as_ptr()),
            SSLOCAL_ERR_INVALID_ARG
        );
        assert!(!sslocal_last_error().is_null());
        assert_eq!(*STAT_ADDR.lock().unwrap(), None);

        // a valid loopback address is stored
        let addr = CString::new("127.0.0.1:65080").unwrap();
        assert_eq!(sslocal_set_stat_address(addr.as_ptr()), SSLOCAL_OK);
        assert_eq!(
            *STAT_ADDR.lock().unwrap(),
            Some("127.0.0.1:65080".parse().unwrap())
        );

        // garbage must not clobber a previously stored address
        assert_eq!(
            sslocal_set_stat_address(garbage.as_ptr()),
            SSLOCAL_ERR_INVALID_ARG
        );
        assert_eq!(
            *STAT_ADDR.lock().unwrap(),
            Some("127.0.0.1:65080".parse().unwrap())
        );

        // empty string and null clear the address
        let empty = CString::new("").unwrap();
        assert_eq!(sslocal_set_stat_address(empty.as_ptr()), SSLOCAL_OK);
        assert_eq!(*STAT_ADDR.lock().unwrap(), None);
        assert_eq!(sslocal_set_stat_address(addr.as_ptr()), SSLOCAL_OK);
        assert_eq!(sslocal_set_stat_address(std::ptr::null()), SSLOCAL_OK);
        assert_eq!(*STAT_ADDR.lock().unwrap(), None);
    }

    #[test]
    fn start_tun_fd_rejects_negative_fd() {
        let config = CString::new(
            r#"{"locals":[{"protocol":"tun","tun_interface_address":"172.19.0.1/30"}],"server":"127.0.0.1","server_port":8388,"password":"p","method":"aes-256-gcm"}"#,
        )
        .unwrap();
        assert_eq!(
            sslocal_start_tun_fd(config.as_ptr(), -1),
            SSLOCAL_ERR_INVALID_ARG
        );
    }

    #[test]
    fn start_tun_fd_requires_a_local() {
        // no locals at all -> bad config
        let config = CString::new(
            r#"{"locals":[],"server":"127.0.0.1","server_port":8388,"password":"p","method":"aes-256-gcm"}"#,
        )
        .unwrap();
        assert_eq!(
            sslocal_start_tun_fd(config.as_ptr(), 3),
            SSLOCAL_ERR_BAD_CONFIG
        );
    }
}
