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

import { VpnExtensionAbility, vpnExtension, socket } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import sslocal from 'libsslocal.so';
import { ProfileStore } from '../model/ProfileStore';
import { aclFileForRoute, ROUTE_ALL } from '../model/Routes';
import { TrafficStatsStore } from '../model/TrafficStats';

const TAG = 'SsVpnExtension';

const TUN_ADDRESS = '172.19.0.1';

/** Loopback ports probed (in order) for the traffic-stat report endpoint. */
const STAT_PORTS: number[] = [65080, 65081, 65082, 65083, 65084];
/** Stat samples reach us every ~500 ms; persist at most one per second. */
const STAT_SAVE_INTERVAL_MS = 1000;

/**
 * VPN extension ability that establishes the system VPN interface and routes
 * every packet through the embedded sslocal core in tun mode.
 *
 * The system hands us an already-configured tun file descriptor from
 * `VpnConnection.create()`; we pass it straight to the native core
 * (`sslocal.startTunFd`, built with the `local-tun` feature). The core's tun
 * stack (smoltcp) terminates TCP/UDP from the tun and re-establishes each flow
 * through the shadowsocks tunnel — the same role tun2socks plays in the
 * Android client.
 *
 * Policy routes: when the active profile's route is not `all`, the matching
 * ACL file (shipped as a rawfile resource, mirroring shadowsocks-android's
 * assets/acl) is deployed to the app files dir and injected into the core
 * config; the core then connects matching destinations directly instead of
 * through the tunnel.
 *
 * Traffic stats: the core (built with `local-flow-stat`) connects to a
 * loopback TCP endpoint every 500 ms and writes 16 bytes — two little-endian
 * u64 cumulative counters (tx, rx), the same wire format shadowsocks-android's
 * TrafficMonitor consumes. We host that endpoint and persist the latest
 * sample via TrafficStatsStore for the UI process to poll.
 *
 * The default route below sends all traffic into the tun, so the core's own
 * connections to the shadowsocks server must stay outside the tunnel or the
 * tunnel loops on itself. `VpnConnection.protectProcessNet()` (API 22+) marks
 * every socket this process creates afterwards as protected; since the native
 * core runs in this same process, its server connections bypass the VPN. On
 * older runtimes the API is absent — we log a warning and the tunnel will
 * loop unless the server is reachable through a more specific route.
 */
export default class SsVpnExtensionAbility extends VpnExtensionAbility {
  private connection: vpnExtension.VpnConnection | null = null;
  private statServer: socket.TCPSocketServer | null = null;
  private statConnections: socket.TCPSocketConnection[] = [];
  private lastStatSave: number = 0;

  async onCreate(want: Want): Promise<void> {
    hilog.info(0x0000, TAG, 'onCreate, core version %{public}s', sslocal.version());
    const profile = await ProfileStore.getCurrent(this.context);
    if (profile === null || profile.host.length === 0) {
      hilog.error(0x0000, TAG, 'no profile configured, aborting');
      return;
    }
    hilog.info(0x0000, TAG, 'starting profile %{public}s (route %{public}s)',
      profile.name, profile.route);

    this.connection = vpnExtension.createVpnConnection(this.context);
    const config: vpnExtension.VpnConfig = {
      addresses: [{
        address: { address: TUN_ADDRESS, family: 1 },
        prefixLength: 30,
      }],
      // default route: capture all IPv4 traffic into the tun
      routes: [{
        interface: 'vpn-tun',
        destination: {
          address: { address: '0.0.0.0', family: 1 },
          prefixLength: 0,
        },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: true,
      }],
      dnsAddresses: ['1.1.1.1'],
      trustedApplications: [],
      blockedApplications: [],
      mtu: 1500,
      isIPv4Accepted: true,
    };
    try {
      const tunFd = await this.connection.create(config);
      hilog.info(0x0000, TAG, 'vpn interface created, tun fd %{public}d', tunFd);

      // Keep the core's own server connections out of the tunnel (see class
      // doc): protect every socket this process creates from now on. Only
      // available since API 22, so probe for it at runtime.
      if (typeof this.connection.protectProcessNet === 'function') {
        await this.connection.protectProcessNet();
        hilog.info(0x0000, TAG, 'process sockets protected from VPN routing');
      } else {
        hilog.warn(0x0000, TAG, 'protectProcessNet unavailable (API < 22); ' +
          'server connection may loop through the tunnel');
      }

      const aclPath = await this.deployAcl(profile.route);

      // Host the flow-stat report endpoint; stats are best-effort, so a
      // failure here must not block the VPN from starting.
      await TrafficStatsStore.clear(this.context);
      try {
        const statPort = await this.startStatServer();
        const code = sslocal.setStatAddress(`127.0.0.1:${statPort}`);
        if (code !== 0) {
          hilog.warn(0x0000, TAG, 'setStatAddress failed: %{public}d', code);
        }
      } catch (e) {
        hilog.warn(0x0000, TAG, 'traffic stats unavailable: %{public}s', JSON.stringify(e));
      }

      // Route the tun device through the shadowsocks tunnel.
      const code = sslocal.startTunFd(profile.toTunConfig(aclPath), tunFd);
      if (code !== 0) {
        hilog.error(0x0000, TAG, 'sslocal.startTunFd failed: %{public}d %{public}s',
          code, sslocal.lastError() ?? '');
        await this.teardown();
      } else {
        hilog.info(0x0000, TAG, 'shadowsocks tun routing started');
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'failed to establish VPN: %{public}s', JSON.stringify(e));
      await this.teardown();
    }
  }

