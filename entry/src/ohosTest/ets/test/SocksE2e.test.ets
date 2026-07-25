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

import { afterAll, describe, expect, it } from '@ohos/hypium';
import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import sslocal from 'libsslocal.so';

const TAG = 'SocksE2eTest';

/**
 * Host address as seen from the emulator's user-mode (slirp) network — QEMU
 * maps it to the host's loopback, so a server bound to 127.0.0.1 on the host
 * is reachable here (and only here).
 */
const HOST = '10.0.2.2';
/** Host-side `ssserver` (see ci/hos-emulator-e2e.sh). */
const SERVER_PORT = 18388;
const METHOD = 'aes-256-gcm';
const PASSWORD = 'shadowsocks-ohos-e2e';
/** SOCKS5 port the core listens on inside the guest. */
const LOCAL_PORT = 11080;

/**
 * Marker HTTP server, bound to the **host's** loopback. Addressed as
 * `127.0.0.1` on purpose: that literal is resolved on the far side of the
 * tunnel, by `ssserver` on the host. From inside the guest, 127.0.0.1 is the
 * guest's own loopback, where nothing listens — so a successful fetch can
 * only mean the request travelled through the encrypted tunnel. (Addressing
 * the host as 10.0.2.2 would prove nothing: slirp would carry it directly.)
 */
const MARKER_HOST = '127.0.0.1';
const MARKER_PORT = 18800;
const MARKER_BODY = 'shadowsocks-ohos e2e OK';

const REQUEST = `GET /e2e.txt HTTP/1.0\r\nHost: ${MARKER_HOST}:${MARKER_PORT}\r\n\r\n`;

/** JSON config for the core: one SOCKS5 local, pointing at the host ssserver. */
function localConfig(): string {
  const config: Record<string, Object> = {
    'locals': [Object({
      'protocol': 'socks',
      'local_address': '127.0.0.1',
      'local_port': LOCAL_PORT,
    })],
    'server': HOST,
    'server_port': SERVER_PORT,
    'password': PASSWORD,
    'method': METHOD,
  };
  return JSON.stringify(config);
}

/** Sleeps for `ms`. */
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: Function) => setTimeout(resolve, ms));
}

/** ASCII decode; the marker page and HTTP headers are plain ASCII. */
function decode(data: ArrayBuffer): string {
  const bytes = new Uint8Array(data);
  let text = '';
  for (let i = 0; i < bytes.length; i++) {
    text += String.fromCharCode(bytes[i]);
  }
  return text;
}

/**
 * Connects to the marker server, optionally through the core's SOCKS5 local,
 * and returns what the server sent back. Rejects if the connection cannot be
 * established.
 *
 * Closing a socket whose `connect()` is still in flight kills the test process
 * (no JS error, no faultlog), so the socket is only ever closed once connected.
 */
async function fetchMarker(viaSocks: boolean, timeoutMs: number): Promise<string> {
  const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
  const connectOptions: socket.TCPConnectOptions = {
    address: { address: MARKER_HOST, port: MARKER_PORT, family: 1 },
    timeout: timeoutMs,
  };
  if (viaSocks) {
    connectOptions.proxy = {
      type: socket.ProxyTypes.SOCKS5,
      address: { address: '127.0.0.1', port: LOCAL_PORT, family: 1 },
    };
  }
  await tcp.connect(connectOptions);
  try {
    return await new Promise<string>((resolve, reject) => {
      let received = '';
      let settled = false;
      const settle = (err: Error | null): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (err !== null) {
          reject(err);
        } else {
          resolve(received);
        }
      };
      const timer = setTimeout((): void => {
        settle(new Error(`no marker after ${timeoutMs}ms, got ${received.length} bytes`));
      }, timeoutMs);
      tcp.on('message', (value: socket.SocketMessageInfo) => {
        received += decode(value.message);
        if (received.includes(MARKER_BODY)) {
          clearTimeout(timer);
          settle(null);
        }
      });
      tcp.send({ data: REQUEST }).catch((err: Error): void => {
        clearTimeout(timer);
        settle(err);
      });
    });
  } finally {
    await tcp.close();
  }
}

/**
 * On-device end-to-end test of the SOCKS path: starts the native core through
 * the same NAPI entry point the app uses, then pulls a marker page through the
 * encrypted tunnel to a host-side `ssserver`.
 *
 * Unlike `VpnE2e.test.ets` this needs no VPN consent and no tun routing, so it
 * runs on the public HarmonyOS emulator image, where guest traffic never
 * reaches `vpn-tun` (see docs/hos-emulator-vpn.md §2a). It is the on-device
 * test CI runs; the VPN e2e stays a real-device exercise.
 *
 * Host side, provided by `ci/hos-emulator-e2e.sh`:
 *   ssserver -s 127.0.0.1:18388 -k <PASSWORD> -m aes-256-gcm
 *   python3 -m http.server 18800 --bind 127.0.0.1   # serving e2e.txt
 */
export default function socksE2eTest() {
  describe('SocksE2eTest', () => {
    afterAll(() => {
      sslocal.stop();
    });

    it('round-trips an HTTP fetch through the shadowsocks tunnel', 0, async () => {
      const rc = sslocal.start(localConfig());
      if (rc !== 0) {
        hilog.error(0x0000, TAG, 'sslocal.start failed: %{public}s', sslocal.lastError());
      }
      expect(rc).assertEqual(0);
      expect(sslocal.isRunning()).assertTrue();

      // the core binds its SOCKS listener asynchronously
      await sleep(1000);

      const body = await fetchMarker(true, 20000);
      hilog.info(0x0000, TAG, 'tunnelled fetch: %{public}s', body);
      expect(body.includes(MARKER_BODY)).assertTrue();

      expect(sslocal.stop()).assertEqual(0);
      expect(sslocal.isRunning()).assertFalse();
    });

    it('cannot reach the marker without the tunnel', 0, async () => {
      // Control for the test above: the marker listens on the *host's*
      // loopback, so the guest must not be able to reach `127.0.0.1:18800`
      // on its own. Without this, a fetch that slipped out through slirp
      // would look exactly like a working tunnel.
      let reached = false;
      try {
        const body = await fetchMarker(false, 5000);
        hilog.warn(0x0000, TAG, 'direct fetch unexpectedly returned: %{public}s', body);
        reached = body.includes(MARKER_BODY);
      } catch (err) {
        hilog.info(0x0000, TAG, 'direct fetch failed as expected: %{public}s',
          JSON.stringify(err));
      }
      expect(reached).assertFalse();
    });
  });
}
