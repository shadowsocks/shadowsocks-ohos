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
import { fileIo as fs } from '@kit.CoreFileKit';

/**
 * Minimal JSON-file persistence under `<filesDir>/store/`, used instead of
 * @ohos.data.preferences: preferences rejects contexts without a bound
 * ability ("401 context is invalid" on newer runtimes) and is not safe to
 * share across processes, while this app must exchange state between the UI
 * process and the VPN extension process. Both abilities belong to the same
 * HAP, so their filesDir resolves to the same directory.
 *
 * Writes are atomic (tmp file + rename) so the reader process never observes
 * a torn file.
 */
export class JsonStore {
  private static pathFor(context: common.Context, name: string): string {
    return `${context.filesDir}/store/${name}.json`;
  }

  static async read(context: common.Context, name: string): Promise<string> {
    try {
      const path = JsonStore.pathFor(context, name);
      const stat = fs.statSync(path);
      const buffer = new ArrayBuffer(stat.size);
      const fd = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(fd.fd, buffer);
      } finally {
        fs.closeSync(fd);
      }
      return decodeUtf8(Array.from(new Uint8Array(buffer)));
    } catch (e) {
      return '';
    }
  }

  static async write(context: common.Context, name: string, content: string): Promise<void> {
    const dir = `${context.filesDir}/store`;
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
      // directory already exists
    }
    const path = JsonStore.pathFor(context, name);
    const tmp = `${path}.tmp`;
    const fd = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(fd.fd, new Uint8Array(encodeUtf8(content)).buffer);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmp, path);
  }

  static async remove(context: common.Context, name: string): Promise<void> {
    try {
      fs.unlink(JsonStore.pathFor(context, name));
    } catch (e) {
      // not present
    }
  }
}

/** Encodes a string as UTF-8 bytes (no util.TextEncoder dependency). */
function encodeUtf8(text: string): number[] {
  const bytes: number[] = [];
  for (let i = 0; i < text.length; i++) {
    let code = text.charCodeAt(i);
    // combine surrogate pairs
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const low = text.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
        i += 1;
      }
    }
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return bytes;
}

/** Decodes UTF-8 bytes (no util.TextDecoder dependency). */
function decodeUtf8(bytes: number[]): string {
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
      const v = codePoint - 0x10000;
      out += String.fromCharCode(0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff));
    }
    i += extra + 1;
  }
  return out;
}
