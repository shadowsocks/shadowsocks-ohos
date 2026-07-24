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

//! SIP003 plugin support, implemented in-process.
//!
//! Spawning external plugin binaries is impossible on HarmonyOS, so the
//! two most common SIP003 plugins are built in:
//!
//! - `obfs-local` / `simple-obfs` (`obfs=http|tls;obfs-host=...`), via the
//!   vendored [`crate::obfs`] wrappers;
//! - `v2ray-plugin` (WebSocket, optionally over TLS), via
//!   [`crate::v2ray_plugin`] and the `meow-transport` layers.
//!
//! Client-side SIP003 semantics are preserved with a loopback forwarder:
//! [`start_forwarder`] binds `127.0.0.1:0` and relays every accepted
//! connection through the plugin wrapper to the real server, so the
//! shadowsocks core only ever sees a plain `127.0.0.1:<port>` server entry.
//!
//! UDP through plugins is out of scope: neither simple-obfs nor
//! v2ray-plugin (WebSocket) carries UDP upstream, so plugin-enabled servers
//! relay TCP only.

use std::fmt;
use std::time::Duration;

use tokio::net::{TcpListener, TcpStream};

use crate::obfs;
use crate::v2ray_plugin::{self, V2rayPluginConfig};

/// Back-off between retries after a transient accept failure, so a resource
/// shortage cannot turn the accept loop into a busy loop.
const ACCEPT_RETRY_DELAY: Duration = Duration::from_millis(100);

/// Whether an `accept` error concerns only the pending connection (retry) as
/// opposed to the listening socket itself (give up).
fn is_transient_accept_error(e: &std::io::Error) -> bool {
    use std::io::ErrorKind;
    matches!(
        e.kind(),
        ErrorKind::ConnectionAborted
            | ErrorKind::ConnectionReset
            | ErrorKind::Interrupted
            | ErrorKind::WouldBlock
            | ErrorKind::TimedOut
    ) || matches!(
        e.raw_os_error(),
        // EMFILE / ENFILE / ENOBUFS / ENOMEM: out of descriptors or buffers;
        // the listener survives, so keep it and retry after a back-off.
        Some(libc::EMFILE) | Some(libc::ENFILE) | Some(libc::ENOBUFS) | Some(libc::ENOMEM)
    )
}

/// A parsed SIP003 plugin specification.
#[derive(Debug, Clone)]
pub enum PluginKind {
    /// simple-obfs in HTTP mode (`obfs=http`). Empty host falls back to the
    /// server host.
    SimpleObfsHttp { host: String },
    /// simple-obfs in TLS mode (`obfs=tls`). Empty host falls back to the
    /// server host.
    SimpleObfsTls { host: String },
    /// v2ray-plugin (WebSocket, optionally over TLS).
    V2ray(V2rayPluginConfig),
}

/// Errors produced while parsing or applying a SIP003 plugin.
#[derive(Debug)]
pub enum PluginError {
    /// The plugin name is not one of the built-in plugins.
    Unsupported(String),
    /// The plugin options string is malformed or misses required keys.
    InvalidOptions(String),
    /// I/O failure (connecting, relaying).
    Io(std::io::Error),
    /// Failure inside a `meow-transport` layer (TLS/WS handshake, config).
    Transport(meow_transport::TransportError),
}

impl fmt::Display for PluginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PluginError::Unsupported(name) => write!(
                f,
                "plugin \"{name}\" is not supported: spawning external plugin \
                 processes is impossible on HarmonyOS; built-in plugins are \
                 obfs-local (simple-obfs) and v2ray-plugin"
            ),
            PluginError::InvalidOptions(message) => write!(f, "{message}"),
            PluginError::Io(e) => write!(f, "io: {e}"),
            PluginError::Transport(e) => write!(f, "transport: {e}"),
        }
    }
}

impl std::error::Error for PluginError {}

impl From<std::io::Error> for PluginError {
    fn from(e: std::io::Error) -> Self {
        PluginError::Io(e)
    }
}

