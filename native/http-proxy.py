#!/usr/bin/env python3
"""Minimal HTTP forward proxy for the tun-e2e Docker container.

The colima VM reaches the host as host.lima.internal; the host's port 8081 is
already taken by a local sslocal instance, so this proxy listens on a
different port (default 18081) and gives containers plain-HTTP internet
access (enough for `apt-get`). Not for production use.
"""

import http.server
import socket
import socketserver
import sys
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18081


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self._forward()

    do_HEAD = do_GET
    do_POST = do_GET

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        req = urllib.request.Request(self.path, data=body, method=self.command)
        for name, value in self.headers.items():
            if name.lower() not in ("host", "connection", "proxy-connection",
                                    "content-length"):
                req.add_header(name, value)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                self.send_response(resp.status)
                for name, value in resp.headers.items():
                    if name.lower() not in ("connection",
                                            "transfer-encoding"):
                        self.send_header(name, value)
                self.end_headers()
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except Exception as exc:  # noqa: BLE001 - report any upstream failure
            self.send_error(502, str(exc))

    def do_CONNECT(self):
        host, _, port = self.path.partition(":")
        try:
            upstream = socket.create_connection((host, int(port or 443)),
                                                timeout=30)
        except OSError as exc:
            self.send_error(502, str(exc))
            return
        self.send_response(200, "Connection Established")
        self.end_headers()
        self.connection.setblocking(False)
        upstream.setblocking(False)
        import select
        sockets = [self.connection, upstream]
        try:
            while True:
                readable, _, _ = select.select(sockets, [], [], 60)
                if not readable:
                    break
                for sock in readable:
                    try:
                        data = sock.recv(65536)
                    except OSError:
                        return
                    if not data:
                        return
                    (upstream if sock is self.connection
                     else self.connection).sendall(data)
        finally:
            upstream.close()

    def log_message(self, fmt, *args):
        sys.stderr.write("proxy: %s\n" % (fmt % args))


class ThreadingProxy(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    address_family = socket.AF_INET


if __name__ == "__main__":
    server = ThreadingProxy(("0.0.0.0", PORT), ProxyHandler)
    print(f"forward proxy listening on 0.0.0.0:{PORT}", file=sys.stderr)
    server.serve_forever()
