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

import { ROUTE_ALL } from './Routes';

const DEFAULT_SOCKS_PORT = 1080;

/**
 * Random UUIDv4-shaped id for profiles and subscriptions. Implemented with
 * Math.random (uniqueness only, not security) because util.generateRandomUUID
 * is unavailable in the host-side unit-test runtime.
 */
export function newProfileId(): string {
  const HEX = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      out += '-';
      continue;
    }
    if (i === 14) {
      out += '4';
      continue;
    }
    if (i === 19) {
      out += HEX.charAt(8 + Math.floor(Math.random() * 4));
      continue;
    }
    out += HEX.charAt(Math.floor(Math.random() * 16));
  }
  return out;
}

/**
 * A shadowsocks server profile, parseable from SIP002 `ss://` URLs and
 * serializable into the JSON config consumed by the native sslocal core.
 */
export class Profile {
  id: string = '';
  name: string = 'Default';
  host: string = '';
  remotePort: number = 8388;
  password: string = '';
  method: string = 'aes-256-gcm';
  /** Policy route, one of the ROUTE_* constants in Routes.ets. */
  route: string = ROUTE_ALL;
  /** Owning subscription id, or '' for manually-added profiles. */
  subscriptionId: string = '';
  localAddress: string = '127.0.0.1';
  localPort: number = DEFAULT_SOCKS_PORT;
  /**
   * SIP003 plugin name ('' = no plugin), e.g. `obfs-local` or `v2ray-plugin`.
   * The native core runs known plugins in-process (see native/sslocal-ffi).
   */
  plugin: string = '';
  /** SIP003 plugin options (`k=v;...`), e.g. `obfs=tls;obfs-host=example.com`. */
  pluginOpts: string = '';

  /** Assigns a fresh random id if this profile does not have one yet. */
  ensureId(): void {
    if (this.id.length === 0) {
      this.id = newProfileId();
    }
  }

  /**
   * Decodes URL-safe or standard base64, with or without padding. Whitespace
   * is skipped; any other invalid character throws. Implemented in pure
   * ArkTS (no Base64Helper) so it also works in the host-side unit-test
   * runtime, where the native util codecs are unavailable.
   */
  static decodeBase64(text: string): string {
    const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const normalized = text.replaceAll('-', '+').replaceAll('_', '/');
    const bytes: number[] = [];
    let buffer = 0;
    let bits = 0;
    for (let i = 0; i < normalized.length; i++) {
      const c = normalized.charAt(i);
      if (c === '=') {
        break;
      }
      if (c === ' ' || c === '\t' || c === '\r' || c === '\n') {
        continue;
      }
      const value = ALPHABET.indexOf(c);
      if (value < 0) {
        throw new Error('invalid base64 input');
      }
      buffer = (buffer << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        bytes.push((buffer >> bits) & 0xff);
      }
    }
    return Profile.decodeUtf8(bytes);
  }

