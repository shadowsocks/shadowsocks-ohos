//! Host-side end-to-end test of the built-in SIP003 plugin path: an
//! in-process shadowsocks server behind a fake simple-obfs HTTP server shim,
//! an sslocal instance started through the C ABI with
//! `"plugin": "obfs-local", "plugin_opts": "obfs=http;obfs-host=..."`, and a
//! full SOCKS5 round-trip through the obfuscated tunnel to an echo server.

use std::ffi::CString;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;
use std::time::Duration;

use sslocal_core::{
    sslocal_is_running, sslocal_last_error, sslocal_start, sslocal_stop, SSLOCAL_OK,
};

const SS_PORT: u16 = 18389;
const SHIM_PORT: u16 = 18390;
const LOCAL_PORT: u16 = 11081;
const ECHO_PORT: u16 = 19991;
const PASSWORD: &str = "harmony-e2e-password";
const METHOD: &str = "aes-256-gcm";

/// The fake HTTP response a simple-obfs server prepends to the first bytes
/// sent back to the client.
const FAKE_RESPONSE: &[u8] = b"HTTP/1.1 101 Switching Protocols\r\n\
    Upgrade: websocket\r\n\
    Connection: Upgrade\r\n\
    \r\n";

fn wait_for_port(port: u16) {
    for _ in 0..100 {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }
    panic!("port {port} did not open within 10s");
}

fn spawn_echo_server() {
    let listener = TcpListener::bind(("127.0.0.1", ECHO_PORT)).unwrap();
    thread::spawn(move || {
        for stream in listener.incoming() {
            thread::spawn(move || {
                let mut stream = match stream {
                    Ok(s) => s,
                    Err(_) => return,
                };
                let mut buf = [0u8; 4096];
                loop {
                    match stream.read(&mut buf) {
                        Ok(0) | Err(_) => return,
                        Ok(n) => {
                            if stream.write_all(&buf[..n]).is_err() {
                                return;
                            }
                        }
                    }
                }
            });
        }
    });
}

fn spawn_ss_server() {
    thread::spawn(|| {
        let config_json = format!(
            r#"{{"server": "127.0.0.1", "server_port": {SS_PORT}, "password": "{PASSWORD}", "method": "{METHOD}"}}"#
        );
        let config = shadowsocks_service::config::Config::load_from_str(
            &config_json,
            shadowsocks_service::config::ConfigType::Server,
        )
        .unwrap();
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime
            .block_on(shadowsocks_service::run_server(config))
            .unwrap();
    });
}

fn find_double_crlf(data: &[u8]) -> Option<usize> {
    data.windows(4).position(|w| w == b"\r\n\r\n")
}

/// A fake simple-obfs HTTP *server*: per connection it consumes the client's
/// fake GET request headers, forwards the remaining buffered body plus
/// everything after to the real ssserver, and prepends a fake `101 Switching
/// Protocols` response header to the first bytes sent back to the client.
fn spawn_obfs_http_shim() {
    let listener = TcpListener::bind(("127.0.0.1", SHIM_PORT)).unwrap();
    thread::spawn(move || {
        for stream in listener.incoming() {
            thread::spawn(move || {
                let mut client = match stream {
                    Ok(s) => s,
                    Err(_) => return,
                };
                // Read until the \r\n\r\n header terminator, keeping any
                // request body bytes that arrived in the same reads.
                let mut buf = Vec::new();
                let mut tmp = [0u8; 4096];
                let body_start = loop {
                    match client.read(&mut tmp) {
                        Ok(0) | Err(_) => return,
                        Ok(n) => {
                            buf.extend_from_slice(&tmp[..n]);
                            if let Some(idx) = find_double_crlf(&buf) {
                                break idx + 4;
                            }
                            if buf.len() > 64 * 1024 {
                                return;
                            }
                        }
                    }
                };
                let mut server = match TcpStream::connect(("127.0.0.1", SS_PORT)) {
                    Ok(s) => s,
                    Err(_) => return,
                };
                if server.write_all(&buf[body_start..]).is_err() {
                    return;
                }
                // client -> server: pure passthrough from here on.
                let mut client_in = match client.try_clone() {
                    Ok(s) => s,
                    Err(_) => return,
                };
                let mut server_in = match server.try_clone() {
                    Ok(s) => s,
                    Err(_) => return,
                };
                let upstream = thread::spawn(move || {
                    let _ = std::io::copy(&mut client_in, &mut server_in);
                });
                // server -> client: fake response header, then passthrough.
                if client.write_all(FAKE_RESPONSE).is_err() {
                    return;
                }
                let _ = std::io::copy(&mut server, &mut client);
                let _ = upstream.join();
            });
        }
    });
}

fn last_error_text() -> String {
    let ptr = sslocal_last_error();
    if ptr.is_null() {
        return "<no error>".to_owned();
    }
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

#[test]
fn socks5_roundtrip_through_http_obfs_plugin() {
    let _ = env_logger::builder().is_test(true).try_init();
    spawn_echo_server();
    spawn_ss_server();
    spawn_obfs_http_shim();
    wait_for_port(ECHO_PORT);
    wait_for_port(SS_PORT);
    wait_for_port(SHIM_PORT);

    let config_json = format!(
        r#"{{
            "locals": [{{"protocol": "socks", "local_address": "127.0.0.1", "local_port": {LOCAL_PORT}}}],
            "server": "127.0.0.1",
            "server_port": {SHIM_PORT},
            "password": "{PASSWORD}",
            "method": "{METHOD}",
            "plugin": "obfs-local",
            "plugin_opts": "obfs=http;obfs-host=www.example.com"
        }}"#
    );
    let config = CString::new(config_json).unwrap();
    assert_eq!(
        sslocal_start(config.as_ptr()),
        SSLOCAL_OK,
        "{}",
        last_error_text()
    );
    assert_eq!(sslocal_is_running(), 1);
    wait_for_port(LOCAL_PORT);

    // SOCKS5: greeting with no-auth
    let mut stream = TcpStream::connect(("127.0.0.1", LOCAL_PORT)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    stream.write_all(&[0x05, 0x01, 0x00]).unwrap();
    let mut reply = [0u8; 2];
    stream.read_exact(&mut reply).unwrap();
    assert_eq!(reply, [0x05, 0x00], "SOCKS5 greeting failed");

    // SOCKS5: CONNECT 127.0.0.1:ECHO_PORT (through the obfuscated tunnel)
    let mut request = vec![0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1];
    request.extend_from_slice(&ECHO_PORT.to_be_bytes());
    stream.write_all(&request).unwrap();
    let mut response = [0u8; 10];
    stream.read_exact(&mut response).unwrap();
    assert_eq!(response[1], 0x00, "SOCKS5 CONNECT failed: {response:?}");

    // payload must round-trip through
    // sslocal -> plugin forwarder -> obfs shim -> ssserver -> echo and back
    let payload = b"hello through the obfuscated shadowsocks tunnel on HarmonyOS core";
    stream.write_all(payload).unwrap();
    let mut echoed = vec![0u8; payload.len()];
    stream.read_exact(&mut echoed).unwrap();
    assert_eq!(&echoed, payload);

    assert_eq!(sslocal_stop(), SSLOCAL_OK);
    assert_eq!(sslocal_is_running(), 0);
}
