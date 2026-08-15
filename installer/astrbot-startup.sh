#!/usr/bin/env bash
# Shared runtime installer for AstrBot Android clients.
# This file is distributed by a signed release and intentionally contains no
# client-specific UI logic. Keep persistent user settings outside this file.

set -o pipefail

INSTALLER_VERSION="0.1.1"
CONFIG_DIR="${HOME:-/root}/.config/astrbot-android"
CONFIG_FILE="$CONFIG_DIR/installer.env"
FLAGS_DIR="$CONFIG_DIR/flags"
REINSTALL_PLUGINS_FLAG="$FLAGS_DIR/reinstall-plugins"

ASTRBOT_GITHUB_PROXY="${ASTRBOT_GITHUB_PROXY:-auto}"
ASTRBOT_FORCE_REINSTALL_STEP="${ASTRBOT_FORCE_REINSTALL_STEP:-}"
ASTRBOT_DASHBOARD_PORT="${ASTRBOT_DASHBOARD_PORT:-6185}"
ASTRBOT_ONEBOT_WS_PORT="${ASTRBOT_ONEBOT_WS_PORT:-6199}"
OPENCODE_VERSION="${ASTRBOT_OPENCODE_VERSION:-1.17.18}"

export UV_LINK_MODE=copy
export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
export UV_PYTHON_INSTALL_MIRROR="https://ghfast.top/https://github.com/astral-sh/python-build-standalone/releases/download"

log() { printf '[AstrBot Installer] %s\n' "$*"; }
warn() { printf '[AstrBot Installer] WARNING: %s\n' "$*" >&2; }
fail() { printf '[AstrBot Installer] ERROR: %s\n' "$*" >&2; return 1; }

init_runtime() {
  TMPDIR="${TMPDIR:-/tmp}"
  export TMPDIR
  mkdir -p "$TMPDIR" "$CONFIG_DIR" "$FLAGS_DIR"
  : "${L_NOT_INSTALLED:=not installed}"
  : "${L_INSTALLING:=installing}"
  : "${L_INSTALLED:=installed}"
  export L_NOT_INSTALLED L_INSTALLING L_INSTALLED
}

progress_echo() {
  printf '\033[31m- %s\033[0m\n' "$*"
  printf '%s' "$*" > "$TMPDIR/progress_des"
}

bump_progress() {
  local current=0
  [ -f "$TMPDIR/progress" ] && current="$(cat "$TMPDIR/progress" 2>/dev/null || echo 0)"
  case "$current" in *[!0-9]*|'') current=0 ;; esac
  printf '%s' "$((current + 1))" > "$TMPDIR/progress"
}

load_user_config() {
  local encoded
  CUSTOM_GIT_CLONE=""
  [ -f "$CONFIG_FILE" ] || return 0
  encoded="$(sed -n 's/^CUSTOM_GIT_CLONE_B64=//p' "$CONFIG_FILE" | head -n 1)"
  [ -n "$encoded" ] || return 0
  CUSTOM_GIT_CLONE="$(printf '%s' "$encoded" | base64 -d 2>/dev/null || true)"
  if [ -z "$CUSTOM_GIT_CLONE" ]; then
    warn "Ignoring an invalid CUSTOM_GIT_CLONE_B64 setting."
  fi
}

recover_package_manager() {
  command -v dpkg >/dev/null 2>&1 || return 0
  export DEBIAN_FRONTEND=noninteractive

  log "Checking interrupted package operations."
  if dpkg --configure -a; then
    return 0
  fi

  warn "dpkg configuration is incomplete; attempting to repair package dependencies."
  if ! apt-get -o Acquire::ForceIPv4=true --fix-broken install -y; then
    fail "Unable to repair the Ubuntu package manager. Run 'dpkg --configure -a' in the terminal and review the package error."
    return 1
  fi
  if ! dpkg --configure -a; then
    fail "Ubuntu packages are still not fully configured. Run 'dpkg --configure -a' in the terminal and review the package error."
    return 1
  fi
}

mark_reinstall_plugins() {
  mkdir -p "$FLAGS_DIR"
  : > "$REINSTALL_PLUGINS_FLAG"
}

needs_plugin_reinstall() {
  [ -f "$REINSTALL_PLUGINS_FLAG" ]
}

