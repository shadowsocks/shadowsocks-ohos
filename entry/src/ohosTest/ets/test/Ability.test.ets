import { describe, expect, it } from '@ohos/hypium';
import sslocal from 'libsslocal.so';

export default function abilityTest() {
  describe('SslocalNativeTest', () => {
    it('exposes the native core', 0, () => {
      expect(sslocal.version().length > 0).assertTrue();
      expect(sslocal.isRunning()).assertFalse();
    });

    it('rejects invalid configs', 0, () => {
      expect(sslocal.start('not json') !== 0).assertTrue();
      const err = sslocal.lastError();
      expect(err !== null && err.length > 0).assertTrue();
    });

    it('rejects a negative tun fd', 0, () => {
      const config = '{"locals":[{"protocol":"tun"}],"server":"127.0.0.1",'
        + '"server_port":8388,"password":"p","method":"aes-256-gcm","mode":"tcp_and_udp"}';
      expect(sslocal.startTunFd(config, -1) !== 0).assertTrue();
    });
  });
}
