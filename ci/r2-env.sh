#!/usr/bin/env bash
# shellcheck shell=bash
#
# Sourced, not executed. Derives S3 credentials for the CI bucket from the two
# values CI stores: R2_API_TOKEN (a Cloudflare API token) and R2_ENDPOINT.
#
# R2's S3 API accepts a Cloudflare API token as the token's *ID* — which
# /tokens/verify returns, and the account is the first label of the endpoint
# host — plus the SHA-256 of the token value. An explicit AWS keypair wins if
# one is already exported, so a plain S3 credential still works everywhere.
#
# Safe to source more than once.

if [[ -n "${R2_API_TOKEN:-}" && -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
    : "${R2_ENDPOINT:?set R2_ENDPOINT alongside R2_API_TOKEN}"
    _r2_account="$(echo "$R2_ENDPOINT" | sed -E 's|https?://([^.]+)\..*|\1|')"
    AWS_ACCESS_KEY_ID="$(curl -fsS \
        "https://api.cloudflare.com/client/v4/accounts/$_r2_account/tokens/verify" \
        -H "Authorization: Bearer $R2_API_TOKEN" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
    AWS_SECRET_ACCESS_KEY="$(printf '%s' "$R2_API_TOKEN" | shasum -a 256 | cut -d' ' -f1)"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    unset _r2_account
    # The ID is not secret by itself, but it is half a credential.
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::add-mask::$AWS_ACCESS_KEY_ID"
        echo "::add-mask::$AWS_SECRET_ACCESS_KEY"
    fi
fi

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