network_test() {
  local timeout=10 status proxy
  target_proxy=""

  case "$ASTRBOT_GITHUB_PROXY" in
    direct|'') return 0 ;;
    auto) ;;
    http://*|https://*)
      target_proxy="${ASTRBOT_GITHUB_PROXY%/}"
      log "Using configured GitHub proxy: $target_proxy"
      return 0
      ;;
    *)
      warn "Ignoring invalid GitHub proxy setting: $ASTRBOT_GITHUB_PROXY"
      ;;
  esac

  for proxy in \
    https://ghfast.top \
    https://gh-proxy.com \
    https://ghproxy.net \
    https://ghproxy.cc \
    https://gh.dpik.top \
    https://gh.monlor.com \
    https://gh.chjina.com \
    https://github.boki.moe \
    https://gh.jasonzeng.dev \
    https://gh.geekertao.top \
    https://gh.nxnow.top \
    https://down.npee.cn; do
    status="$(curl -fL --connect-timeout "$timeout" --max-time "$((timeout * 2))" -o /dev/null -s -w '%{http_code}' "$proxy/https://raw.githubusercontent.com/astral-sh/uv/main/README.md" || true)"
    if [ "$status" = "200" ]; then
      target_proxy="$proxy"
      log "Using GitHub proxy: $target_proxy"
      return 0
    fi
  done

  log "No GitHub proxy responded; trying a direct connection."
}

github_url() {
  local url="$1"
  if [ -n "${target_proxy:-}" ]; then
    printf '%s/%s\n' "${target_proxy%/}" "$url"
  else
    printf '%s\n' "$url"
  fi
}

ensure_base_commands() {
  local missing=() command
  recover_package_manager || return 1
  for command in sudo git curl tar ca-certificates; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    progress_echo "Base commands $L_INSTALLED"
    return 0
  fi

  progress_echo "Installing base commands: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::ForceIPv4=true update || warn "apt-get update failed; continuing with package installation."
  apt-get -o Acquire::ForceIPv4=true install -y sudo git curl tar ca-certificates || return 1

  for command in sudo git curl tar; do
    command -v "$command" >/dev/null 2>&1 || return 1
  done
  progress_echo "Base commands $L_INSTALLED"
}

prepare_reinstall_step() {
  case "$1" in
    base)
      progress_echo "Checking base commands"
      ;;
    uv)
      progress_echo "Preparing uv reinstall"
      rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"
      ;;
    napcat)
      progress_echo "Preparing NapCat reinstall"
      if [ -d "$HOME/napcat/config" ]; then
        rm -rf "$HOME/napcat_config_backup"
        cp -a "$HOME/napcat/config" "$HOME/napcat_config_backup"
      fi
      pkill -f 'qq --no-sandbox' 2>/dev/null || true
      pkill -f 'NapCat' 2>/dev/null || true
      pkill -f '/root/launcher_.*\.sh' 2>/dev/null || true
      pkill -f '/root/launcher\.sh' 2>/dev/null || true
      pkill -f 'napcat_instances/.*/launcher' 2>/dev/null || true
      rm -rf "$HOME/napcat" "$HOME/napcat.sh" "$HOME/launcher.sh" "$HOME/launcher.cpp" "$HOME/libnapcat_launcher.so"
      export ASTRBOT_LINUXQQ_FORCE_INSTALL=1
      ;;
    astrbot)
      progress_echo "Preparing AstrBot reinstall"
      killall uv 2>/dev/null || true
      rm -rf "$HOME/AstrBot_data_reinstall_backup"
      if [ -d "$HOME/AstrBot/data" ]; then
        cp -a "$HOME/AstrBot/data" "$HOME/AstrBot_data_reinstall_backup"
      fi
      rm -rf "$HOME/AstrBot" "$HOME/AstrBot_tmp"
      ;;
    opencode)
      progress_echo "Preparing OpenCode reinstall"
      rm -f "$HOME/.local/bin/opencode"
      ;;
  esac
}

maybe_prepare_reinstall() {
  [ "$ASTRBOT_FORCE_REINSTALL_STEP" = "$1" ] && prepare_reinstall_step "$1"
}

