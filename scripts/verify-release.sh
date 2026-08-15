#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 4 ] || {
  echo "用法: $0 <manifest.json> <manifest.sig> <payload.tar.gz> <public.pem>" >&2
  exit 2
}

manifest="$1"
signature="$2"
payload="$3"
public_key="$4"

openssl pkeyutl -verify -rawin -pubin -inkey "$public_key" \
  -in "$manifest" -sigfile "$signature"

expected="$(sed -nE 's/.*"sha256"[[:space:]]*:[[:space:]]*"([0-9a-f]{64})".*/\1/p' "$manifest" | head -n 1)"
actual="$(sha256sum "$payload" | awk '{print $1}')"
[ -n "$expected" ] && [ "$actual" = "$expected" ] || {
  echo "SHA-256 校验失败" >&2
  exit 1
}

echo "签名和 SHA-256 校验通过"