impl From<meow_transport::TransportError> for PluginError {
    fn from(e: meow_transport::TransportError) -> Self {
        PluginError::Transport(e)
    }
}

/// Parses a SIP003 `plugin` name plus its `plugin_opts` string.
pub fn parse_plugin(name: &str, opts: &str) -> Result<PluginKind, PluginError> {
    match name {
        "obfs-local" | "simple-obfs" | "obfs" => parse_simple_obfs_opts(opts),
        "v2ray-plugin" => v2ray_plugin::parse_opts(opts).map(PluginKind::V2ray),
        other => Err(PluginError::Unsupported(other.to_owned())),
    }
}

/// Parses simple-obfs SIP003 opts: `obfs=http|tls;obfs-host=example.com`
/// (`;`-separated `k=v`, bare keys allowed; unknown keys are ignored).
fn parse_simple_obfs_opts(opts: &str) -> Result<PluginKind, PluginError> {
    let mut mode: Option<String> = None;
    let mut host = String::new();

    for token in opts.split(';').map(str::trim).filter(|t| !t.is_empty()) {
        let (key, value) = match token.split_once('=') {
            Some((k, v)) => (k.trim(), v.trim()),
            None => (token, ""),
        };
        match key {
            "obfs" => mode = Some(value.to_owned()),
            "obfs-host" => host = value.to_owned(),
            other => log::warn!("simple-obfs: ignoring unknown opt '{other}'"),
        }
    }

    match mode.as_deref() {
        Some("http") => Ok(PluginKind::SimpleObfsHttp { host }),
        Some("tls") => Ok(PluginKind::SimpleObfsTls { host }),
        Some(other) => Err(PluginError::InvalidOptions(format!(
            "simple-obfs: unknown obfs mode '{other}' (expected 'http' or 'tls')"
        ))),
        None => Err(PluginError::InvalidOptions(
            "simple-obfs: missing 'obfs=http|tls' option".to_owned(),
        )),
    }
}

impl PluginKind {
    /// Connects to `server_host:server_port` and wraps the stream with this
    /// plugin's obfuscation layer.
    pub async fn wrap_stream(
        &self,
        server_host: &str,
        server_port: u16,
    ) -> Result<Box<dyn meow_transport::Stream>, PluginError> {
        match self {
            PluginKind::SimpleObfsHttp { host } => {
                let tcp = TcpStream::connect((server_host, server_port)).await?;
                let host = if host.is_empty() { server_host } else { host };
                Ok(Box::new(obfs::HttpObfs::new(
                    tcp,
                    host.to_owned(),
                    server_port,
                )))
            }
            PluginKind::SimpleObfsTls { host } => {
                let tcp = TcpStream::connect((server_host, server_port)).await?;
                let host = if host.is_empty() { server_host } else { host };
                Ok(Box::new(obfs::TlsObfs::new(tcp, host.to_owned())))
            }
            // v2ray-plugin's dial connects TCP itself (TLS SNI / Host header
            // fallbacks depend on the server address).
            PluginKind::V2ray(cfg) => v2ray_plugin::dial(cfg, server_host, server_port).await,
        }
    }
}

