#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_ADMIN_USER="${SUDO_USER:-netadmin}"
ADMIN_USER="${EDGE_ADMIN_USER:-$DEFAULT_ADMIN_USER}"
NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"
NETBIRD_HOSTNAME="${NETBIRD_HOSTNAME:-$(hostname -s)}"
PREPARE_NETBIRD_ROUTING_PEER="yes"
INSTALL_DESKTOP="${INSTALL_DESKTOP:-yes}"
INSTALL_BLOOMINGEDGE_WALLPAPER="${INSTALL_BLOOMINGEDGE_WALLPAPER:-yes}"
INSTALL_PORTAINER="${INSTALL_PORTAINER:-yes}"
CONFIGURE_UFW="${CONFIGURE_UFW:-yes}"
ENABLE_FULL_UPGRADE="${ENABLE_FULL_UPGRADE:-yes}"
REPAIR_MODE="${REPAIR_MODE:-no}"
FORCE_NETBIRD_REENROLL="${FORCE_NETBIRD_REENROLL:-no}"
FORCE_PORTAINER_REDEPLOY="${FORCE_PORTAINER_REDEPLOY:-no}"
PORTAINER_CONTAINER_NAME="${PORTAINER_CONTAINER_NAME:-portainer}"
LOG_BASENAME="${BOOTSTRAP_LOG_BASENAME:-edge-node-bootstrap}"
WALLPAPER_SOURCE_PATH="${EDGE_WALLPAPER_SOURCE:-$REPO_ROOT/img/BloomingEdge_Network.png}"
WALLPAPER_TARGET_PATH="${EDGE_WALLPAPER_TARGET:-/usr/share/backgrounds/BloomingEdge_Network.png}"

BASE_PACKAGES=(
  curl
  wget
  git
  htop
  iftop
  btop
  nano
  vim
  net-tools
  chrony
  lm-sensors
  jq
  unzip
  zip
  snmpd
  ufw
)

DESKTOP_PACKAGES=(
  xfce4
  xfce4-goodies
  lightdm
  lightdm-gtk-greeter
  gnome-keyring
  libpam-gnome-keyring
  seahorse
  xorg
  xserver-xorg-input-all
  dbus-x11
  xubuntu-default-settings
  xrdp
  xorgxrdp
  network-manager
  network-manager-gnome
)

NETPLAN_RENDERER_FILE="/etc/netplan/99-bcl-network-manager-renderer.yaml"

APT_UPDATE_RECOVERY_ACTION="none"
APT_UPDATE_FINAL_STATUS="unknown"
GOOGLE_CHROME_REPO_DISABLED="no"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

repair_google_chrome_repo_key() {
  local keyring_dir="/etc/apt/keyrings"
  local keyring_file="$keyring_dir/google-chrome.gpg"
  local key_url="https://dl.google.com/linux/linux_signing_key.pub"

  if ! command -v gpg >/dev/null 2>&1; then
    log "Cannot repair Google Chrome apt key: gpg is not installed"
    return 1
  fi

  install -m 0755 -d "$keyring_dir"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$key_url" | gpg --dearmor -o "$keyring_file"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$key_url" | gpg --dearmor -o "$keyring_file"
  else
    log "Cannot repair Google Chrome apt key: neither curl nor wget is available"
    return 1
  fi

  chmod a+r "$keyring_file"
  return 0
}

disable_google_chrome_repo() {
  local chrome_repo_file="/etc/apt/sources.list.d/google-chrome.list"
  local disabled_repo_file="/etc/apt/sources.list.d/google-chrome.list.disabled"

  if [[ -f "$chrome_repo_file" ]]; then
    mv "$chrome_repo_file" "$disabled_repo_file"
    GOOGLE_CHROME_REPO_DISABLED="yes"
    log "Disabled Google Chrome apt repo due to key/signature errors: $disabled_repo_file"
  fi
}

is_google_chrome_repo_present() {
  local chrome_repo_file="/etc/apt/sources.list.d/google-chrome.list"
  [[ -f "$chrome_repo_file" ]]
}

