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

import { vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Profile } from '../model/Profile';
import { ProfileStore } from '../model/ProfileStore';
import { abilityContext } from '../model/AppContext';
import { formatBytes, formatRate, TrafficStats, TrafficStatsStore } from '../model/TrafficStats';
import { grantVpnAuthorization } from './VpnGrant';

const TAG = 'Index';

const VPN_ABILITY: Want = {
  deviceId: '',
  bundleName: 'com.xbt.project',
  abilityName: 'SsVpnExtensionAbility',
};

const STATS_POLL_INTERVAL_MS = 1000;

/**
 * Main page: the profile list with the active profile highlighted, a bottom
 * bar with the connect toggle and live traffic stats — mirroring
 * shadowsocks-android's main screen.
 */
@Entry
@Component
struct Index {
  @State profiles: Profile[] = [];
  @State currentId: string = '';
  @State connected: boolean = false;
  @State txTotal: number = 0;
  @State rxTotal: number = 0;
  @State txRate: number = 0;
  @State rxRate: number = 0;
  @State importUrl: string = '';

  private statsTimer: number = -1;
  private lastStats: TrafficStats | null = null;
  private importDialog: CustomDialogController = new CustomDialogController({
    builder: ImportDialog({
      onConfirm: (url: string) => this.importFromUrl(url),
    }),
    autoCancel: true,
  });

  aboutToAppear(): void {
    this.reload();
  }

  aboutToDisappear(): void {
    // the poll timer outlives the page otherwise, and keeps reading the
    // stats file (and touching @State) after the component is gone
    this.stopStatsPolling();
  }

  onPageShow(): void {
    // returning from the edit/subscription page may have changed the list
    this.reload();
  }

  private async reload(): Promise<void> {
    this.profiles = await ProfileStore.getAll(abilityContext());
    this.currentId = await ProfileStore.getCurrentId(abilityContext());
  }

  private currentProfile(): Profile | null {
    return this.profiles.find((p) => p.id === this.currentId) ??
      (this.profiles.length > 0 ? this.profiles[0] : null);
  }

  /** Reports a failed store operation instead of rejecting into a click handler. */
  private reportFailure(what: string, e: Object): void {
    hilog.error(0x0000, TAG, '%{public}s failed: %{public}s', what, JSON.stringify(e));
    promptAction.showToast({ message: `${what} failed` });
  }

  private async selectProfile(profile: Profile): Promise<void> {
    this.currentId = profile.id;
    try {
      await ProfileStore.setCurrentId(abilityContext(), profile.id);
    } catch (e) {
      this.reportFailure('Select profile', e as Object);
    }
  }

  private async removeProfile(profile: Profile): Promise<void> {
    try {
      await ProfileStore.remove(abilityContext(), profile.id);
    } catch (e) {
      this.reportFailure('Delete profile', e as Object);
    }
    await this.reload();
  }

  private importFromUrl(url: string): void {
    const profile = Profile.parseUrl(url);
    if (profile === null) {
      promptAction.showToast({ message: 'Invalid ss:// URL' });
      return;
    }
    profile.ensureId();
    ProfileStore.upsert(abilityContext(), profile).then(async () => {
      await ProfileStore.setCurrentId(abilityContext(), profile.id);
      await this.reload();
      promptAction.showToast({ message: `Imported ${profile.name}` });
    }).catch((e: Object) => this.reportFailure('Import', e));
  }