  async onDestroy(): Promise<void> {
    hilog.info(0x0000, TAG, 'onDestroy');
    await this.teardown();
  }

  private async teardown(): Promise<void> {
    if (sslocal.isRunning()) {
      sslocal.stop();
    }
    for (const conn of this.statConnections) {
      try {
        await conn.close();
      } catch (e) {
        // already closed
      }
    }
    this.statConnections = [];
    if (this.statServer !== null) {
      try {
        await this.statServer.close();
      } catch (e) {
        // already closed
      }
      this.statServer = null;
    }
    if (this.connection !== null) {
      await this.connection.destroy();
      this.connection = null;
    }
    await TrafficStatsStore.clear(this.context);
  }

  /**
   * Deploys the ACL file for `route` from rawfile resources into the app
   * files dir and returns its path, or '' when the route needs no ACL.
   */
  private async deployAcl(route: string): Promise<string> {
    if (route === ROUTE_ALL) {
      return '';
    }
    const file = aclFileForRoute(route);
    if (file.length === 0) {
      hilog.warn(0x0000, TAG, 'unknown route %{public}s, no ACL applied', route);
      return '';
    }
    try {
      const dir = `${this.context.filesDir}/acl`;
      try {
        fs.mkdirSync(dir);
      } catch (e) {
        // directory already exists
      }
      const dest = `${dir}/${file}`;
      const content = await this.context.resourceManager.getRawFileContent(`acl/${file}`);
      const fd = fs.openSync(dest,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(fd.fd,
          content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength));
      } finally {
        fs.closeSync(fd);
      }
      hilog.info(0x0000, TAG, 'ACL deployed: %{public}s', dest);
      return dest;
    } catch (e) {
      hilog.error(0x0000, TAG, 'failed to deploy ACL for %{public}s: %{public}s',
        route, JSON.stringify(e));
      return '';
    }
  }

  /**
   * Binds the traffic-stat TCP endpoint to the first free loopback port from
   * STAT_PORTS and returns the bound port. Each accepted connection delivers
   * 16-byte little-endian (tx, rx) u64 cumulative counters.
   */
  private async startStatServer(): Promise<number> {
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      this.onStatConnection(conn);
    });
    for (const port of STAT_PORTS) {
      try {
        await server.listen({ address: '127.0.0.1', port: port, family: 1 });
        this.statServer = server;
        hilog.info(0x0000, TAG, 'stat endpoint listening on 127.0.0.1:%{public}d', port);
        return port;
      } catch (e) {
        hilog.warn(0x0000, TAG, 'stat port %{public}d unavailable, trying next', port);
      }
    }
    throw new Error('no stat port available');
  }

  private onStatConnection(conn: socket.TCPSocketConnection): void {
    this.statConnections.push(conn);
    conn.on('message', (info: socket.SocketMessageInfo) => {
      const buf = info.message;
      if (buf.byteLength < 16) {
        return;
      }
      const view = new DataView(buf);
      // native-endian u64 on arm64 = little-endian; low word first
      const tx = view.getUint32(0, true) + view.getUint32(4, true) * 4294967296;
      const rx = view.getUint32(8, true) + view.getUint32(12, true) * 4294967296;
      const now = Date.now();
      if (now - this.lastStatSave >= STAT_SAVE_INTERVAL_MS) {
        this.lastStatSave = now;
        TrafficStatsStore.save(this.context, tx, rx).catch(() => {
        });
      }
    });
  }
}
