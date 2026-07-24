#!/usr/bin/env bash
#
# Ad-hoc (local) signing of a debug HAP using the OpenHarmony sample signing
# materials that ship with the SDK — no Huawei developer account required.
# This is the same local-signing scheme DevEco Studio uses for emulator/device
# debug runs.
#
# Usage:
#   sign-hap-debug.sh <unsigned.hap> [output-signed.hap]
#
# Requires: java, and the OpenHarmony SDK (auto-detected, or set OHOS_SDK_HOME
# to the directory containing openharmony/toolchains).
set -euo pipefail

UNSIGNED="${1:?usage: sign-hap-debug.sh <unsigned.hap> [signed.hap]}"
SIGNED="${2:-${UNSIGNED%-unsigned.hap}-signed.hap}"
BUNDLE_NAME="${BUNDLE_NAME:-com.xbt.project}"

# Locate the OpenHarmony toolchains/lib that holds hap-sign-tool.jar + samples.
if [[ -z "${OHOS_SDK_HOME:-}" ]]; then
    for candidate in \
        "$HOME/Downloads/command-line-tools/sdk/default/openharmony" \
        "$HOME/command-line-tools/sdk/default/openharmony"; do
        [[ -d "$candidate/toolchains/lib" ]] && OHOS_SDK_HOME="$candidate" && break
    done
fi
: "${OHOS_SDK_HOME:?Set OHOS_SDK_HOME to …/sdk/default/openharmony}"

LIB="$OHOS_SDK_HOME/toolchains/lib"
JAR="$LIB/hap-sign-tool.jar"
P12="$LIB/OpenHarmony.p12"
PROFILE_CERT="$LIB/OpenHarmonyProfileRelease.pem"
TEMPLATE="$LIB/UnsgnedDebugProfileTemplate.json"
PWD_="123456"   # well-known password of the public OpenHarmony sample keystore

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Build the app cert chain: the CA-signed release cert is embedded in the
#    debug profile template (the keystore's own copy is self-signed), chained to
#    the CA and root exported from the keystore.
python3 - "$TEMPLATE" "$WORK/leaf.pem" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
open(sys.argv[2], "w").write(d["bundle-info"]["development-certificate"])
PY
keytool -exportcert -rfc -keystore "$P12" -storepass "$PWD_" -storetype PKCS12 \
    -alias "openharmony application ca" -file "$WORK/ca.pem" 2>/dev/null
keytool -exportcert -rfc -keystore "$P12" -storepass "$PWD_" -storetype PKCS12 \
    -alias "openharmony application root ca" -file "$WORK/root.pem" 2>/dev/null
cat "$WORK/leaf.pem" "$WORK/ca.pem" "$WORK/root.pem" > "$WORK/app-cert-chain.pem"

# 2. Sign a debug provisioning profile for this bundle.
sed "s/com.OpenHarmony.app.test/$BUNDLE_NAME/" "$TEMPLATE" > "$WORK/profile.json"
java -jar "$JAR" sign-profile \
    -keyAlias "openharmony application profile release" -signAlg SHA256withECDSA -mode localSign \
    -profileCertFile "$PROFILE_CERT" -inFile "$WORK/profile.json" \
    -keystoreFile "$P12" -outFile "$WORK/profile.p7b" -keyPwd "$PWD_" -keystorePwd "$PWD_"

# 3. Sign the HAP.
java -jar "$JAR" sign-app \
    -keyAlias "openharmony application release" -signAlg SHA256withECDSA -mode localSign \
    -appCertFile "$WORK/app-cert-chain.pem" -profileFile "$WORK/profile.p7b" \
    -inFile "$UNSIGNED" -keystoreFile "$P12" -outFile "$SIGNED" -keyPwd "$PWD_" -keystorePwd "$PWD_"

# 4. Verify.
java -jar "$JAR" verify-app -inFile "$SIGNED" \
    -outCertChain "$WORK/out.cer" -outProfile "$WORK/out.p7b" >/dev/null

echo "Signed and verified: $SIGNED"
