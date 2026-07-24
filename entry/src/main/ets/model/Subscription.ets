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

import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { JsonStore } from './JsonStore';
import { newProfileId, Profile } from './Profile';

const STORE_SUBSCRIPTIONS = 'subscriptions';

/** A remote profile subscription (a URL serving ss:// links). */
export class Subscription {
  id: string = '';
  url: string = '';
  /** Last successful update, milliseconds since epoch; 0 = never. */
  updatedAt: number = 0;

  ensureId(): void {
    if (this.id.length === 0) {
      this.id = newProfileId();
    }
  }
}

/** Persists the subscription list as a JSON file via JsonStore. */
export class SubscriptionStore {
  /**
   * Rebuilds a Subscription from a parsed JSON object. JSON.parse yields
   * plain objects, so the class methods (`ensureId`) are absent until the
   * fields are copied onto a real instance — same reason ProfileStore has a
   * `fromJson`.
   */
  static fromJson(parsed: Subscription): Subscription {
    const subscription = new Subscription();
    subscription.id = parsed.id ?? '';
    subscription.url = parsed.url ?? '';
    subscription.updatedAt = parsed.updatedAt ?? 0;
    return subscription;
  }

  static async getAll(context: common.Context): Promise<Subscription[]> {
    const raw = await JsonStore.read(context, STORE_SUBSCRIPTIONS);
    if (raw.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as Subscription[];
      return parsed.map((s) => SubscriptionStore.fromJson(s));
    } catch (e) {
      return [];
    }
  }

  static async saveAll(context: common.Context, subscriptions: Subscription[]): Promise<void> {
    await JsonStore.write(context, STORE_SUBSCRIPTIONS, JSON.stringify(subscriptions));
  }

  static async upsert(context: common.Context, subscription: Subscription): Promise<void> {
    subscription.ensureId();
    const all = await SubscriptionStore.getAll(context);
    const index = all.findIndex((s) => s.id === subscription.id);
    if (index >= 0) {
      all[index] = subscription;
    } else {
      all.push(subscription);
    }
    await SubscriptionStore.saveAll(context, all);
  }

  static async remove(context: common.Context, id: string): Promise<void> {
    const all = (await SubscriptionStore.getAll(context)).filter((s) => s.id !== id);
    await SubscriptionStore.saveAll(context, all);
  }
}

/** Shape of one server entry in a SIP008 online config document. */
interface Sip008Server {
  server?: string;
  server_port?: number;
  password?: string;
  method?: string;
  remarks?: string;
}

/** Shape of a SIP008 online config document. */
interface Sip008Document {
  servers?: Sip008Server[];
}

/**
 * Parses a subscription response body into profiles. Two formats are
 * supported, matching what shadowsocks providers serve:
 *
 * - a base64 blob of newline-separated `ss://` URLs (the common case);
 * - a SIP008 JSON online config (`{"servers": [...]}`), as used by `ssd://`.
 */
export function parseSubscriptionBody(body: string, subscriptionId: string): Profile[] {
  const trimmed = body.trim();
  if (trimmed.length === 0) {
    return [];
  }
  let text = trimmed;
  if (!trimmed.startsWith('{') && trimmed.indexOf('ss://') < 0) {
    try {
      text = Profile.decodeBase64(trimmed);
    } catch (e) {
      return [];
    }
  }
  if (text.trim().startsWith('{')) {
    return parseSip008(text, subscriptionId);
  }
  const profiles: Profile[] = [];
  for (const line of text.split(/\r?\n/)) {
    const entry = line.trim();
    if (entry.length === 0) {
      continue;
    }
    const profile = Profile.parseUrl(entry);
    if (profile !== null) {
      profile.subscriptionId = subscriptionId;
      profile.ensureId();
      profiles.push(profile);
    }
  }
  return profiles;
}

function parseSip008(text: string, subscriptionId: string): Profile[] {
  let doc: Sip008Document;
  try {
    doc = JSON.parse(text) as Sip008Document;
  } catch (e) {
    return [];
  }
  const profiles: Profile[] = [];
  for (const server of doc.servers ?? []) {
    if (!server.server || !server.server_port || !server.password || !server.method) {
      continue;
    }
    const profile = new Profile();
    profile.name = server.remarks && server.remarks.length > 0 ? server.remarks : server.server;
    profile.host = server.server;
    profile.remotePort = server.server_port;
    profile.password = server.password;
    profile.method = server.method;
    profile.subscriptionId = subscriptionId;
    profile.ensureId();
    profiles.push(profile);
  }
  return profiles;
}

/**
 * Downloads a subscription URL and parses it into profiles owned by
 * `subscriptionId`. Rejects on network errors or non-2xx responses; an
 * unparseable body yields an empty list.
 */
export async function fetchSubscription(url: string, subscriptionId: string): Promise<Profile[]> {
  const request = http.createHttp();
  try {
    const response = await request.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: 15000,
      readTimeout: 15000,
    });
    const code = response.responseCode;
    if (code < 200 || code >= 300) {
      throw new Error(`HTTP ${code}`);
    }
    return parseSubscriptionBody(response.result as string, subscriptionId);
  } finally {
    request.destroy();
  }
}