apt_update_with_repo_recovery() {
  if apt-get update; then
    APT_UPDATE_FINAL_STATUS="ok"
    return 0
  fi

  if is_google_chrome_repo_present; then
    log "apt update failed; attempting Google Chrome repo key repair"
    if repair_google_chrome_repo_key; then
      if apt-get update; then
        APT_UPDATE_RECOVERY_ACTION="chrome-key-refreshed"
        APT_UPDATE_FINAL_STATUS="ok"
        log "Recovered apt update by refreshing Google Chrome apt key"
        return 0
      fi
    fi

    log "Google Chrome repo still failing; temporarily disabling repo and retrying apt update"
    disable_google_chrome_repo
    apt-get update
    APT_UPDATE_RECOVERY_ACTION="chrome-repo-disabled"
    APT_UPDATE_FINAL_STATUS="ok"
    return 0
  fi

  APT_UPDATE_FINAL_STATUS="failed"
  return 1
}

print_repo_health_summary() {
  local chrome_repo_file="/etc/apt/sources.list.d/google-chrome.list"
  local chrome_repo_disabled_file="/etc/apt/sources.list.d/google-chrome.list.disabled"
  local chrome_key_file="/etc/apt/keyrings/google-chrome.gpg"

  cat <<EOF

Repository health summary:
  - apt update status: $APT_UPDATE_FINAL_STATUS
EOF

  case "$APT_UPDATE_RECOVERY_ACTION" in
    chrome-key-refreshed)
      cat <<'EOF'
  - recovery action: refreshed Google Chrome apt key during this run
EOF
      ;;
    chrome-repo-disabled)
      cat <<'EOF'
  - recovery action: disabled Google Chrome apt repo to allow bootstrap to continue
EOF
      ;;
    *)
      cat <<'EOF'
  - recovery action: none needed
EOF
      ;;
  esac

  if [[ -f "$chrome_repo_file" ]]; then
    cat <<'EOF'
  - chrome repo file: enabled
EOF
  elif [[ -f "$chrome_repo_disabled_file" ]]; then
    cat <<'EOF'
  - chrome repo file: disabled (google-chrome.list.disabled present)
EOF
  else
    cat <<'EOF'
  - chrome repo file: not configured
EOF
  fi

  if [[ -f "$chrome_key_file" ]]; then
    cat <<'EOF'
  - chrome apt keyring: present
EOF
  else
    cat <<'EOF'
  - chrome apt keyring: missing
EOF
  fi
}

print_banner() {
  local title="$1"
  local subtitle="${2:-}"
  local border="============================================================"
  printf '\n%s\n' "$border"
  printf '== %s\n' "$title"
  if [[ -n "$subtitle" ]]; then
    printf '== %s\n' "$subtitle"
  fi
  printf '%s\n' "$border"
}

init_logging() {
  local timestamp="$(date '+%Y%m%d-%H%M%S')"
  local log_dir="${BOOTSTRAP_LOG_DIR:-$PWD}"
  local latest_log_file="${log_dir}/${LOG_BASENAME}.log"
  local run_log_file="${log_dir}/${LOG_BASENAME}-${timestamp}.log"

  # BOOTSTRAP_LOG_FILE remains supported as an explicit single-file override.
  if [[ -n "${BOOTSTRAP_LOG_FILE:-}" ]]; then
    latest_log_file="$BOOTSTRAP_LOG_FILE"
    run_log_file="$BOOTSTRAP_LOG_FILE"
  fi

  mkdir -p "$(dirname "$latest_log_file")"
  touch "$latest_log_file"

  if [[ "$run_log_file" != "$latest_log_file" ]]; then
    touch "$run_log_file"
    : > "$latest_log_file"
  fi

  if [[ "${EDGE_BOOTSTRAP_LOGGING_ACTIVE:-no}" != "yes" ]]; then
    export EDGE_BOOTSTRAP_LOGGING_ACTIVE="yes"
    if [[ "$run_log_file" == "$latest_log_file" ]]; then
      exec > >(tee -a "$latest_log_file") 2>&1
    else
      exec > >(tee -a "$run_log_file" "$latest_log_file") 2>&1
    fi
  fi

  if [[ "$run_log_file" == "$latest_log_file" ]]; then
    log "Bootstrap log file: $latest_log_file"
  else
    log "Bootstrap log files: latest=$latest_log_file, run=$run_log_file"
  fi
}

normalize_yes_no() {
  local raw="${1:-}"
  case "${raw,,}" in
    y|yes|true|1|on)
      printf 'yes'
      ;;
    *)
      printf 'no'
      ;;
  esac
}