install_uv() {
  local install_dir="$HOME/.local/bin"
  local version="0.9.9"
  local archive="uv-aarch64-unknown-linux-gnu.tar.gz"
  local tmp

  if [ -x "$install_dir/uv" ] && [ -x "$install_dir/uvx" ]; then
    progress_echo "uv $L_INSTALLED"
    return 0
  fi

  progress_echo "uv $L_NOT_INSTALLED, $L_INSTALLING"
  network_test
  tmp="$(mktemp -d "$TMPDIR/uv.XXXXXX")" || return 1
  if ! curl -fL "$(github_url "https://github.com/astral-sh/uv/releases/download/${version}/${archive}")" -o "$tmp/$archive"; then
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -xzf "$tmp/$archive" -C "$tmp" --strip-components=1; then
    rm -rf "$tmp"
    return 1
  fi
  if [ ! -f "$tmp/uv" ] || [ ! -f "$tmp/uvx" ]; then
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$install_dir"
  cp "$tmp/uv" "$tmp/uvx" "$install_dir/"
  chmod 755 "$install_dir/uv" "$install_dir/uvx"
  grep -qF 'export PATH=$HOME/.local/bin:$PATH' "$HOME/.bashrc" 2>/dev/null || \
    printf '%s\n' 'export PATH=$HOME/.local/bin:$PATH' >> "$HOME/.bashrc"
  rm -rf "$tmp"
  progress_echo "uv $L_INSTALLED"
}

linuxqq_ready() {
  command -v qq >/dev/null 2>&1 &&
    dpkg-query -W -f='${Status}\n' linuxqq 2>/dev/null | grep -qx 'install ok installed'
}

prepare_apt_downloads() {
  local file changed=0
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p /etc/apt/apt.conf.d
  printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "3";\n' > /etc/apt/apt.conf.d/99astrbot-force-ipv4
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$file" ] || continue
    if grep -q 'http://mirrors\.tuna\.tsinghua\.edu\.cn' "$file"; then
      sed -i 's#http://mirrors\.tuna\.tsinghua\.edu\.cn#https://mirrors.tuna.tsinghua.edu.cn#g' "$file"
      changed=1
    fi
  done
  if [ "$changed" -eq 1 ]; then
    log "Changed the Tsinghua Ubuntu mirror to HTTPS."
  fi
  apt-get -o Acquire::ForceIPv4=true update
}

validate_linuxqq_deb() {
  local file="$1" arch package
  [ -s "$file" ] || return 1
  dpkg-deb --info "$file" >/dev/null 2>&1 || return 1
  dpkg-deb --contents "$file" >/dev/null 2>&1 || return 1
  arch="$(dpkg-deb -f "$file" Architecture 2>/dev/null)"
  package="$(dpkg-deb -f "$file" Package 2>/dev/null)"
  case "$arch" in arm64|aarch64) ;; *) return 1 ;; esac
  [ "$package" = "linuxqq" ]
}

use_local_linuxqq_deb() {
  local destination="$1" candidate
  for candidate in "${ASTRBOT_LINUXQQ_FILE:-}" "$HOME"/*.deb /sdcard/Download/*.deb /storage/emulated/0/Download/*.deb; do
    [ -n "$candidate" ] && [ -f "$candidate" ] || continue
    validate_linuxqq_deb "$candidate" || continue
    log "Using local LinuxQQ package: $candidate"
    cp -f "$candidate" "$destination"
    return $?
  done
  return 1
}

get_linuxqq_signed_url() {
  local bare_url="$1"
  local response="$TMPDIR/linuxqq-sign.json"
  local normalized="$TMPDIR/linuxqq-sign-normalized.json"
  local payload
  LINUXQQ_SIGNED_URL=""
  payload="$(printf '{\"url\":\"%s\"}' "$bare_url")"
  if ! curl -fL --connect-timeout 15 --max-time 30 \
    -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/124 Safari/537.36' \
    -e 'https://im.qq.com/' \
    -H 'Accept: application/json, text/plain, */*' \
    -H 'Content-Type: application/json' \
    -H 'x-oidb: {"uint32_command":"0x9b8e","uint32_service_type":1}' \
    --data "$payload" 'https://im.qq.com/http2rpc/gotrpc/noauth/trpc.qqntv2.urlsign.UrlSign/GetSign' \
    -o "$response"; then
    return 1
  fi
  sed 's#\\/#/#g; s#\\u0026#\&#g; s#\\u003d#=#g' "$response" > "$normalized"
  LINUXQQ_SIGNED_URL="$(grep -Eo '\"url\"[[:space:]]*:[[:space:]]*\"[^\"]+\"' "$normalized" | head -n 1 | sed -E 's/^\"url\"[[:space:]]*:[[:space:]]*\"//; s/\"$//')"
  case "$LINUXQQ_SIGNED_URL" in
    https://*.deb|https://*.deb\?*) return 0 ;;
    *) LINUXQQ_SIGNED_URL=""; return 1 ;;
  esac
}

