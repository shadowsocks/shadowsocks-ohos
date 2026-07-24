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
import { Profile } from './Profile';
import { ROUTE_ALL } from './Routes';

const STORE_PROFILES = 'profiles';
const STORE_CURRENT_ID = 'current_profile_id';

/**
 * Persists the profile list and the selected (active) profile, mirroring
 * shadowsocks-android's profile database. Storage is a JSON file via
 * JsonStore (see there for why not @ohos.data.preferences).
 */
export class ProfileStore {
  static fromJson(parsed: Profile): Profile {
    const profile = new Profile();
    profile.id = parsed.id ?? '';
    profile.name = parsed.name ?? 'Default';
    profile.host = parsed.host ?? '';
    profile.remotePort = parsed.remotePort ?? 8388;
    profile.password = parsed.password ?? '';
    profile.method = parsed.method ?? 'aes-256-gcm';
    profile.route = parsed.route ?? ROUTE_ALL;
    profile.subscriptionId = parsed.subscriptionId ?? '';
    profile.localAddress = parsed.localAddress ?? '127.0.0.1';
    profile.localPort = parsed.localPort ?? 1080;
    profile.plugin = parsed.plugin ?? '';
    profile.pluginOpts = parsed.pluginOpts ?? '';
    return profile;
  }

  static async getAll(context: common.Context): Promise<Profile[]> {
    const raw = await JsonStore.read(context, STORE_PROFILES);
    if (raw.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as Profile[];
      return parsed.map((p) => ProfileStore.fromJson(p));
    } catch (e) {
      return [];
    }
  }

  static async saveAll(context: common.Context, profiles: Profile[]): Promise<void> {
    await JsonStore.write(context, STORE_PROFILES, JSON.stringify(profiles));
  }

  /** Inserts a new profile or updates the existing one with the same id. */
  static async upsert(context: common.Context, profile: Profile): Promise<void> {
    profile.ensureId();
    const profiles = await ProfileStore.getAll(context);
    const index = profiles.findIndex((p) => p.id === profile.id);
    if (index >= 0) {
      profiles[index] = profile;
    } else {
      profiles.push(profile);
    }
    await ProfileStore.saveAll(context, profiles);
  }

  static async remove(context: common.Context, id: string): Promise<void> {
    const profiles = (await ProfileStore.getAll(context)).filter((p) => p.id !== id);
    await ProfileStore.saveAll(context, profiles);
    const currentId = await ProfileStore.getCurrentId(context);
    if (currentId === id) {
      await ProfileStore.setCurrentId(context, profiles.length > 0 ? profiles[0].id : '');
    }
  }

  /**
   * Atomically replaces every profile owned by `subscriptionId` with the
   * freshly-fetched list (used by subscription updates). Returns the new
   * full profile list.
   */
  static async replaceSubscription(context: common.Context, subscriptionId: string,
    fresh: Profile[]): Promise<Profile[]> {
    const manual = (await ProfileStore.getAll(context)).filter((p) => p.subscriptionId !== subscriptionId);
    const profiles = manual.concat(fresh);
    await ProfileStore.saveAll(context, profiles);
    const current = await ProfileStore.getCurrent(context);
    if (current === null && profiles.length > 0) {
      await ProfileStore.setCurrentId(context, profiles[0].id);
    }
    return profiles;
  }

  static async getCurrentId(context: common.Context): Promise<string> {
    return JsonStore.read(context, STORE_CURRENT_ID);
  }

  static async setCurrentId(context: common.Context, id: string): Promise<void> {
    await JsonStore.write(context, STORE_CURRENT_ID, id);
  }

  /** The selected profile, or null when none is configured. */
  static async getCurrent(context: common.Context): Promise<Profile | null> {
    const profiles = await ProfileStore.getAll(context);
    if (profiles.length === 0) {
      return null;
    }
    const currentId = await ProfileStore.getCurrentId(context);
    return profiles.find((p) => p.id === currentId) ?? profiles[0];
  }
}