apply_mode_defaults() {
  PREPARE_NETBIRD_ROUTING_PEER="yes"
  INSTALL_DESKTOP="$(normalize_yes_no "$INSTALL_DESKTOP")"
  INSTALL_BLOOMINGEDGE_WALLPAPER="$(normalize_yes_no "$INSTALL_BLOOMINGEDGE_WALLPAPER")"
  INSTALL_PORTAINER="$(normalize_yes_no "$INSTALL_PORTAINER")"
  CONFIGURE_UFW="$(normalize_yes_no "$CONFIGURE_UFW")"
  ENABLE_FULL_UPGRADE="$(normalize_yes_no "$ENABLE_FULL_UPGRADE")"
  REPAIR_MODE="$(normalize_yes_no "$REPAIR_MODE")"
  FORCE_NETBIRD_REENROLL="$(normalize_yes_no "$FORCE_NETBIRD_REENROLL")"
  FORCE_PORTAINER_REDEPLOY="$(normalize_yes_no "$FORCE_PORTAINER_REDEPLOY")"

  if [[ "$REPAIR_MODE" == "yes" ]]; then
    # Repair mode forces re-apply of key mutable components.
    PREPARE_NETBIRD_ROUTING_PEER="yes"
    INSTALL_DESKTOP="yes"
    INSTALL_PORTAINER="yes"
    CONFIGURE_UFW="yes"
    FORCE_NETBIRD_REENROLL="yes"
    FORCE_PORTAINER_REDEPLOY="yes"
  fi
}

show_mode_summary() {
  log "Mode summary: REPAIR_MODE=$REPAIR_MODE, PREPARE_NETBIRD_ROUTING_PEER=$PREPARE_NETBIRD_ROUTING_PEER, FORCE_NETBIRD_REENROLL=$FORCE_NETBIRD_REENROLL, FORCE_PORTAINER_REDEPLOY=$FORCE_PORTAINER_REDEPLOY"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script with sudo." >&2
    exit 1
  fi
}

run_apt_update() {
  log "Refreshing apt metadata"
  apt_update_with_repo_recovery

  if [[ "$ENABLE_FULL_UPGRADE" == "yes" ]]; then
    log "Applying in-release package upgrades (apt-get upgrade only; no Ubuntu release upgrade)"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fi
}

install_packages() {
  local packages=("$@")
  log "Installing packages: ${packages[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

install_google_chrome() {
  local arch
  arch="$(dpkg --print-architecture)"

  if [[ "$arch" != "amd64" ]]; then
    log "Skipping Google Chrome install on unsupported architecture: $arch"
    return
  fi

  if command -v google-chrome >/dev/null 2>&1; then
    log "Google Chrome already installed"
    return
  fi

  log "Installing Google Chrome"
  install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/google-chrome.gpg ]]; then
    repair_google_chrome_repo_key
  fi

  cat >/etc/apt/sources.list.d/google-chrome.list <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main
EOF

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable
}

