#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 3 ] || {
  echo "用法: $0 <version> <private.pem> <public.pem>" >&2
  exit 2
}

version="$1"
private_key="$2"
public_key="$3"
root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"
stage="$(mktemp -d)"
artifact="astrbot-installer-v${version}.tar.gz"
offline="astrbot-installer-offline-v${version}.tar.gz"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "版本号必须为 major.minor.patch" >&2
  exit 2
}

trap 'rm -rf "$stage"' EXIT
mkdir -p "$dist" "$stage/astrbot-installer"
# Always normalize the runtime script to Unix LF line endings. The release is
# executed inside Ubuntu; preserving Windows CRLF causes Bash to read `\r` as
# part of every command and fail before the installer starts.
sed 's/\r$//' "$root/installer/astrbot-startup.sh" > "$stage/astrbot-installer/astrbot-startup.sh"
chmod 700 "$stage/astrbot-installer/astrbot-startup.sh"
tar -C "$stage" -czf "$dist/$artifact" astrbot-installer

sha="$(sha256sum "$dist/$artifact" | awk '{print $1}')"
cat > "$dist/manifest.json" <<EOF
{
  "format": "astrbot-android-installer-v1",
  "version": "${version}",
  "release_tag": "v${version}",
  "artifact": "${artifact}",
  "sha256": "${sha}"
}
EOF

openssl pkeyutl -sign -rawin -inkey "$private_key" \
  -in "$dist/manifest.json" -out "$dist/manifest.sig"
"$root/scripts/verify-release.sh" "$dist/manifest.json" "$dist/manifest.sig" \
  "$dist/$artifact" "$public_key"

tar -C "$dist" -czf "$dist/$offline" manifest.json manifest.sig "$artifact"
echo "已生成:"
printf '  %s\n' "$dist/$artifact" "$dist/manifest.json" "$dist/manifest.sig" "$dist/$offline"
