import abilityTest from './Ability.test';
import vpnE2eTest from './VpnE2e.test';

export default function testsuite() {
  abilityTest();
  vpnE2eTest();
}