configure_default_browser_for_user() {
  local user_name="$1"
  local user_home="$2"
  local helpers_rc="$user_home/.config/xfce4/helpers.rc"
  local exo_xml="$user_home/.config/xfce4/xfconf/xfce-perchannel-xml/exo.xml"
  local applications_dir="$user_home/.config"
  local mimeapps_list="$applications_dir/mimeapps.list"
  local local_bin_dir="$user_home/.local/bin"
  local local_applications_dir="$user_home/.local/share/applications"
  local browser_wrapper_script="$local_bin_dir/bcl-chrome-browser"
  local browser_desktop_file="$local_applications_dir/bcl-chrome-browser.desktop"

  if ! command -v google-chrome >/dev/null 2>&1 && ! command -v google-chrome-stable >/dev/null 2>&1; then
    log "Skipping default browser configuration; Chrome binary not found"
    return
  fi

  install -d -m 0755 "$user_home/.config/xfce4/xfconf/xfce-perchannel-xml" "$applications_dir" "$local_bin_dir" "$local_applications_dir"

  cat > "$browser_wrapper_script" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

exec /usr/bin/google-chrome-stable --password-store=basic "$@"
EOF

cat > "$browser_desktop_file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Comment=Access the Internet
Exec=$browser_wrapper_script %U
Terminal=false
Icon=google-chrome
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
EOF

  cat > "$helpers_rc" <<'EOF'
WebBrowser=custom-WebBrowser
WebBrowserDismissed=true
EOF

  cat > "$exo_xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>

<channel name="exo" version="1.0">
  <property name="helpers" type="empty">
    <property name="WebBrowser" type="empty">
      <property name="Default" type="string" value="CustomWebBrowser"/>
      <property name="CustomWebBrowser" type="string" value="$browser_wrapper_script"/>
    </property>
  </property>
</channel>
EOF

  cat > "$mimeapps_list" <<'EOF'
[Default Applications]
text/html=bcl-chrome-browser.desktop
x-scheme-handler/http=bcl-chrome-browser.desktop
x-scheme-handler/https=bcl-chrome-browser.desktop
x-scheme-handler/about=bcl-chrome-browser.desktop
x-scheme-handler/unknown=bcl-chrome-browser.desktop
EOF

  chmod 0755 "$browser_wrapper_script"
  chmod 0644 "$browser_desktop_file" "$helpers_rc" "$exo_xml" "$mimeapps_list"

  chown "$user_name":"$user_name" "$browser_wrapper_script" "$browser_desktop_file" "$helpers_rc" "$exo_xml" "$mimeapps_list"

  # Configure desktop defaults via user session tools when available.
  runuser -u "$user_name" -- xdg-settings set default-web-browser bcl-chrome-browser.desktop >/dev/null 2>&1 || true
  runuser -u "$user_name" -- xdg-mime default bcl-chrome-browser.desktop text/html x-scheme-handler/http x-scheme-handler/https >/dev/null 2>&1 || true

  log "Configured Chrome launcher/default browser for $user_name"
}

repair_desktop_user_permissions() {
  local user_name="$1"
  local user_home="$2"

  install -d -m 0755 "$user_home/.config" "$user_home/.cache" "$user_home/.local" "$user_home/.local/bin" "$user_home/.local/share" "$user_home/.local/share/applications"
  install -d -m 0700 "$user_home/.local/share/keyrings"

  chown -R "$user_name":"$user_name" "$user_home/.config" "$user_home/.cache" "$user_home/.local"
  chmod 0700 "$user_home/.local/share/keyrings"

  log "Repaired desktop profile permissions for $user_name"
}

install_wallpaper_asset() {
  if [[ ! -f "$WALLPAPER_SOURCE_PATH" ]]; then
    log "Skipping wallpaper install; source image not found: $WALLPAPER_SOURCE_PATH"
    return
  fi

  install -m 0755 -d "$(dirname "$WALLPAPER_TARGET_PATH")"
  install -m 0644 "$WALLPAPER_SOURCE_PATH" "$WALLPAPER_TARGET_PATH"
  log "Installed BloomingEdge wallpaper: $WALLPAPER_TARGET_PATH"
}

