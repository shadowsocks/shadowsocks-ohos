//! Host-side end-to-end test of the FFI core: an in-process shadowsocks
//! server, an sslocal instance started through the C ABI, and a full SOCKS5
//! round-trip through the encrypted tunnel to a local echo server.

use std::ffi::CString;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use sslocal_core::{
    sslocal_is_running, sslocal_last_error, sslocal_set_stat_address, sslocal_start, sslocal_stop,
    SSLOCAL_ERR_ALREADY_RUNNING, SSLOCAL_OK,
};

const SS_PORT: u16 = 18388;
const LOCAL_PORT: u16 = 11080;
const ECHO_PORT: u16 = 19990;
const PASSWORD: &str = "harmony-e2e-password";
const METHOD: &str = "aes-256-gcm";

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
        runtime.block_on(shadowsocks_service::run_server(config)).unwrap();
    });
}

/// Listens for the core's flow-stat reports (16 bytes: two native-endian u64
/// cumulative counters tx, rx, one message per connection every 500ms).
fn spawn_stat_listener() -> (u16, mpsc::Receiver<[u64; 2]>) {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = match stream {
                Ok(s) => s,
                Err(_) => continue,
            };
            let mut buf = [0u8; 16];
            if stream.read_exact(&mut buf).is_err() {
                continue;
            }
            let counters = [
                u64::from_ne_bytes(buf[..8].try_into().unwrap()),
                u64::from_ne_bytes(buf[8..].try_into().unwrap()),
            ];
            if tx.send(counters).is_err() {
                return;
            }
        }
    });
    (port, rx)
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
fn socks5_roundtrip_through_tunnel() {
    spawn_echo_server();
    spawn_ss_server();
    wait_for_port(ECHO_PORT);
    wait_for_port(SS_PORT);

    let config_json = format!(
        r#"{{
            "locals": [{{"protocol": "socks", "local_address": "127.0.0.1", "local_port": {LOCAL_PORT}}}],
            "server": "127.0.0.1",
            "server_port": {SS_PORT},
            "password": "{PASSWORD}",
            "method": "{METHOD}"
        }}"#
    );
    let config = CString::new(config_json).unwrap();
    // direct the instance's flow-stat reports at our listener before starting
    let (stat_port, stat_rx) = spawn_stat_listener();
    let stat_addr = CString::new(format!("127.0.0.1:{stat_port}")).unwrap();
    assert_eq!(sslocal_set_stat_address(stat_addr.as_ptr()), SSLOCAL_OK);
    assert_eq!(sslocal_start(config.as_ptr()), SSLOCAL_OK, "{}", last_error_text());
    assert_eq!(sslocal_is_running(), 1);
    // a second start must be rejected while the first instance lives
    assert_eq!(sslocal_start(config.as_ptr()), SSLOCAL_ERR_ALREADY_RUNNING);
    wait_for_port(LOCAL_PORT);

    // SOCKS5: greeting with no-auth
    let mut stream = TcpStream::connect(("127.0.0.1", LOCAL_PORT)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    stream.write_all(&[0x05, 0x01, 0x00]).unwrap();
    let mut reply = [0u8; 2];
    stream.read_exact(&mut reply).unwrap();
    assert_eq!(reply, [0x05, 0x00], "SOCKS5 greeting failed");

    // SOCKS5: CONNECT 127.0.0.1:ECHO_PORT (through the shadowsocks tunnel)
    let mut request = vec![0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1];
    request.extend_from_slice(&ECHO_PORT.to_be_bytes());
    stream.write_all(&request).unwrap();
    let mut response = [0u8; 10];
    stream.read_exact(&mut response).unwrap();
    assert_eq!(response[1], 0x00, "SOCKS5 CONNECT failed: {response:?}");

    // payload must round-trip through sslocal -> ssserver -> echo and back
    let payload = b"hello through the shadowsocks tunnel on HarmonyOS core";
    stream.write_all(payload).unwrap();
    let mut echoed = vec![0u8; payload.len()];
    stream.read_exact(&mut echoed).unwrap();
    assert_eq!(&echoed, payload);

    // the instance reports cumulative tx/rx counters every 500ms; after the
    // round-trip above at least one report must show non-zero traffic
    let mut counters = [0u64; 2];
    for _ in 0..20 {
        counters = stat_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("no flow-stat report received");
        if counters[0] > 0 && counters[1] > 0 {
            break;
        }
    }
    assert!(
        counters[0] > 0 && counters[1] > 0,
        "flow-stat counters stayed at zero: {counters:?}"
    );

    assert_eq!(sslocal_stop(), SSLOCAL_OK);
    assert_eq!(sslocal_is_running(), 0);
    // leave no stat address behind for other tests
    assert_eq!(sslocal_set_stat_address(std::ptr::null()), SSLOCAL_OK);
}
