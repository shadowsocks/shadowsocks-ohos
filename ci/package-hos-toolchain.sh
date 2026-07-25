#!/usr/bin/env bash
#
# Packages the HarmonyOS toolchain CI needs into two archives and uploads them
# to an S3-compatible bucket (Cloudflare R2), because Huawei's DevEco
# command-line tools and emulator images are behind an account + region-gated
# download (docs/hos-emulator-vpn.md §4) and cannot be fetched by a runner —
# nor redistributed publicly, which is why the bucket must be private.
#
# Run this on a Mac that already has both installed:
#
#   HOS_TOOLS=~/workspace/command-line-tools \
#   HOS_IMAGES=~/Library/Huawei/Sdk \
#   R2_BUCKET=shadowsocks R2_ENDPOINT=https://<account>.r2.cloudflarestorage.com \
#   R2_API_TOKEN=<cloudflare api token> \
#   ci/package-hos-toolchain.sh
#
# R2_API_TOKEN/R2_ENDPOINT are the same two values the workflow reads from
# repository secrets; an AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY pair is used
# instead when exported.
#
# Produces (under $OUT, default ./hos-bundle) and uploads to
# s3://$R2_BUCKET/$PREFIX/:
#
#   hos-tools.tar.zst    command-line-tools, minus what a CLI build never uses.
#                        This is what the `build` job of harmonyos.yml streams.
#   hos-images.tar.zst   the emulator system image. CI does not fetch this —
#                        the emulator only runs on a self-hosted Apple-silicon
#                        runner, which has the image locally; it is here to
#                        provision such a machine (or a replacement) without
#                        going through Huawei's region-gated download again.
#   manifest.txt         versions and sha256 of both, for the workflow to pin
#
# Set NO_UPLOAD=1 to only build the archives locally.
#
set -euo pipefail

HOS_TOOLS="${HOS_TOOLS:-$HOME/workspace/command-line-tools}"
HOS_IMAGES="${HOS_IMAGES:-$HOME/Library/Huawei/Sdk}"
IMAGE_SUBPATH="${IMAGE_SUBPATH:-system-image/HarmonyOS-6.1.1/phone_all_arm}"
OUT="${OUT:-$PWD/hos-bundle}"
PREFIX="${PREFIX:-harmonyos-6.1.1}"
ZSTD_LEVEL="${ZSTD_LEVEL:-10}"

[[ -x "$HOS_TOOLS/bin/hvigorw" ]] || { echo "no hvigorw under $HOS_TOOLS"; exit 1; }
[[ -d "$HOS_IMAGES/$IMAGE_SUBPATH" ]] || { echo "no image at $HOS_IMAGES/$IMAGE_SUBPATH"; exit 1; }
command -v zstd >/dev/null || { echo "zstd required"; exit 1; }

mkdir -p "$OUT"

# Dropped: codelinter (~190 MB, only DevEco Studio's linter) and any *.orig
# backup copies of the emulator binary. The previewers look equally droppable
# but are not: hvigor validates the SDK's component list on every build and
# fails with "SDK component missing" if they are absent.
EXCLUDES=(
    --exclude "codelinter"
    --exclude "emulator/*.orig"
    --exclude "*/.DS_Store"
)

echo "=== packing tools from $HOS_TOOLS ==="
tar -C "$(dirname "$HOS_TOOLS")" "${EXCLUDES[@]}" -cf - "$(basename "$HOS_TOOLS")" \
    | zstd "-$ZSTD_LEVEL" -T0 -f -o "$OUT/hos-tools.tar.zst"

echo "=== packing image from $HOS_IMAGES/$IMAGE_SUBPATH ==="
# Keep the system-image/... prefix: the emulator locates images by that layout
# under whatever -imageRoot it is given.
tar -C "$HOS_IMAGES" --exclude "*/.DS_Store" -cf - "$IMAGE_SUBPATH" \
    | zstd "-$ZSTD_LEVEL" -T0 -f -o "$OUT/hos-images.tar.zst"

{
    echo "packaged: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "image: $IMAGE_SUBPATH"
    grep -E "Version:|SDK:|apiVersion" "$HOS_TOOLS/version.txt" 2>/dev/null || true
    echo ""
    shasum -a 256 "$OUT/hos-tools.tar.zst" "$OUT/hos-images.tar.zst" | sed "s|$OUT/||"
} > "$OUT/manifest.txt"

ls -lh "$OUT"
cat "$OUT/manifest.txt"

if [[ -n "${NO_UPLOAD:-}" ]]; then
    echo "NO_UPLOAD set; skipping upload"
    exit 0
fi

: "${R2_BUCKET:?set R2_BUCKET}"
: "${R2_ENDPOINT:?set R2_ENDPOINT}"
command -v aws >/dev/null || { echo "aws CLI required (brew install awscli)"; exit 1; }

# Same credential model as the workflow: R2's S3 API accepts a Cloudflare API
# token as the token's *ID* (from /tokens/verify) plus the SHA-256 of its value,
# so only R2_API_TOKEN has to be stored anywhere. An explicit AWS keypair still
# wins if one is exported.
if [[ -n "${R2_API_TOKEN:-}" && -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
    account="$(echo "$R2_ENDPOINT" | sed -E 's|https?://([^.]+)\..*|\1|')"
    AWS_ACCESS_KEY_ID="$(curl -fsS \
        "https://api.cloudflare.com/client/v4/accounts/$account/tokens/verify" \
        -H "Authorization: Bearer $R2_API_TOKEN" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
    AWS_SECRET_ACCESS_KEY="$(printf '%s' "$R2_API_TOKEN" | shasum -a 256 | cut -d' ' -f1)"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
fi

echo "=== uploading to s3://$R2_BUCKET/$PREFIX/ ==="
for file in hos-tools.tar.zst hos-images.tar.zst manifest.txt; do
    aws s3 cp --endpoint-url "$R2_ENDPOINT" --checksum-algorithm CRC32 \
        "$OUT/$file" "s3://$R2_BUCKET/$PREFIX/$file"
done
echo "done; point the workflow's HOS_BUNDLE_PREFIX at $PREFIX"