  private async connect(): Promise<void> {
    const profile = this.currentProfile();
    if (profile === null || profile.host.length === 0 || profile.password.length === 0) {
      promptAction.showToast({ message: 'Please add and select a profile first' });
      return;
    }
    // The public emulator image ships no system consent app
    // (com.huawei.hmos.vpndialog), so startVpnExtensionAbility cannot obtain
    // authorization the usual way there. Grant it up front through the
    // module's own updateVpnAuthorizedState (the same settingsdata write the
    // consent app performs). On retail devices the write is either ignored or
    // rejected and the normal consent dialog still shows; the retry below
    // covers runtimes where the first start already failed before the grant.
    const ret = grantVpnAuthorization(VPN_ABILITY.bundleName ?? '');
    hilog.info(0x0000, TAG, 'updateVpnAuthorizedState ret %{public}d', ret);
    try {
      await vpnExtension.startVpnExtensionAbility(VPN_ABILITY);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'vpn start rejected (%{public}s), retrying after self-grant',
        JSON.stringify(e));
      try {
        grantVpnAuthorization(VPN_ABILITY.bundleName ?? '');
        await vpnExtension.startVpnExtensionAbility(VPN_ABILITY);
      } catch (e2) {
        promptAction.showToast({ message: `Failed to start VPN: ${JSON.stringify(e2)}` });
        return;
      }
    }
    this.connected = true;
    this.startStatsPolling();
  }

  private async disconnect(): Promise<void> {
    try {
      await vpnExtension.stopVpnExtensionAbility(VPN_ABILITY);
    } catch (e) {
      // the extension may already be gone; report but still leave the UI
      // in the disconnected state rather than rejecting into the click handler
      hilog.warn(0x0000, TAG, 'vpn stop failed: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: `Failed to stop VPN: ${JSON.stringify(e)}` });
    } finally {
      this.connected = false;
      this.stopStatsPolling();
    }
  }

  private startStatsPolling(): void {
    this.stopStatsPolling();
    this.lastStats = null;
    this.txTotal = 0;
    this.rxTotal = 0;
    this.txRate = 0;
    this.rxRate = 0;
    this.statsTimer = setInterval(async () => {
      const stats = await TrafficStatsStore.load(abilityContext());
      if (stats === null) {
        return;
      }
      const last = this.lastStats;
      if (last !== null && stats.timestamp > last.timestamp) {
        const deltaSec = (stats.timestamp - last.timestamp) / 1000;
        this.txRate = Math.max(0, Math.round((stats.tx - last.tx) / deltaSec));
        this.rxRate = Math.max(0, Math.round((stats.rx - last.rx) / deltaSec));
      }
      this.lastStats = stats;
      this.txTotal = stats.tx;
      this.rxTotal = stats.rx;
    }, STATS_POLL_INTERVAL_MS);
  }

  private stopStatsPolling(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
  }

  @Builder
  ProfileItem(profile: Profile) {
    Row() {
      Column({ space: 4 }) {
        Text(profile.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${profile.host}:${profile.remotePort}  ${profile.method}`)
          .fontSize(12)
          .fontColor('#9E9E9E')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (profile.id === this.currentId) {
        Text('✓')
          .fontSize(18)
          .fontColor('#4CAF50')
          .margin({ right: 8 })
      }
      Text('Edit')
        .fontSize(14)
        .fontColor('#3F51B5')
        .margin({ right: 16 })
        .onClick(() => {
          router.pushUrl({
            url: 'pages/ProfileEdit',
            params: { id: profile.id } as EditParams,
          });
        })
      Text('✕')
        .fontSize(16)
        .fontColor('#9E9E9E')
        .onClick(() => this.removeProfile(profile))
    }
    .width('100%')
    .padding(12)
    .borderRadius(8)
    .backgroundColor(profile.id === this.currentId ? '#E8EAF6' : '#FFFFFF')
    .onClick(() => this.selectProfile(profile))
  }

  @Builder
  AddMenu() {
    Menu() {
      MenuItem({ content: 'Add manually' })
        .onClick(() => {
          router.pushUrl({ url: 'pages/ProfileEdit' });
        })
      MenuItem({ content: 'Import ss:// URL' })
        .onClick(() => this.importDialog.open())
      MenuItem({ content: 'Subscriptions' })
        .onClick(() => {
          router.pushUrl({ url: 'pages/Subscription' });
        })
    }
  }

  build() {
    Column() {
      // title bar
      Row() {
        Text('Shadowsocks')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Text('＋')
          .fontSize(28)
          .fontColor('#3F51B5')
          .bindMenu(this.AddMenu())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })

      // profile list
      List({ space: 8 }) {
        ForEach(this.profiles, (profile: Profile) => {
          ListItem() {
            this.ProfileItem(profile)
          }
        }, (profile: Profile) => profile.id)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })

      // status + stats bar
      Column({ space: 4 }) {
        if (this.connected) {
          Text(`↑ ${formatRate(this.txRate)} (${formatBytes(this.txTotal)})   ` +
            `↓ ${formatRate(this.rxRate)} (${formatBytes(this.rxTotal)})`)
            .fontSize(13)
            .fontColor('#4CAF50')
        } else {
          Text(this.currentProfile() !== null ?
            `${this.currentProfile()!.name} · ${this.currentProfile()!.route}` :
            'No profile selected')
            .fontSize(13)
            .fontColor('#9E9E9E')
        }
        Button(this.connected ? 'Disconnect' : 'Connect')
          .width('100%')
          .height(48)
          .backgroundColor(this.connected ? '#F44336' : '#3F51B5')
          .onClick(() => {
            if (this.connected) {
              this.disconnect();
            } else {
              this.connect();
            }
          })
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}

/** Router params for the profile edit page. */
export interface EditParams {
  id?: string;
}

@CustomDialog
struct ImportDialog {
  controller: CustomDialogController;
  onConfirm: (url: string) => void = () => {
  };
  @State url: string = '';

  build() {
    Column({ space: 12 }) {
      Text('Import ss:// URL')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
      TextInput({ placeholder: 'ss://…', text: this.url })
        .onChange((value) => this.url = value)
      Row({ space: 12 }) {
        Button('Cancel')
          .backgroundColor('#9E9E9E')
          .layoutWeight(1)
          .onClick(() => this.controller.close())
        Button('Import')
          .layoutWeight(1)
          .onClick(() => {
            this.onConfirm(this.url);
            this.controller.close();
          })
      }
      .width('100%')
    }
    .padding(20)
  }
}