/// Starts a loopback forwarder implementing client-side SIP003 semantics:
/// every connection accepted on `127.0.0.1:0` is relayed through the plugin
/// wrapper to `server_host:server_port`. Returns the bound port.
///
/// The accept loop and per-connection tasks are spawned on the caller's
/// tokio runtime and die with it — that is the intended lifecycle.
pub async fn start_forwarder(
    kind: PluginKind,
    server_host: String,
    server_port: u16,
) -> std::io::Result<u16> {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
    let port = listener.local_addr()?.port();
    log::info!("plugin forwarder for {server_host}:{server_port} listening on 127.0.0.1:{port}");
    tokio::spawn(async move {
        loop {
            let (mut inbound, peer) = match listener.accept().await {
                Ok(pair) => pair,
                // Per-connection errors (a peer that vanished between the
                // SYN and the accept, a momentary fd shortage) are expected
                // and retried; anything else means the listener itself is
                // gone, and retrying it would spin the CPU forever.
                Err(e) if is_transient_accept_error(&e) => {
                    log::warn!("plugin forwarder: accept failed: {e}, retrying");
                    tokio::time::sleep(ACCEPT_RETRY_DELAY).await;
                    continue;
                }
                Err(e) => {
                    log::error!("plugin forwarder: accept failed fatally: {e}, giving up");
                    return;
                }
            };
            let kind = kind.clone();
            let server_host = server_host.clone();
            tokio::spawn(async move {
                match kind.wrap_stream(&server_host, server_port).await {
                    Ok(mut wrapped) => {
                        if let Err(e) =
                            tokio::io::copy_bidirectional(&mut inbound, &mut wrapped).await
                        {
                            log::warn!("plugin forwarder: relay for {peer} ended with error: {e}");
                        }
                    }
                    Err(e) => {
                        log::warn!(
                            "plugin forwarder: connect to {server_host}:{server_port} failed: {e}"
                        );
                    }
                }
            });
        }
    });
    Ok(port)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::v2ray_plugin::Mode;

    #[test]
    fn parse_obfs_local_http() {
        let kind = parse_plugin("obfs-local", "obfs=http;obfs-host=www.example.com").unwrap();
        match kind {
            PluginKind::SimpleObfsHttp { host } => assert_eq!(host, "www.example.com"),
            other => panic!("expected SimpleObfsHttp, got {other:?}"),
        }
    }

    #[test]
    fn parse_simple_obfs_tls() {
        let kind = parse_plugin("simple-obfs", "obfs=tls;obfs-host=cdn.example.com").unwrap();
        match kind {
            PluginKind::SimpleObfsTls { host } => assert_eq!(host, "cdn.example.com"),
            other => panic!("expected SimpleObfsTls, got {other:?}"),
        }
    }

    #[test]
    fn parse_obfs_missing_mode_errors() {
        let err = parse_plugin("obfs-local", "obfs-host=www.example.com").unwrap_err();
        assert!(matches!(err, PluginError::InvalidOptions(_)));
    }

    #[test]
    fn parse_obfs_unknown_mode_errors() {
        let err = parse_plugin("obfs-local", "obfs=quic").unwrap_err();
        assert!(matches!(err, PluginError::InvalidOptions(_)));
    }

    #[test]
    fn parse_v2ray_plugin_opts() {
        let kind = parse_plugin("v2ray-plugin", "tls;host=example.com;path=/ws").unwrap();
        match kind {
            PluginKind::V2ray(cfg) => {
                assert_eq!(cfg.mode, Mode::Websocket);
                assert!(cfg.tls);
                assert_eq!(cfg.host, "example.com");
                assert_eq!(cfg.path, "/ws");
            }
            other => panic!("expected V2ray, got {other:?}"),
        }
    }

    #[test]
    fn accept_errors_are_classified() {
        use std::io::{Error, ErrorKind};
        // per-connection failures: keep the listener and retry
        assert!(is_transient_accept_error(&Error::from(
            ErrorKind::ConnectionAborted
        )));
        assert!(is_transient_accept_error(&Error::from_raw_os_error(
            libc::EMFILE
        )));
        // the listener itself is gone: retrying would spin forever
        assert!(!is_transient_accept_error(&Error::from_raw_os_error(
            libc::EBADF
        )));
        assert!(!is_transient_accept_error(&Error::from(
            ErrorKind::InvalidInput
        )));
    }

    #[test]
    fn parse_unsupported_plugin_errors() {
        let err = parse_plugin("kcptun", "").unwrap_err();
        match &err {
            PluginError::Unsupported(name) => assert_eq!(name, "kcptun"),
            other => panic!("expected Unsupported, got {other:?}"),
        }
        assert!(err.to_string().contains("HarmonyOS"));
    }
}