configure_xfce_wallpaper() {
  local user_name="$1"
  local user_home="$2"
  local xfce_dir="$user_home/.config/xfce4/xfconf/xfce-perchannel-xml"
  local xfce_wallpaper_xml="$xfce_dir/xfce4-desktop.xml"
  local xfce_displays_xml="$xfce_dir/displays.xml"
  local autostart_dir="$user_home/.config/autostart"
  local xfce_autostart_dir="$user_home/.config/xfce4/autostart"
  local local_bin_dir="$user_home/.local/bin"
  local wallpaper_setter_script="$local_bin_dir/bloomingedge-set-wallpaper.sh"
  local wallpaper_autostart_desktop="$autostart_dir/bloomingedge-set-wallpaper.desktop"
  local xfce_wallpaper_autostart_desktop="$xfce_autostart_dir/bloomingedge-set-wallpaper.desktop"
  local display_popup_override_desktop="$autostart_dir/xfce4-display-settings.desktop"
  local xubuntu_display_settings_override_desktop="$autostart_dir/xfce4-settings-helper-autostart.desktop"

  install -d -m 0755 "$xfce_dir"

  cat > "$xfce_wallpaper_xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="$WALLPAPER_TARGET_PATH"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
      <property name="monitorVirtual1" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="$WALLPAPER_TARGET_PATH"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF

  cat > "$xfce_displays_xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="displays" version="1.0">
  <property name="Notify" type="bool" value="false"/>
  <property name="AutoEnableProfiles" type="bool" value="false"/>
</channel>
EOF

  install -d -m 0755 "$autostart_dir" "$xfce_autostart_dir" "$local_bin_dir"

  cat > "$wallpaper_setter_script" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" != "--worker" ]]; then
  nohup "$0" --worker >/dev/null 2>&1 &
  exit 0
fi

WALLPAPER_SOURCE="$HOME/bcl-edge-node-build/img/BloomingEdge_Network.png"
WALLPAPER_TARGET="/usr/share/backgrounds/BloomingEdge_Network.png"

# Ensure the file exists at the source
if [[ ! -f "$WALLPAPER_SOURCE" ]]; then
  exit 1
fi

# Copy to system location
sudo cp "$WALLPAPER_SOURCE" "$WALLPAPER_TARGET"
sudo chmod 0644 "$WALLPAPER_TARGET"

# Wait for XFCE to be ready
sleep 3

# Set it using xfconf-query - discover ALL monitors dynamically
if command -v xfconf-query >/dev/null 2>&1; then
  # Get ALL last-image properties from all monitors
  xfconf-query -c xfce4-desktop -l 2>/dev/null | grep 'last-image' | while read -r prop; do
    xfconf-query -c xfce4-desktop -p "$prop" -s "$WALLPAPER_TARGET" -t string 2>/dev/null || true
    
    # Also set image-style to 5 (scaled) for the same path
    style_prop="${prop%/last-image}/image-style"
    xfconf-query -c xfce4-desktop -p "$style_prop" -s 5 -t int 2>/dev/null || true
  done
  
  # Reload desktop
  xfdesktop --reload >/dev/null 2>&1 || true
fi
EOF

  cat > "$wallpaper_autostart_desktop" <<EOF
[Desktop Entry]
Type=Application
Name=BloomingEdge Wallpaper
Comment=Applies BloomingEdge wallpaper for XFCE sessions
Exec=$wallpaper_setter_script
X-GNOME-Autostart-Delay=3
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF

  cp "$wallpaper_autostart_desktop" "$xfce_wallpaper_autostart_desktop"

  cat > "$display_popup_override_desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=XFCE Display Settings
Hidden=true
X-GNOME-Autostart-enabled=false
NoDisplay=true
EOF

  cat > "$xubuntu_display_settings_override_desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=XFCE Settings Helper
Hidden=true
X-GNOME-Autostart-enabled=false
NoDisplay=true
EOF

  chmod 0755 "$wallpaper_setter_script"
  chmod 0644 "$wallpaper_autostart_desktop" "$xfce_wallpaper_autostart_desktop" "$display_popup_override_desktop" "$xubuntu_display_settings_override_desktop"

  chown -R "$user_name":"$user_name" "$user_home/.config/xfce4" "$autostart_dir" "$xfce_autostart_dir" "$local_bin_dir"
  log "Configured XFCE wallpaper for $user_name"
}

configure_wallpaper_session_hook() {
  local user_name="$1"
  local user_home="$2"
  local xprofile_file="$user_home/.xprofile"
  local wallpaper_setter_script="$user_home/.local/bin/bloomingedge-set-wallpaper.sh"
  local marker="# bcl-edge wallpaper hook"

  if [[ ! -f "$wallpaper_setter_script" ]]; then
    log "Skipping wallpaper session hook; wallpaper helper not found at $wallpaper_setter_script"
    return
  fi

  if [[ ! -f "$xprofile_file" ]]; then
    cat > "$xprofile_file" <<EOF
#!/bin/sh
$marker
if [ -x "$wallpaper_setter_script" ]; then
  "$wallpaper_setter_script" >/dev/null 2>&1 || true
fi
EOF
  elif ! grep -Fq "$marker" "$xprofile_file"; then
    cat >> "$xprofile_file" <<EOF

$marker
if [ -x "$wallpaper_setter_script" ]; then
  "$wallpaper_setter_script" >/dev/null 2>&1 || true
fi
EOF
  fi

  chown "$user_name":"$user_name" "$xprofile_file"
  chmod 0755 "$xprofile_file"
  log "Configured wallpaper session hook for $user_name"
}

configure_lightdm() {
  local lightdm_dir="/etc/lightdm/lightdm.conf.d"
  local lightdm_conf="${lightdm_dir}/50-bcl-edge.conf"

  install -d -m 0755 "$lightdm_dir"
  cat > "$lightdm_conf" <<'EOF'
[Seat:*]
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOF

  log "Configured LightDM for local XFCE sessions"
}