linuxqq_download_url() {
  local config_url="${ASTRBOT_LINUXQQ_CONFIG_URL:-https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/linuxConfig.js}"
  local config="$TMPDIR/linuxqq-config.js"
  local normalized="$TMPDIR/linuxqq-config-normalized.js"
  local url="${ASTRBOT_LINUXQQ_URL:-}"

  if [ -n "$url" ]; then
    printf '%s\n' "$url"
    return 0
  fi
  curl -fL --connect-timeout 15 --max-time 60 "$config_url" -o "$config" || return 1
  sed 's#\\/#/#g' "$config" > "$normalized"
  url="$(grep -Eo "(https?:)?//[^\"'[:space:]]+" "$normalized" | grep -Ei '(arm64|aarch64)[^[:space:]]*\.deb([?#][^[:space:]]*)?' | head -n 1)"
  case "$url" in
    //*) url="https:$url" ;;
  esac
  case "$url" in
    https://*.deb|https://*.deb\?*) printf '%s\n' "$url" ;;
    *) return 1 ;;
  esac
}

install_linuxqq() {
  local deb="$HOME/QQ.deb"
  local part="${deb}.part"
  local url package_arch package_name sound_package

  if linuxqq_ready && [ "${ASTRBOT_LINUXQQ_FORCE_INSTALL:-0}" != "1" ]; then
    log "LinuxQQ is already installed."
    return 0
  fi

  progress_echo "LinuxQQ $L_NOT_INSTALLED, $L_INSTALLING"
  rm -f "$part"
  if ! url="$(linuxqq_download_url)"; then
    warn "Unable to find a LinuxQQ ARM64 package URL. Set ASTRBOT_LINUXQQ_URL or ASTRBOT_LINUXQQ_FILE to override it."
    return 1
  fi

  if ! validate_linuxqq_deb "$deb" || [ "${ASTRBOT_LINUXQQ_FORCE_INSTALL:-0}" = "1" ]; then
    rm -f "$part"
    log "Downloading LinuxQQ ARM64 package."
    if ! curl -fL --connect-timeout 20 --max-time 600 \
      -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/124 Safari/537.36' \
      -e 'https://im.qq.com/' "$url" -o "$part"; then
      rm -f "$part"
      log "Direct LinuxQQ download failed; trying a signed URL."
      if ! get_linuxqq_signed_url "$url" || ! curl -fL --connect-timeout 20 --max-time 600 \
        -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/124 Safari/537.36' \
        -e 'https://im.qq.com/' "$LINUXQQ_SIGNED_URL" -o "$part"; then
        rm -f "$part"
        use_local_linuxqq_deb "$part" || return 1
      fi
    fi
    validate_linuxqq_deb "$part" || { rm -f "$part"; return 1; }
    mv -f "$part" "$deb"
  fi

  validate_linuxqq_deb "$deb" || return 1
  package_arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null)"
  package_name="$(dpkg-deb -f "$deb" Package 2>/dev/null)"
  case "$package_arch" in arm64|aarch64) ;; *) return 1 ;; esac
  [ "$package_name" = "linuxqq" ] || return 1
  if apt-cache show libasound2t64 >/dev/null 2>&1; then sound_package=libasound2t64; else sound_package=libasound2; fi
  apt-get -o Acquire::ForceIPv4=true install -y libnss3 libnspr4 libgbm1 "$sound_package" || return 1
  apt-get -o Acquire::ForceIPv4=true install -y --allow-downgrades "$deb" || return 1
  linuxqq_ready || return 1
  rm -f "$deb"
  progress_echo "LinuxQQ $L_INSTALLED"
}

