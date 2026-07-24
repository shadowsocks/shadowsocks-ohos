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

import { describe, expect, it, Hypium } from '@ohos/hypium';
import { http, vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo } from '@kit.CoreFileKit';

const TAG = 'VpnE2eTest';

interface CoreStats {
  tx: number;
  rx: number;
}

/** Reads the core's persisted flow counters (<filesDir>/store/traffic_stats.json). */
function readCoreStats(): CoreStats | null {
  try {
    const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
    const path = `${context.filesDir}/store/traffic_stats.json`;
    const raw = fileIo.readTextSync(path);
    return JSON.parse(raw) as CoreStats;
  } catch (e) {
    hilog.error(0x0000, TAG, 'readCoreStats failed: %{public}s', JSON.stringify(e));
    return null;
  }
}

const VPN_ABILITY: Want = {
  deviceId: '',
  bundleName: 'com.xbt.project',
  abilityName: 'SsVpnExtensionAbility',
};

/**
 * Marker page served by the host running the test (`python3 -m http.server
 * 8000`, see docs/hos-emulator-vpn.md). **Point this at the host's own address
 * before running** — it is reachable only from the machine that serves it.
 */
const MARKER_URL = 'http://192.168.0.102:8000/e2e.txt';
/** Text the marker page must contain. */
const MARKER_BODY = 'shadowsocks-ohos e2e OK';

/**
 * On-device end-to-end test for the VPN path. Self-contained: starts
 * SsVpnExtensionAbility (which brings up vpn-tun and the native core in tun
 * mode, using the currently selected profile), fetches a marker page through
 * the tunnel, and stops the VPN. The `aa test` runner tears down a VPN
 * started earlier from the UI, so the VPN must be started from within the
 * test process itself.
 *
 * Expected environment: the selected profile points at an ssserver reachable
 * from the emulator (e.g. 10.0.2.2:18388 on the host), and the settingsdata
 * VPN grant rows exist (see docs/hos-emulator-vpn.md). The host-side ssserver
 * log showing the flow is the definitive tunnel proof.
 */
export default function vpnE2eTest() {
  describe('VpnE2eTest', () => {
    it('routes an HTTP fetch through the shadowsocks tunnel', 0, async () => {
      // starting the VPN + fetching + stats sampling exceeds hypium's 5s default
      Hypium.setTimeConfig(20000);
      await vpnExtension.startVpnExtensionAbility(VPN_ABILITY);
      hilog.info(0x0000, TAG, 'vpn extension started');
      try {
        // give the extension a moment to create the tun and start the core
        await new Promise<void>((resolve) => setTimeout(resolve, 3000));

        const url = MARKER_URL;
        const req = http.createHttp();
        try {
          const resp = await req.request(url, {
            method: http.RequestMethod.GET,
            connectTimeout: 15000,
            readTimeout: 15000,
          });
          const body = resp.result as string;
          hilog.info(0x0000, TAG, 'GET %{public}s -> %{public}d %{public}s',
            url, resp.responseCode, body);
          expect(resp.responseCode).assertEqual(200);
          expect(body.includes(MARKER_BODY)).assertTrue();
        } finally {
          req.destroy();
        }

        // the core reports cumulative tx/rx every 500ms; let a sample persist
        await new Promise<void>((resolve) => setTimeout(resolve, 2000));
        const stats = readCoreStats();
        hilog.info(0x0000, TAG, 'core flow stats after fetch: tx=%{public}d rx=%{public}d',
          stats?.tx ?? -1, stats?.rx ?? -1);
        // the fetch (~30B request, ~30B page through the core) must move the
        // counters; zero means the guest traffic bypassed the tunnel entirely
        expect(stats !== null && (stats.tx > 0 || stats.rx > 0)).assertTrue();
      } finally {
        await vpnExtension.stopVpnExtensionAbility(VPN_ABILITY);
        hilog.info(0x0000, TAG, 'vpn extension stopped');
      }
    });
  });
}