configure_network_manager_for_desktop() {
  local nm_conf="/etc/NetworkManager/NetworkManager.conf"
  local nm_conf_backup="/etc/NetworkManager/NetworkManager.conf.bcl-edge.bak"

  install -d -m 0755 /etc/NetworkManager

  if [[ -f "$nm_conf" && ! -f "$nm_conf_backup" ]]; then
    cp -a "$nm_conf" "$nm_conf_backup"
    log "Backed up existing NetworkManager config to $nm_conf_backup"
  fi

  cat > "$nm_conf" <<'EOF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
EOF

  install -d -m 0755 /etc/netplan
  cat > "$NETPLAN_RENDERER_FILE" <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
  chmod 0600 "$NETPLAN_RENDERER_FILE"

  netplan generate >/dev/null
  netplan apply >/dev/null

  systemctl restart NetworkManager
  log "Configured NetworkManager to manage interfaces and applied netplan renderer=NetworkManager"
}

configure_nm_applet_autostart() {
  local user_name="$1"
  local user_home="$2"
  local autostart_dir="$user_home/.config/autostart"
  local user_nm_applet_desktop="$autostart_dir/nm-applet.desktop"
  local system_nm_applet_desktop="/etc/xdg/autostart/nm-applet.desktop"

  install -d -m 0755 "$autostart_dir"

  if [[ -f "$system_nm_applet_desktop" ]]; then
    cp "$system_nm_applet_desktop" "$user_nm_applet_desktop"
    chown "$user_name":"$user_name" "$user_nm_applet_desktop"
    chmod 0644 "$user_nm_applet_desktop"
    log "Enabled NetworkManager applet autostart for $user_name"
  else
    log "Skipping nm-applet autostart; $system_nm_applet_desktop not found"
  fi
}

configure_gnome_keyring_for_desktop() {
  local lightdm_pam_file="/etc/pam.d/lightdm"
  local xrdp_pam_file="/etc/pam.d/xrdp-sesman"

  if [[ -f "$lightdm_pam_file" ]] && ! grep -Fq 'pam_gnome_keyring.so' "$lightdm_pam_file"; then
    cat >> "$lightdm_pam_file" <<'EOF'
auth optional pam_gnome_keyring.so
session optional pam_gnome_keyring.so auto_start
EOF
  fi

  if [[ -f "$xrdp_pam_file" ]] && ! grep -Fq 'pam_gnome_keyring.so' "$xrdp_pam_file"; then
    cat >> "$xrdp_pam_file" <<'EOF'
auth optional pam_gnome_keyring.so
session optional pam_gnome_keyring.so auto_start
EOF
  fi

  log "Configured GNOME keyring integration for desktop sessions"
}

configure_xorg_for_xrdp() {
  cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

  log "Configured Xorg wrapper for XRDP sessions"
}

enable_service() {
  local service_name="$1"
  log "Enabling service: $service_name"
  systemctl enable --now "$service_name"
}

is_container_running() {
  local container_name="$1"
  docker ps --format '{{.Names}}' | grep -Fxq "$container_name"
}

enable_display_manager() {
  local candidates=(lightdm gdm3 sddm)
  local service_name

  for service_name in "${candidates[@]}"; do
    if systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null | grep -q "^${service_name}\\.service"; then
      enable_service "$service_name"
      return 0
    fi
  done

  log "No known display manager service found (tried: ${candidates[*]}). Skipping display manager enable."
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed"
  else
    log "Installing Docker"
    curl -fsSL https://get.docker.com | sh
  fi

  if id "$ADMIN_USER" >/dev/null 2>&1; then
    log "Ensuring $ADMIN_USER is in the docker group"
    usermod -aG docker "$ADMIN_USER"
  else
    log "Skipping docker group assignment; user $ADMIN_USER does not exist"
  fi

  enable_service docker
}

install_netbird() {
  if command -v netbird >/dev/null 2>&1; then
    log "NetBird already installed"
    return
  fi

  log "Installing NetBird"
  curl -fsSL https://pkgs.netbird.io/install.sh | bash
}