patch_napcat_installer() {
  local installer="$1"
  sed -i -E 's/curl[[:space:]]+-k[[:space:]]+-L/curl -fL/g; s/curl[[:space:]]+-kL/curl -fL/g' "$installer"
  if apt-cache show libasound2t64 >/dev/null 2>&1; then
    sed -i -E 's/(^|[^[:alnum:]_])libasound2([^[:alnum:]_]|$)/\1libasound2t64\2/g' "$installer"
  fi
  sed -i -E 's/^[[:space:]]*install_linuxqq[[:space:]]*$/log "LinuxQQ is managed by AstrBot Android"/' "$installer"
  ! grep -qE '^[[:space:]]*install_linuxqq[[:space:]]*$' "$installer"
}

configure_napcat_token_ttl() {
  [ -f "$HOME/napcat/napcat.mjs" ] || return 0
  sed -i -E 's#static MAX_CREDENTIAL_VALID_SECONDS = [0-9]+#static MAX_CREDENTIAL_VALID_SECONDS = 604800#g' "$HOME/napcat/napcat.mjs"
  sed -i -E 's#Rp\.set\(`revoked:\$\{r\}`, !0, [0-9]+\)#Rp.set(`revoked:${r}`, !0, 604800)#g' "$HOME/napcat/napcat.mjs"
}

check_napcat_ready() {
  local missing=0
  command -v qq >/dev/null 2>&1 || missing=1
  command -v Xvfb >/dev/null 2>&1 || missing=1
  dpkg -s linuxqq 2>/dev/null | grep -q 'Status: install ok installed' || missing=1
  dpkg -s libnss3 2>/dev/null | grep -q 'Status: install ok installed' || missing=1
  dpkg -s libnspr4 2>/dev/null | grep -q 'Status: install ok installed' || missing=1
  { dpkg -s libasound2t64 2>/dev/null || dpkg -s libasound2 2>/dev/null; } | grep -q 'Status: install ok installed' || missing=1
  [ -f "$HOME/launcher.sh" ] || missing=1
  [ -f "$HOME/libnapcat_launcher.so" ] || missing=1
  [ -d "$HOME/napcat" ] || missing=1
  [ "$missing" -eq 0 ]
}

install_napcat() {
  local installer="$HOME/napcat.sh"
  if ! check_napcat_ready; then
    progress_echo "NapCat $L_NOT_INSTALLED, $L_INSTALLING"
    prepare_apt_downloads || return 1
    apt --fix-broken install -y || warn "apt could not completely repair dependencies before NapCat installation."
    install_linuxqq || return 1
    [ -d "$HOME/napcat/config" ] && cp -a "$HOME/napcat/config" "$HOME/napcat_config_backup" 2>/dev/null || true
    rm -rf "$HOME/napcat" "$HOME/napcat.sh" "$HOME/launcher.sh" "$HOME/launcher.cpp" "$HOME/libnapcat_launcher.so"
    network_test
    curl -fL "$(github_url 'https://raw.githubusercontent.com/NapNeko/napcat-linux-installer/refs/heads/main/install.sh')" -o "$installer" || return 1
    chmod 700 "$installer"
    patch_napcat_installer "$installer" || return 1
    bash "$installer" || return 1
    pkill -f 'qq --no-sandbox' 2>/dev/null || true
    pkill -f 'NapCat' 2>/dev/null || true
    pkill -f '/root/launcher_.*\.sh' 2>/dev/null || true
    pkill -f '/root/launcher\.sh' 2>/dev/null || true
    pkill -f 'napcat_instances/.*/launcher' 2>/dev/null || true
    if [ -d "$HOME/napcat_config_backup" ]; then
      mkdir -p "$HOME/napcat/config"
      cp -a "$HOME/napcat_config_backup/." "$HOME/napcat/config/"
      rm -rf "$HOME/napcat_config_backup"
    fi
  fi
  if [ ! -f "$HOME/napcat/config/onebot11.json" ]; then
    mkdir -p "$HOME/napcat/config"
    cat > "$HOME/napcat/config/onebot11.json" <<EOF
{
  "network": {
    "httpServers": [],
    "httpClients": [],
    "websocketServers": [],
    "websocketClients": [{
      "name": "WsClient",
      "enable": true,
      "url": "ws://localhost:${ASTRBOT_ONEBOT_WS_PORT}/ws",
      "messagePostFormat": "array",
      "reportSelfMessage": false,
      "reconnectInterval": 5000,
      "token": "kasdkfljsadhlskdjhasdlkfshdlafksjdhf",
      "debug": false,
      "heartInterval": 30000
    }]
  },
  "musicSignUrl": "",
  "enableLocalFile2Url": false,
  "parseMultMsg": false
}
EOF
  fi
  configure_napcat_token_ttl
  check_napcat_ready || return 1
  progress_echo "NapCat $L_INSTALLED"
}

