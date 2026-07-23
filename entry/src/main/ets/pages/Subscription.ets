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
import { ProfileStore } from '../model/ProfileStore';
import { abilityContext } from '../model/AppContext';
import {
  fetchSubscription,
  Subscription,
  SubscriptionStore,
} from '../model/Subscription';

/**
 * Subscription management: a list of subscription URLs with per-item
 * update/delete, mirroring shadowsocks-android's subscription settings.
 * Updating re-downloads the URL and atomically replaces the profiles it owns.
 */
@Entry
@Component
struct SubscriptionPage {
  @State subscriptions: Subscription[] = [];
  @State profileCounts: Map<string, number> = new Map();
  @State updatingId: string = '';

  private addDialog: CustomDialogController = new CustomDialogController({
    builder: AddSubscriptionDialog({
      onConfirm: (url: string) => this.addSubscription(url),
    }),
    autoCancel: true,
  });

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.subscriptions = await SubscriptionStore.getAll(abilityContext());
    const profiles = await ProfileStore.getAll(abilityContext());
    const counts = new Map<string, number>();
    for (const profile of profiles) {
      if (profile.subscriptionId.length > 0) {
        counts.set(profile.subscriptionId, (counts.get(profile.subscriptionId) ?? 0) + 1);
      }
    }
    this.profileCounts = counts;
  }

  private async addSubscription(url: string): Promise<void> {
    const trimmed = url.trim();
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      promptAction.showToast({ message: 'Subscription must be an http(s) URL' });
      return;
    }
    const subscription = new Subscription();
    subscription.url = trimmed;
    subscription.ensureId();
    await SubscriptionStore.upsert(abilityContext(), subscription);
    await this.reload();
    this.update(subscription);
  }

  private async update(subscription: Subscription): Promise<void> {
    if (this.updatingId.length > 0) {
      return;
    }
    this.updatingId = subscription.id;
    try {
      const profiles = await fetchSubscription(subscription.url, subscription.id);
      if (profiles.length === 0) {
        promptAction.showToast({ message: 'No profiles found in subscription' });
      } else {
        await ProfileStore.replaceSubscription(abilityContext(), subscription.id, profiles);
        subscription.updatedAt = Date.now();
        await SubscriptionStore.upsert(abilityContext(), subscription);
        promptAction.showToast({ message: `Updated: ${profiles.length} profiles` });
      }
    } catch (e) {
      promptAction.showToast({ message: `Update failed: ${JSON.stringify(e)}` });
    } finally {
      this.updatingId = '';
      await this.reload();
    }
  }

  private async remove(subscription: Subscription): Promise<void> {
    // drop the subscription and every profile it owns
    await ProfileStore.replaceSubscription(abilityContext(), subscription.id, []);
    await SubscriptionStore.remove(abilityContext(), subscription.id);
    await this.reload();
  }

  build() {
    Column() {
      Row() {
        Text('‹ Back')
          .fontSize(16)
          .fontColor('#3F51B5')
          .onClick(() => router.back())
        Text('Subscriptions')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('＋')
          .fontSize(24)
          .fontColor('#3F51B5')
          .onClick(() => this.addDialog.open())
      }
      .width('100%')
      .padding(16)

      if (this.subscriptions.length === 0) {
        Text('No subscriptions yet')
          .fontSize(14)
          .fontColor('#9E9E9E')
          .margin({ top: 32 })
      }

      List({ space: 8 }) {
        ForEach(this.subscriptions, (subscription: Subscription) => {
          ListItem() {
            Column({ space: 6 }) {
              Text(subscription.url)
                .fontSize(14)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Row() {
                Text(`${this.profileCounts.get(subscription.id) ?? 0} profiles · ` +
                  (subscription.updatedAt > 0 ?
                    `updated ${new Date(subscription.updatedAt).toLocaleDateString()}` :
                    'never updated'))
                  .fontSize(12)
                  .fontColor('#9E9E9E')
                  .layoutWeight(1)
                if (this.updatingId === subscription.id) {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                    .margin({ right: 12 })
                } else {
                  Text('Update')
                    .fontSize(14)
                    .fontColor('#3F51B5')
                    .margin({ right: 16 })
                    .onClick(() => this.update(subscription))
                }
                Text('Delete')
                  .fontSize(14)
                  .fontColor('#F44336')
                  .onClick(() => this.remove(subscription))
              }
              .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(12)
            .borderRadius(8)
            .backgroundColor('#FFFFFF')
          }
        }, (subscription: Subscription) => subscription.id)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}

@CustomDialog
struct AddSubscriptionDialog {
  controller: CustomDialogController;
  onConfirm: (url: string) => void = () => {
  };
  @State url: string = '';

  build() {
    Column({ space: 12 }) {
      Text('Add subscription')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
      TextInput({ placeholder: 'https://…', text: this.url })
        .onChange((value) => this.url = value)
      Row({ space: 12 }) {
        Button('Cancel')
          .backgroundColor('#9E9E9E')
          .layoutWeight(1)
          .onClick(() => this.controller.close())
        Button('Add')
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
