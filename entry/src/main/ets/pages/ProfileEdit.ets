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

import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Profile } from '../model/Profile';
import { ProfileStore } from '../model/ProfileStore';
import { abilityContext } from '../model/AppContext';
import { ALL_ROUTES, ROUTE_ALL } from '../model/Routes';
import { EditParams } from './Index';

const METHODS: string[] = [
  'aes-128-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305',
];

/**
 * SIP003 plugins the native core runs in-process ('none' = direct
 * connection). The matching option string is edited free-form below.
 */
const PLUGINS: string[] = ['none', 'obfs-local', 'v2ray-plugin'];

const PLUGIN_OPTS_HINTS: string[] = [
  '',
  'obfs=tls;obfs-host=www.example.com',
  'mode=websocket;tls;host=www.example.com;path=/',
];

/** Profile editor, reached from the profile list (add or edit). */
@Entry
@Component
struct ProfileEdit {
  @State profileId: string = '';
  @State name: string = '';
  @State host: string = '';
  @State remotePort: string = '8388';
  @State password: string = '';
  @State methodIndex: number = 1;
  @State methodCustom: string = '';
  @State routeIndex: number = 0;
  @State pluginIndex: number = 0;
  @State pluginOpts: string = '';
  /** PLUGINS plus the profile's current plugin when it is not a preset. */
  @State pluginOptions: string[] = PLUGINS;

  aboutToAppear(): void {
    const params = router.getParams() as EditParams | null;
    const id = params?.id ?? '';
    if (id.length > 0) {
      this.profileId = id;
      ProfileStore.getAll(abilityContext()).then((profiles) => {
        const profile = profiles.find((p) => p.id === id);
        if (profile !== undefined) {
          this.name = profile.name;
          this.host = profile.host;
          this.remotePort = profile.remotePort.toString();
          this.password = profile.password;
          const methodIndex = METHODS.indexOf(profile.method);
          this.methodIndex = methodIndex >= 0 ? methodIndex : -1;
          this.methodCustom = methodIndex >= 0 ? '' : profile.method;
          this.routeIndex = Math.max(0, ALL_ROUTES.indexOf(profile.route));
          if (profile.plugin.length > 0 && PLUGINS.indexOf(profile.plugin) < 0) {
            // keep an imported non-preset plugin visible instead of dropping it
            this.pluginOptions = PLUGINS.concat([profile.plugin]);
          }
          this.pluginIndex = Math.max(0, this.pluginOptions.indexOf(profile.plugin));
          this.pluginOpts = profile.pluginOpts;
        }
      });
    }
  }

  private selectedMethod(): string {
    return this.methodIndex >= 0 ? METHODS[this.methodIndex] : this.methodCustom.trim();
  }

  private async save(): Promise<void> {
    const method = this.selectedMethod();
    if (this.host.trim().length === 0 || this.password.length === 0 || method.length === 0) {
      promptAction.showToast({ message: 'Server, password and method are required' });
      return;
    }
    const profile = new Profile();
    profile.id = this.profileId;
    profile.name = this.name.trim().length > 0 ? this.name.trim() : this.host.trim();
    profile.host = this.host.trim();
    profile.remotePort = Number.parseInt(this.remotePort, 10) || 8388;
    profile.password = this.password;
    profile.method = method;
    profile.route = ALL_ROUTES[this.routeIndex] ?? ROUTE_ALL;
    profile.plugin = this.pluginOptions[this.pluginIndex] === 'none' ?
      '' : this.pluginOptions[this.pluginIndex];
    profile.pluginOpts = this.pluginOpts.trim();
    profile.ensureId();
    try {
      await ProfileStore.upsert(abilityContext(), profile);
      await ProfileStore.setCurrentId(abilityContext(), profile.id);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'ProfileEdit', 'save failed: %{public}s %{public}s',
        err.code?.toString() ?? '', err.message ?? String(e));
      promptAction.showToast({ message: `Save failed: ${err.message ?? String(e)}` });
      return;
    }
    router.back();
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('‹ Back')
          .fontSize(16)
          .fontColor('#3F51B5')
          .onClick(() => router.back())
        Text(this.profileId.length > 0 ? 'Edit profile' : 'Add profile')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text(' ')
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      TextInput({ placeholder: 'Profile name (optional)', text: this.name })
        .onChange((value) => this.name = value)
      TextInput({ placeholder: 'Server host', text: this.host })
        .onChange((value) => this.host = value)
      TextInput({ placeholder: 'Server port', text: this.remotePort })
        .type(InputType.Number)
        .onChange((value) => this.remotePort = value)
      TextInput({ placeholder: 'Password', text: this.password })
        .type(InputType.Password)
        .onChange((value) => this.password = value)

      LabeledSelect({
        label: 'Encryption method',
        options: METHODS.concat(['Custom…']),
        selected: this.methodIndex >= 0 ? this.methodIndex : METHODS.length,
        onSelect: (index: number) => {
          this.methodIndex = index < METHODS.length ? index : -1;
        },
      })
      if (this.methodIndex < 0) {
        TextInput({ placeholder: 'Method (e.g. aes-256-gcm)', text: this.methodCustom })
          .onChange((value) => this.methodCustom = value)
      }

      LabeledSelect({
        label: 'Route',
        options: ALL_ROUTES,
        selected: this.routeIndex,
        onSelect: (index: number) => {
          this.routeIndex = index;
        },
      })

      LabeledSelect({
        label: 'Plugin',
        options: this.pluginOptions,
        selected: this.pluginIndex,
        onSelect: (index: number) => {
          this.pluginIndex = index;
        },
      })
      if (this.pluginIndex > 0) {
        TextInput({
          placeholder: PLUGIN_OPTS_HINTS[this.pluginIndex] || 'Plugin options (k=v;...)',
          text: this.pluginOpts,
        })
          .onChange((value) => this.pluginOpts = value)
      }

      Blank()

      Button('Save')
        .width('100%')
        .height(48)
        .margin({ bottom: 24 })
        .onClick(() => this.save())
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}

@Component
struct LabeledSelect {
  label: string = '';
  options: string[] = [];
  selected: number = 0;
  onSelect: (index: number) => void = () => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(14)
        .fontColor('#9E9E9E')
        .layoutWeight(1)
      Select(this.options.map((option) => {
        return { value: option } as SelectOption;
      }))
        .selected(this.selected)
        .value(this.options[this.selected] ?? '')
        .onSelect((index: number) => this.onSelect(index))
    }
    .width('100%')
  }
}