check_astrbot_ready() {
  command -v curl >/dev/null 2>&1 || return 1
  command -v git >/dev/null 2>&1 || return 1
  [ -x "$HOME/.local/bin/uv" ] || return 1
  [ -f "$HOME/AstrBot/pyproject.toml" ] || return 1
  [ -f "$HOME/AstrBot/main.py" ] || return 1
  [ -d "$HOME/AstrBot/.venv" ] || return 1
  cd "$HOME/AstrBot" && "$HOME/.local/bin/uv" run --no-sync python -c 'import aiohttp' >/dev/null 2>&1
}

restore_astrbot_data() {
  local install_dir="$1"
  local backup_dir="/sdcard/Download/AstrBotBubble"
  local latest_backup=""
  if [ -d "$HOME/AstrBot_data_reinstall_backup" ]; then
    rm -rf "$install_dir/data"
    mv "$HOME/AstrBot_data_reinstall_backup" "$install_dir/data"
    mark_reinstall_plugins
    return 0
  fi
  [ -d "$backup_dir" ] && latest_backup="$(ls -t "$backup_dir"/AstrBotBubble-backup-*.tar.gz 2>/dev/null | head -n 1)"
  if [ -n "$latest_backup" ] && tar -xzf "$latest_backup" -C "$install_dir"; then
    mark_reinstall_plugins
    return 0
  fi
  mkdir -p "$install_dir/data"
  if [ -f "$HOME/cmd_config.json" ]; then
    cp "$HOME/cmd_config.json" "$install_dir/data/"
    chmod u+w "$install_dir/data/cmd_config.json"
  fi
}

