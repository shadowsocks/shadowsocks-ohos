import { describe, expect, it } from '@ohos/hypium';
import {
  parseSubscriptionBody,
  Subscription,
  SubscriptionStore,
} from '../main/ets/model/Subscription';

export default function subscriptionTest() {
  describe('SubscriptionTest', () => {
    it('parses a base64 list of ss urls', 0, () => {
      // base64 of two newline-separated ss:// URLs (aes-256-gcm:pw@a.example.com
      // and chacha20-ietf-poly1305:p2@b.example.com); precomputed because the
      // host-side test runtime has no native base64 codec
      const body = 'c3M6Ly9ZV1Z6TFRJMU5pMW5ZMjA2Y0hjQGEuZXhhbXBsZS5jb206ODM4OCNOb2RlJTIwQQ' +
        'pzczovL1kyaGhZMmhoTWpBdGFXVjBaaTF3YjJ4NU1UTXdOVHB3TWdAYi5leGFtcGxlLmNvbTo4Mzg5I05vZGUlMjBC';
      const profiles = parseSubscriptionBody(body, 'sub-1');
      expect(profiles.length).assertEqual(2);
      expect(profiles[0].host).assertEqual('a.example.com');
      expect(profiles[0].name).assertEqual('Node A');
      expect(profiles[1].host).assertEqual('b.example.com');
      expect(profiles[1].method).assertEqual('chacha20-ietf-poly1305');
      expect(profiles[0].subscriptionId).assertEqual('sub-1');
      expect(profiles[0].id.length > 0).assertTrue();
    });

    it('parses a SIP008 json document', 0, () => {
      const body = '{"servers":[' +
        '{"server":"a.example.com","server_port":8388,"password":"pw",' +
        '"method":"aes-256-gcm","remarks":"Node A"},' +
        '{"server":"broken.example.com"}' +
        ']}';
      const profiles = parseSubscriptionBody(body, 'sub-2');
      expect(profiles.length).assertEqual(1);
      expect(profiles[0].name).assertEqual('Node A');
      expect(profiles[0].remotePort).assertEqual(8388);
      expect(profiles[0].subscriptionId).assertEqual('sub-2');
    });

    it('rejects garbage bodies', 0, () => {
      expect(parseSubscriptionBody('', 's').length).assertEqual(0);
      expect(parseSubscriptionBody('not a subscription at all !!!', 's').length).assertEqual(0);
      expect(parseSubscriptionBody('{invalid json', 's').length).assertEqual(0);
    });

    it('skips malformed entries instead of aborting the body', 0, () => {
      // the second line has a broken percent escape in its fragment; it must
      // not take the whole subscription down with it
      const body = 'ss://YWVzLTI1Ni1nY206cHc@a.example.com:8388#Node%20A\n' +
        'ss://YWVzLTI1Ni1nY206cHc@b.example.com:8389#Bad%ZZ\n' +
        'ss://not!valid!base64\n' +
        'ss://YWVzLTI1Ni1nY206cHc@c.example.com:8390';
      const profiles = parseSubscriptionBody(body, 'sub-3');
      expect(profiles.length).assertEqual(3);
      expect(profiles[0].host).assertEqual('a.example.com');
      expect(profiles[1].host).assertEqual('b.example.com');
      expect(profiles[2].host).assertEqual('c.example.com');
    });

    it('revives stored subscriptions into usable instances', 0, () => {
      // JSON.parse yields prototype-less objects; without fromJson the class
      // methods are missing and upsert() throws on ensureId()
      const stored = JSON.parse('{"id":"","url":"https://example.com/sub","updatedAt":7}') as
        Subscription;
      const revived = SubscriptionStore.fromJson(stored);
      expect(revived.url).assertEqual('https://example.com/sub');
      expect(revived.updatedAt).assertEqual(7);
      revived.ensureId();
      expect(revived.id.length > 0).assertTrue();
    });
  });
}
