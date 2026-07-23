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

import { common } from '@kit.AbilityKit';
import { JsonStore } from './JsonStore';

const STORE_STATS = 'traffic_stats';

/** Cumulative traffic counters reported by the native core. */
export interface TrafficStats {
  /** Bytes sent through the tunnel (uplink), cumulative since connect. */
  tx: number;
  /** Bytes received through the tunnel (downlink), cumulative since connect. */
  rx: number;
  /** When the sample was taken, milliseconds since epoch. */
  timestamp: number;
}

/**
 * Cross-process bridge for traffic stats. The VPN extension ability hosts the
 * native core (which reports counters to a loopback TCP endpoint, see
 * `sslocal.setStatAddress`) and writes the latest sample here; the UI process
 * polls it. Both abilities belong to the same HAP, so JsonStore resolves to
 * the same file in both processes (writes are atomic — see JsonStore).
 */
export class TrafficStatsStore {
  static async save(context: common.Context, tx: number, rx: number): Promise<void> {
    const stats: TrafficStats = { tx, rx, timestamp: Date.now() };
    await JsonStore.write(context, STORE_STATS, JSON.stringify(stats));
  }

  static async load(context: common.Context): Promise<TrafficStats | null> {
    const raw = await JsonStore.read(context, STORE_STATS);
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as TrafficStats;
    } catch (e) {
      return null;
    }
  }

  static async clear(context: common.Context): Promise<void> {
    await JsonStore.remove(context, STORE_STATS);
  }
}

/** Human-readable byte count, e.g. `1.5 MB`. */
export function formatBytes(n: number): string {
  if (n < 1024) {
    return `${n} B`;
  }
  if (n < 1024 * 1024) {
    return `${(n / 1024).toFixed(1)} KB`;
  }
  if (n < 1024 * 1024 * 1024) {
    return `${(n / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

/** Human-readable rate, e.g. `128.0 KB/s`. */
export function formatRate(bytesPerSecond: number): string {
  return `${formatBytes(bytesPerSecond)}/s`;
}