install_plugin_dependencies() {
  local install_dir="$1" plugin failed=0
  needs_plugin_reinstall || return 0
  log "Reinstalling plugin dependencies."
  if [ -d "$install_dir/data/plugins" ]; then
    for plugin in "$install_dir/data/plugins"/*; do
      [ -d "$plugin" ] && [ -f "$plugin/requirements.txt" ] || continue
      log "Installing plugin dependencies: $(basename "$plugin")"
      if ! (cd "$install_dir" && "$HOME/.local/bin/uv" pip install -r "$plugin/requirements.txt"); then
        warn "Plugin dependency installation failed: $(basename "$plugin")"
        failed=1
      fi
    done
  fi
  [ "$failed" -eq 0 ] && rm -f "$REINSTALL_PLUGINS_FLAG"
  return "$failed"
}

install_astrbot() {
  local install_dir="$HOME/AstrBot"
  local clone_tmp="$HOME/AstrBot_tmp"
  local latest_tag clone_branch
  rm -rf "$clone_tmp"
  killall uv 2>/dev/null || true
  if [ -d "$install_dir" ] && { [ ! -f "$install_dir/pyproject.toml" ] || [ ! -f "$install_dir/main.py" ]; }; then
    rm -rf "$HOME/AstrBot_data_reinstall_backup"
    [ -d "$install_dir/data" ] && cp -a "$install_dir/data" "$HOME/AstrBot_data_reinstall_backup"
    rm -rf "$install_dir"
  fi
  if [ ! -d "$install_dir" ]; then
    progress_echo "AstrBot $L_NOT_INSTALLED, $L_INSTALLING"
    cd "$HOME" || return 1
    if [ -n "$CUSTOM_GIT_CLONE" ]; then
      log "Using the configured custom Git clone command."
      eval "$CUSTOM_GIT_CLONE" || return 1
      [ -d "$HOME/AstrBot" ] || return 1
      mv "$HOME/AstrBot" "$clone_tmp"
    else
      network_test
      latest_tag="$(git ls-remote --tags --sort='-v:refname' "$(github_url 'https://github.com/AstrBotDevs/AstrBot.git')" | awk -F/ '{print $3}' | sed 's/\^{}//g' | grep -E '^v?[0-9]+(\.[0-9]+){1,2}$' | head -n 1)"
      clone_branch="${latest_tag:-master}"
      log "Cloning AstrBot revision: $clone_branch"
      git clone --depth=1 --branch "$clone_branch" "$(github_url 'https://github.com/AstrBotDevs/AstrBot.git')" "$clone_tmp" || return 1
    fi
    mv "$clone_tmp" "$install_dir"
  else
    progress_echo "AstrBot $L_INSTALLED"
  fi
  if [ ! -d "$install_dir/data" ]; then
    restore_astrbot_data "$install_dir" || return 1
    rm -rf "$install_dir/.venv"
  fi
  if [ ! -d "$install_dir/.venv" ] || ! (cd "$install_dir" && "$HOME/.local/bin/uv" run --no-sync python -c 'import aiohttp' >/dev/null 2>&1); then
    progress_echo "Synchronizing AstrBot dependencies"
    (cd "$install_dir" && "$HOME/.local/bin/uv" sync) || return 1
    mark_reinstall_plugins
  fi
  install_plugin_dependencies "$install_dir" || return 1
  progress_echo "AstrBot $L_INSTALLED"
}

install_opencode() {
  local install_dir="$HOME/.local/bin"
  local archive="opencode-linux-arm64.tar.gz"
  local tmp
  if [ -x "$install_dir/opencode" ]; then
    progress_echo "OpenCode $L_INSTALLED"
    return 0
  fi
  progress_echo "OpenCode $L_NOT_INSTALLED, $L_INSTALLING"
  network_test
  tmp="$(mktemp -d "$TMPDIR/opencode.XXXXXX")" || return 1
  if ! curl -fL "$(github_url "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${archive}")" -o "$tmp/$archive"; then
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -xzf "$tmp/$archive" -C "$tmp" || [ ! -f "$tmp/opencode" ]; then
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$install_dir"
  mv "$tmp/opencode" "$install_dir/opencode"
  chmod 755 "$install_dir/opencode"
  rm -rf "$tmp"
  progress_echo "OpenCode $L_INSTALLED"
}

launch_astrbot() {
  if ! check_astrbot_ready; then
    printf '%s\n' '__ASTRBOT_MANUAL_ENV_REQUIRED__'
    fail 'Environment is not ready. Install the missing steps from Environment Manager.'
    return 1
  fi
  cd "$HOME/AstrBot" || return 1
  progress_echo 'Starting AstrBot'
  exec "$HOME/.local/bin/uv" run --no-sync main.py
}

run_step() {
  case "$1" in
    start)
      launch_astrbot
      ;;
    base)
      maybe_prepare_reinstall base
      ensure_base_commands
      ;;
    uv)
      maybe_prepare_reinstall uv
      ensure_base_commands && install_uv
      ;;
    napcat)
      maybe_prepare_reinstall napcat
      ensure_base_commands && install_napcat
      ;;
    astrbot)
      maybe_prepare_reinstall astrbot
      ensure_base_commands && install_uv && install_astrbot
      ;;
    opencode)
      maybe_prepare_reinstall opencode
      ensure_base_commands && install_opencode
      ;;
    all|'')
      ensure_base_commands || return 1
      bump_progress
      install_uv || return 1
      bump_progress
      install_napcat || return 1
      bump_progress
      install_astrbot
      ;;
    *)
      fail "Unknown step: $1. Available steps: base uv napcat astrbot opencode all start"
      return 2
      ;;
  esac
}

usage() {
  cat <<'EOF'
Usage:
  astrbot-startup.sh --step <base|uv|napcat|astrbot|opencode|all|start>
  astrbot-startup.sh --version
EOF
}

main() {
  init_runtime
  load_user_config
  case "${1:-}" in
    --step) run_step "${2:-all}" ;;
    --version) printf '%s\n' "$INSTALLER_VERSION" ;;
    --help|-h|help|'') usage ;;
    *) usage; return 2 ;;
  esac
}

main "$@"
