import abilityTest from './Ability.test';
import socksE2eTest from './SocksE2e.test';
import vpnE2eTest from './VpnE2e.test';

export default function testsuite() {
  abilityTest();
  socksE2eTest();
  vpnE2eTest();
}
