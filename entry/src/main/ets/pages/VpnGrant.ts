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

/**
 * Plain-TypeScript helper because ArkTS forbids using a namespace module as
 * an object (arkts-no-ns-as-obj), and `updateVpnAuthorizedState` is not
 * declared in the public d.ts. At runtime the napi module exposes it as a
 * plain property, so a dynamic lookup works.
 *
 * `vpnExtension.updateVpnAuthorizedState(bundleName)` performs the same
 * settingsdata write (`vpnext_mode` → "1") the system consent app performs
 * when the user approves a VPN. The public emulator image ships no consent
 * app (com.huawei.hmos.vpndialog), so VPN apps must grant the authorization
 * themselves there; on retail devices the consent dialog exists and this
 * fallback is never needed (and the write may be permission-gated).
 */

import { vpnExtension } from '@kit.NetworkKit';

interface VpnExtensionDynamic {
  updateVpnAuthorizedState?: (bundleName: string) => number;
}

/** Grants VPN authorization for `bundleName`. Returns the native ret code, or -1 when unavailable. */
export function grantVpnAuthorization(bundleName: string): number {
  const ext = vpnExtension as unknown as VpnExtensionDynamic;
  if (typeof ext.updateVpnAuthorizedState !== 'function') {
    return -1;
  }
  return ext.updateVpnAuthorizedState(bundleName);
}
