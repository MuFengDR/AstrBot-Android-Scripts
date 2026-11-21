#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/home" "$temporary/tmp"
script="$temporary/astrbot-startup.sh"
sed 's/\r$//' "$root/installer/astrbot-startup.sh" > "$script"
trace="$temporary/trace"
export INSTALL_TEST_TRACE="$trace"

for command in apt apt-get curl pkill; do
  cat > "$temporary/bin/$command" <<'STUB'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$INSTALL_TEST_TRACE"
exit 99
STUB
  chmod +x "$temporary/bin/$command"
done

assert_blocked() {
  local step="$1" expected="$2" output status
  : > "$trace"
  set +e
  output="$(HOME="$temporary/home" TMPDIR="$temporary/tmp" PATH="$temporary/bin:$PATH" bash "$script" --step "$step" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ]
  [[ "$output" == *"$expected"* ]]
  [ ! -s "$trace" ]
  printf 'PASS: online %s is blocked before package/network commands\n' "$step"
}

assert_blocked napcat 'NapCat团队收到tx律师函已经删库跑路，请使用离线安装'
assert_blocked linuxqq 'NapCat团队收到tx律师函已经删库跑路，请使用离线安装旧版，否则与最后的NapCat版本不兼容'

cat > "$temporary/bin/dpkg-deb" <<'STUB'
#!/bin/sh
[ -s "$2" ] || exit 1
case "$2" in *invalid*) exit 1 ;; esac
case "$1" in
  --info|--contents) exit 0 ;;
  -f)
    case "$3" in
      Architecture) printf 'arm64\n' ;;
      Package) printf 'linuxqq\n' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
STUB
cat > "$temporary/bin/dpkg" <<'STUB'
#!/bin/sh
printf 'dpkg %s\n' "$*" >> "$INSTALL_TEST_TRACE"
exit 0
STUB
cat > "$temporary/bin/dpkg-query" <<'STUB'
#!/bin/sh
printf 'install ok installed\n'
STUB
cat > "$temporary/bin/qq" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$temporary/bin/dpkg-deb" "$temporary/bin/dpkg" "$temporary/bin/dpkg-query" "$temporary/bin/qq"
printf 'fixture deb' > "$temporary/linuxqq.deb"
: > "$trace"
HOME="$temporary/home" TMPDIR="$temporary/tmp" PATH="$temporary/bin:$PATH" \
  ASTRBOT_LINUXQQ_FILE="$temporary/linuxqq.deb" ASTRBOT_LINUXQQ_FORCE_INSTALL=1 \
  bash "$script" --step linuxqq >/dev/null
grep -q '^dpkg -i ' "$trace"
echo 'PASS: explicitly selected legacy LinuxQQ deb remains installable'

printf 'invalid deb' > "$temporary/invalid.deb"
: > "$trace"
set +e
output="$(HOME="$temporary/home" TMPDIR="$temporary/tmp" PATH="$temporary/bin:$PATH" \
  ASTRBOT_LINUXQQ_FILE="$temporary/invalid.deb" ASTRBOT_LINUXQQ_FORCE_INSTALL=1 \
  bash "$script" --step linuxqq 2>&1)"
status=$?
set -e
[ "$status" -ne 0 ]
[[ "$output" == *'The selected LinuxQQ package is invalid or unreadable.'* ]]
! grep -q '^dpkg -i ' "$trace"
echo 'PASS: invalid LinuxQQ deb is rejected before dpkg'

echo 'PASS: online installation guards'
