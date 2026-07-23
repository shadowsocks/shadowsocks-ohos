//! Multi-role helper for the Linux tun packet-routing e2e (see
//! `harmony/native/tun-e2e-linux.sh`). One static musl binary plays every role
//! so the orchestrating script can drop it into different network namespaces.
//!
//! Subcommands:
//!   echo   <bind_addr>            TCP echo server
//!   server <config_json>         shadowsocks server (shadowsocks_service::run_server)
//!   tun    <config_json> <ifname>  open the persistent tun device <ifname> and
//!                                  route it through the tunnel via the C ABI
//!   client <host:port> <message> connect, send, expect the same bytes back
//!
//! Not compiled into the shipped library — it is a test/dev tool only.

use std::env;
use std::ffi::CString;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::fd::RawFd;
use std::process::exit;
use std::thread;
use std::time::Duration;

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: net_helper <echo|server|tun|client> ...");
        exit(2);
    }
    match args[1].as_str() {
        "echo" => run_echo(&args[2]),
        "server" => run_server(&args[2]),
        "tun" => run_tun(&args[2], &args[3]),
        "client" => run_client(&args[2], &args[3]),
        other => {
            eprintln!("unknown subcommand: {other}");
            exit(2);
        }
    }
}

fn run_echo(bind: &str) -> ! {
    let listener = TcpListener::bind(bind).expect("echo bind");
    eprintln!("[echo] listening on {bind}");
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
    exit(0);
}

fn run_server(config_json: &str) -> ! {
    use shadowsocks_service::config::{Config, ConfigType};
    let config = Config::load_from_str(config_json, ConfigType::Server).expect("server config");
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    eprintln!("[server] starting");
    runtime
        .block_on(shadowsocks_service::run_server(config))
        .expect("run_server");
    exit(0);
}

fn run_tun(config_json: &str, ifname: &str) -> ! {
    let fd = open_tun(ifname).expect("open tun");
    eprintln!("[tun] opened {ifname} as fd {fd}");
    let config = CString::new(config_json).unwrap();
    let code = sslocal_core::sslocal_start_tun_fd(config.as_ptr(), fd);
    if code != 0 {
        let err = sslocal_core::sslocal_last_error();
        let msg = if err.is_null() {
            "<none>".to_owned()
        } else {
            unsafe { std::ffi::CStr::from_ptr(err) }
                .to_string_lossy()
                .into_owned()
        };
        eprintln!("[tun] sslocal_start_tun_fd failed: {code} {msg}");
        exit(1);
    }
    eprintln!("[tun] routing started");
    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}

/// Opens the existing persistent tun device `ifname` (created by
/// `ip tuntap add`) and returns a raw fd with IFF_TUN | IFF_NO_PI, matching
/// the raw L3 packet framing the shadowsocks tun stack expects.
fn open_tun(ifname: &str) -> std::io::Result<RawFd> {
    use std::os::fd::IntoRawFd;

    const TUNSETIFF: u64 = 0x400454ca;
    const IFF_TUN: libc::c_short = 0x0001;
    const IFF_NO_PI: libc::c_short = 0x1000;

    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/net/tun")?;
    let fd = file.into_raw_fd();

    let mut ifr: libc::ifreq = unsafe { std::mem::zeroed() };
    let name = ifname.as_bytes();
    for (i, b) in name.iter().enumerate().take(libc::IFNAMSIZ - 1) {
        ifr.ifr_name[i] = *b as libc::c_char;
    }
    ifr.ifr_ifru.ifru_flags = IFF_TUN | IFF_NO_PI;

    let rc = unsafe { libc::ioctl(fd, TUNSETIFF as _, &ifr) };
    if rc < 0 {
        let err = std::io::Error::last_os_error();
        unsafe { libc::close(fd) };
        return Err(err);
    }
    Ok(fd)
}

fn run_client(target: &str, message: &str) -> ! {
    // retry: the tun route + core need a moment to come up
    for attempt in 0..30 {
        match try_client(target, message) {
            Ok(true) => {
                println!("OK");
                exit(0);
            }
            Ok(false) => eprintln!("[client] attempt {attempt}: payload mismatch"),
            Err(e) => eprintln!("[client] attempt {attempt}: {e}"),
        }
        thread::sleep(Duration::from_millis(500));
    }
    eprintln!("[client] FAILED after retries");
    exit(1);
}

fn try_client(target: &str, message: &str) -> std::io::Result<bool> {
    let mut stream = TcpStream::connect(target)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    stream.write_all(message.as_bytes())?;
    let mut buf = vec![0u8; message.len()];
    stream.read_exact(&mut buf)?;
    Ok(buf == message.as_bytes())
}