  /**
   * Decodes UTF-8 bytes without util.TextDecoder, which is unavailable in the
   * host-side unit-test runtime. Invalid sequences are skipped.
   */
  static decodeUtf8(bytes: number[]): string {
    let out = '';
    let i = 0;
    while (i < bytes.length) {
      const lead = bytes[i];
      if (lead < 0x80) {
        out += String.fromCharCode(lead);
        i += 1;
        continue;
      }
      let codePoint = 0;
      let extra = 0;
      if ((lead & 0xe0) === 0xc0) {
        codePoint = lead & 0x1f;
        extra = 1;
      } else if ((lead & 0xf0) === 0xe0) {
        codePoint = lead & 0x0f;
        extra = 2;
      } else if ((lead & 0xf8) === 0xf0) {
        codePoint = lead & 0x07;
        extra = 3;
      } else {
        i += 1;
        continue;
      }
      if (i + extra >= bytes.length) {
        break;
      }
      for (let j = 1; j <= extra; j++) {
        codePoint = (codePoint << 6) | (bytes[i + j] & 0x3f);
      }
      if (codePoint <= 0xffff) {
        out += String.fromCharCode(codePoint);
      } else {
        // astral plane: encode as a surrogate pair
        const v = codePoint - 0x10000;
        out += String.fromCharCode(0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff));
      }
      i += extra + 1;
    }
    return out;
  }

  /**
   * Percent-decodes a URL component, returning it unchanged when it contains
   * a malformed escape. decodeURIComponent throws on those, and a single bad
   * entry must not abort the parse of a whole subscription body.
   */
  static percentDecode(text: string): string {
    try {
      return decodeURIComponent(text);
    } catch (e) {
      return text;
    }
  }

  /**
   * Parses an `ss://` URL in either SIP002 form
   * (`ss://base64(method:password)@host:port#name`) or legacy form
   * (`ss://base64(method:password@host:port)#name`). Returns null when the
   * text is not a valid shadowsocks URL.
   */
  static parseUrl(url: string): Profile | null {
    const trimmed = url.trim();
    if (!trimmed.startsWith('ss://')) {
      return null;
    }
    let body = trimmed.substring(5);
    let name = '';
    const hashIndex = body.indexOf('#');
    if (hashIndex >= 0) {
      name = Profile.percentDecode(body.substring(hashIndex + 1));
      body = body.substring(0, hashIndex);
    }
    // SIP002 query part: ?plugin=name%3Bopts (percent-encoded as a whole)
    let plugin = '';
    let pluginOpts = '';
    const queryIndex = body.indexOf('?');
    if (queryIndex >= 0) {
      const query = body.substring(queryIndex + 1);
      body = body.substring(0, queryIndex);
      const params = query.split('&');
      for (const param of params) {
        const eq = param.indexOf('=');
        if (eq > 0 && param.substring(0, eq) === 'plugin') {
          const decoded = Profile.percentDecode(param.substring(eq + 1));
          const semi = decoded.indexOf(';');
          plugin = semi >= 0 ? decoded.substring(0, semi) : decoded;
          pluginOpts = semi >= 0 ? decoded.substring(semi + 1) : '';
        }
      }
    }
    const atIndex = body.lastIndexOf('@');
    let method = '';
    let password = '';
    let hostPort = '';
    try {
      if (atIndex >= 0) {
        // SIP002: userinfo is base64(method:password)
        const userInfo = Profile.decodeBase64(body.substring(0, atIndex));
        hostPort = body.substring(atIndex + 1);
        const colon = userInfo.indexOf(':');
        if (colon < 0) {
          return null;
        }
        method = userInfo.substring(0, colon);
        password = userInfo.substring(colon + 1);
      } else {
        // legacy: whole body is base64(method:password@host:port)
        const decoded = Profile.decodeBase64(body);
        const at = decoded.lastIndexOf('@');
        if (at < 0) {
          return null;
        }
        const userInfo = decoded.substring(0, at);
        hostPort = decoded.substring(at + 1);
        const colon = userInfo.indexOf(':');
        if (colon < 0) {
          return null;
        }
        method = userInfo.substring(0, colon);
        password = userInfo.substring(colon + 1);
      }
    } catch (e) {
      return null;
    }
    const portColon = hostPort.lastIndexOf(':');
    if (portColon < 0) {
      return null;
    }
    const host = hostPort.substring(0, portColon).replace('[', '').replace(']', '');
    const port = Number.parseInt(hostPort.substring(portColon + 1), 10);
    if (host.length === 0 || Number.isNaN(port) || port <= 0 || port > 65535) {
      return null;
    }
    if (method.length === 0 || password.length === 0) {
      return null;
    }
    const profile = new Profile();
    profile.name = name.length > 0 ? name : host;
    profile.host = host;
    profile.remotePort = port;
    profile.method = method;
    profile.password = password;
    profile.plugin = plugin;
    profile.pluginOpts = pluginOpts;
    return profile;
  }

  /** JSON config for the native sslocal core with a local SOCKS5 service. */
  toLocalConfig(): string {
    const config: Record<string, Object> = {
      'locals': [Object({
        'protocol': 'socks',
        'local_address': this.localAddress,
        'local_port': this.localPort,
      })],
      'server': this.host,
      'server_port': this.remotePort,
      'password': this.password,
      'method': this.method,
    };
    if (this.plugin.length > 0) {
      config['plugin'] = this.plugin;
      config['plugin_opts'] = this.pluginOpts;
    }
    return JSON.stringify(config);
  }

  /**
   * JSON config for tun mode. The `tun` local's device fd is injected by the
   * native layer (`sslocal.startTunFd`), so no interface address is set here —
   * the fd from HarmonyOS `VpnConnection.create()` is already configured.
   * `tcp_and_udp` routes both TCP streams and UDP datagrams through the tunnel.
   *
   * When the profile's route is not `all`, `aclPath` must point at the
   * deployed ACL file for that route (see Routes.ets); it is injected as the
   * core's top-level `acl` field.
   */
  toTunConfig(aclPath: string = ''): string {
    const config: Record<string, Object> = {
      'locals': [Object({
        'protocol': 'tun',
      })],
      'server': this.host,
      'server_port': this.remotePort,
      'password': this.password,
      'method': this.method,
      'mode': 'tcp_and_udp',
    };
    if (this.plugin.length > 0) {
      config['plugin'] = this.plugin;
      config['plugin_opts'] = this.pluginOpts;
    }
    if (this.route !== ROUTE_ALL && aclPath.length > 0) {
      config['acl'] = aclPath;
    }
    return JSON.stringify(config);
  }
}