configure_netbird_routing_prereqs() {
  local sysctl_file="/etc/sysctl.d/99-netbird-routing.conf"
  log "Configuring NetBird routing-peer prerequisites (IP forwarding)"

  cat > "$sysctl_file" <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true
  sysctl --system >/dev/null || true

  log "NetBird routing-peer host preparation complete"
}

enroll_netbird() {
  if [[ -z "$NETBIRD_SETUP_KEY" ]]; then
    log "NetBird setup key not supplied; skipping enrollment"
    return
  fi

  if [[ "$FORCE_NETBIRD_REENROLL" == "yes" ]]; then
    log "Force NetBird re-enroll enabled; disconnecting current peer session first"
    netbird down >/dev/null 2>&1 || true
  else
    if netbird status 2>/dev/null | grep -Eqi 'Connected|Logged in|Management: Connected'; then
      log "NetBird already connected; skipping re-enrollment (set FORCE_NETBIRD_REENROLL=yes to force)"
      return
    fi
  fi

  log "Enrolling NetBird peer as $NETBIRD_HOSTNAME"
  netbird up --setup-key "$NETBIRD_SETUP_KEY" --hostname "$NETBIRD_HOSTNAME"
}

configure_desktop() {
  if [[ "$INSTALL_DESKTOP" != "yes" ]]; then
    log "Skipping desktop and XRDP installation"
    return
  fi

  install_packages "${DESKTOP_PACKAGES[@]}"
  install_google_chrome
  if [[ "$INSTALL_BLOOMINGEDGE_WALLPAPER" == "yes" ]]; then
    install_wallpaper_asset
  else
    log "Skipping BloomingEdge wallpaper installation"
  fi

  if id "$ADMIN_USER" >/dev/null 2>&1; then
    local user_home
    user_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    repair_desktop_user_permissions "$ADMIN_USER" "$user_home"
    log "Configuring XFCE session for $ADMIN_USER"
    cat > "$user_home/.xsession" <<'EOF'
#!/bin/sh
if command -v gnome-keyring-daemon >/dev/null 2>&1; then
  eval "$(gnome-keyring-daemon --start --components=pkcs11,secrets,ssh)"
  export SSH_AUTH_SOCK
fi
exec startxfce4
EOF
    chown "$ADMIN_USER":"$ADMIN_USER" "$user_home/.xsession"
    chmod 755 "$user_home/.xsession"
    configure_default_browser_for_user "$ADMIN_USER" "$user_home"
    configure_nm_applet_autostart "$ADMIN_USER" "$user_home"
    if [[ "$INSTALL_BLOOMINGEDGE_WALLPAPER" == "yes" ]]; then
      configure_xfce_wallpaper "$ADMIN_USER" "$user_home"
      configure_wallpaper_session_hook "$ADMIN_USER" "$user_home"
    else
      log "Skipping XFCE wallpaper configuration"
    fi
  else
    log "Skipping user session configuration; user $ADMIN_USER does not exist"
  fi

  configure_network_manager_for_desktop

  log "Configuring XRDP to start XFCE"
  cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh

if [ -r /etc/profile ]; then
  . /etc/profile
fi

if [ -r "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi

export DESKTOP_SESSION=xfce
export XDG_CURRENT_DESKTOP=XFCE

# Clear stale values so XRDP can create a fresh desktop session.
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR

# Stale XFCE session state can cause immediate XRDP logout on reconnects/reboots.
if [ -d "$HOME/.cache/sessions" ]; then
  rm -f "$HOME/.cache/sessions"/*
fi

if command -v dbus-launch >/dev/null 2>&1; then
  exec dbus-launch --exit-with-session startxfce4
fi

exec startxfce4
EOF
  chmod 0755 /etc/xrdp/startwm.sh
  configure_xorg_for_xrdp
  configure_gnome_keyring_for_desktop

  if id -nG xrdp 2>/dev/null | tr ' ' '\n' | grep -Fxq ssl-cert; then
    log "xrdp is already a member of ssl-cert"
  else
    adduser xrdp ssl-cert
  fi

  configure_lightdm
  enable_service xrdp
  systemctl restart xrdp-sesman xrdp
  enable_display_manager
}

install_portainer_standalone() {
  if [[ "$INSTALL_PORTAINER" != "yes" ]]; then
    log "Skipping Portainer deployment"
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log "Skipping Portainer; Docker is not available"
    return
  fi

  if docker ps -a --format '{{.Names}}' | grep -Fxq portainer-agent; then
    log "Removing legacy Portainer agent container"
    docker rm -f portainer-agent >/dev/null 2>&1 || true
  fi

  if docker ps -a --format '{{.Names}}' | grep -Fxq "$PORTAINER_CONTAINER_NAME"; then
    if [[ "$FORCE_PORTAINER_REDEPLOY" == "yes" ]]; then
      log "Force Portainer redeploy enabled; removing existing container"
      docker rm -f "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1 || true
    else
      log "Portainer container already exists; ensuring it is running"
      docker start "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1 || true
      if is_container_running "$PORTAINER_CONTAINER_NAME"; then
        log "Portainer container is running"
      else
        log "WARNING: Portainer container exists but is not running"
        docker ps -a --filter "name=$PORTAINER_CONTAINER_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
      fi
      return
    fi
  fi

  log "Deploying standalone Portainer server container"
  docker run -d \
    --name "$PORTAINER_CONTAINER_NAME" \
    --restart=always \
    -p 9000:9000 \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /opt/portainer:/data \
    portainer/portainer-ce:latest

  if is_container_running "$PORTAINER_CONTAINER_NAME"; then
    log "Portainer server deployed and running"
  else
    log "WARNING: Portainer deployment completed but container is not running"
    docker ps -a --filter "name=$PORTAINER_CONTAINER_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
  fi
}

configure_firewall() {
  if [[ "$CONFIGURE_UFW" != "yes" ]]; then
    log "Skipping UFW configuration"
    return
  fi

  log "Allowing SSH and XRDP through UFW"
  if ufw status | grep -Eqi '(^|\s)(22/tcp|OpenSSH)(\s|$)'; then
    log "UFW rule for SSH already present"
  else
    ufw allow ssh
  fi

  if ufw status | grep -Eqi '(^|\s)3389/tcp(\s|$)'; then
    log "UFW rule for XRDP (3389/tcp) already present"
  else
    ufw allow 3389/tcp
  fi

  if ufw status | grep -Eqi '(^|\s)(9000/tcp|9443/tcp)(\s|$)'; then
    log "UFW rules for Portainer already present"
  else
    ufw allow 9000/tcp
    ufw allow 9443/tcp
  fi

  ufw --force enable
}

prepare_librenms_path() {
  log "Creating LibreNMS working directory"
  mkdir -p /opt/librenms
}

print_next_steps() {
  cat <<EOF

Bootstrap complete.

Manual follow-up is still required for:
  - netplan configuration and validation
  - NetBird route or exit-node creation in the dashboard
  - LibreNMS poller deployment and registration
  - site-specific firewall restrictions over NetBird
  - final service validation and reboot if package upgrades require it

If NETBIRD_SETUP_KEY was not supplied, rerun the script with a setup key to
enroll the node as a NetBird peer automatically.

If $ADMIN_USER was added to the docker group, log out and back in before using Docker without sudo.
EOF

  print_repo_health_summary
}

main() {
  require_root
  init_logging
  apply_mode_defaults

  print_banner "BOOTSTRAP START" "Copyright (c) 2026 Blooming Color, Inc. All rights reserved."
  show_mode_summary

  print_banner "APT UPDATE AND UPGRADE"
  run_apt_update

  print_banner "BASE PACKAGE INSTALL"
  install_packages "${BASE_PACKAGES[@]}"

  print_banner "CORE SERVICE ENABLEMENT"
  enable_service chrony
  enable_service snmpd

  print_banner "DOCKER INSTALLATION"
  install_docker

  print_banner "NETBIRD INSTALLATION"
  install_netbird

  print_banner "NETBIRD ROUTING PEER PREPARATION"
  configure_netbird_routing_prereqs

  print_banner "NETBIRD ENROLLMENT"
  enroll_netbird

  print_banner "DESKTOP AND XRDP CONFIGURATION"
  configure_desktop

  print_banner "PORTAINER AGENT DEPLOYMENT"
  install_portainer_standalone

  print_banner "LIBRENMS DIRECTORY PREPARATION"
  prepare_librenms_path

  print_banner "FIREWALL CONFIGURATION"
  configure_firewall

  print_banner "POST-INSTALL NEXT STEPS"
  print_next_steps

  print_banner "BOOTSTRAP COMPLETE"
}

main "$@"