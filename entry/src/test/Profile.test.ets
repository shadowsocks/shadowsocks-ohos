import { describe, expect, it } from '@ohos/hypium';
import { Profile } from '../main/ets/model/Profile';

export default function profileTest() {
  describe('ProfileTest', () => {
    it('parses SIP002 ss urls', 0, () => {
      // base64("aes-256-gcm:test-password") = YWVzLTI1Ni1nY206dGVzdC1wYXNzd29yZA
      const profile = Profile.parseUrl(
        'ss://YWVzLTI1Ni1nY206dGVzdC1wYXNzd29yZA@example.com:8388#My%20Server');
      expect(profile !== null).assertTrue();
      expect(profile!.host).assertEqual('example.com');
      expect(profile!.remotePort).assertEqual(8388);
      expect(profile!.method).assertEqual('aes-256-gcm');
      expect(profile!.password).assertEqual('test-password');
      expect(profile!.name).assertEqual('My Server');
    });

    it('parses legacy ss urls', 0, () => {
      // base64("aes-256-gcm:test-password@example.com:8388")
      const profile = Profile.parseUrl(
        'ss://YWVzLTI1Ni1nY206dGVzdC1wYXNzd29yZEBleGFtcGxlLmNvbTo4Mzg4');
      expect(profile !== null).assertTrue();
      expect(profile!.host).assertEqual('example.com');
      expect(profile!.remotePort).assertEqual(8388);
      expect(profile!.method).assertEqual('aes-256-gcm');
      expect(profile!.password).assertEqual('test-password');
    });

    it('rejects invalid urls', 0, () => {
      expect(Profile.parseUrl('') === null).assertTrue();
      expect(Profile.parseUrl('http://example.com') === null).assertTrue();
      expect(Profile.parseUrl('ss://%%%') === null).assertTrue();
      expect(Profile.parseUrl('ss://YWJj@host:notaport') === null).assertTrue();
    });

    it('serializes sslocal config json', 0, () => {
      const profile = new Profile();
      profile.host = 'example.com';
      profile.remotePort = 8388;
      profile.password = 'pw';
      profile.method = 'aes-256-gcm';
      const config: object = JSON.parse(profile.toLocalConfig()) as object;
      expect(config['server']).assertEqual('example.com');
      expect(config['server_port']).assertEqual(8388);
      expect(config['locals'][0]['protocol']).assertEqual('socks');
      expect(config['locals'][0]['local_port']).assertEqual(1080);
    });

    it('serializes tun config json', 0, () => {
      const profile = new Profile();
      profile.host = 'example.com';
      profile.remotePort = 8388;
      profile.password = 'pw';
      profile.method = 'aes-256-gcm';
      const config: object = JSON.parse(profile.toTunConfig()) as object;
      expect(config['server']).assertEqual('example.com');
      expect(config['locals'][0]['protocol']).assertEqual('tun');
      // both TCP and UDP must route through the tunnel
      expect(config['mode']).assertEqual('tcp_and_udp');
      // route `all` never injects an ACL
      expect(config['acl'] === undefined).assertTrue();
    });

    it('injects acl path for bypass routes', 0, () => {
      const profile = new Profile();
      profile.host = 'example.com';
      profile.remotePort = 8388;
      profile.password = 'pw';
      profile.method = 'aes-256-gcm';
      profile.route = 'bypass-lan-china';
      const config: object =
        JSON.parse(profile.toTunConfig('/data/acl/bypass-lan-china.acl')) as object;
      expect(config['acl']).assertEqual('/data/acl/bypass-lan-china.acl');
      // an acl path without a bypass route is ignored
      profile.route = 'all';
      const plain: object =
        JSON.parse(profile.toTunConfig('/data/acl/bypass-lan-china.acl')) as object;
      expect(plain['acl'] === undefined).assertTrue();
    });
  });
}
