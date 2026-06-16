#!/usr/bin/env bash

set -euo pipefail

DEFAULT_ADMIN_USER="${SUDO_USER:-netadmin}"
ADMIN_USER="${EDGE_ADMIN_USER:-$DEFAULT_ADMIN_USER}"
NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"
NETBIRD_HOSTNAME="${NETBIRD_HOSTNAME:-$(hostname -s)}"
INSTALL_DESKTOP="${INSTALL_DESKTOP:-yes}"
INSTALL_PORTAINER="${INSTALL_PORTAINER:-yes}"
CONFIGURE_UFW="${CONFIGURE_UFW:-yes}"
ENABLE_FULL_UPGRADE="${ENABLE_FULL_UPGRADE:-yes}"
REPAIR_MODE="${REPAIR_MODE:-no}"
FORCE_NETBIRD_REENROLL="${FORCE_NETBIRD_REENROLL:-no}"
FORCE_PORTAINER_REDEPLOY="${FORCE_PORTAINER_REDEPLOY:-no}"
PORTAINER_CONTAINER_NAME="${PORTAINER_CONTAINER_NAME:-portainer-agent}"
LOG_BASENAME="${BOOTSTRAP_LOG_BASENAME:-edge-node-bootstrap}"

BASE_PACKAGES=(
  curl
  wget
  git
  htop
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
  xorg
  dbus-x11
  xubuntu-default-settings
  xrdp
  xorgxrdp
)

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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
  INSTALL_DESKTOP="$(normalize_yes_no "$INSTALL_DESKTOP")"
  INSTALL_PORTAINER="$(normalize_yes_no "$INSTALL_PORTAINER")"
  CONFIGURE_UFW="$(normalize_yes_no "$CONFIGURE_UFW")"
  ENABLE_FULL_UPGRADE="$(normalize_yes_no "$ENABLE_FULL_UPGRADE")"
  REPAIR_MODE="$(normalize_yes_no "$REPAIR_MODE")"
  FORCE_NETBIRD_REENROLL="$(normalize_yes_no "$FORCE_NETBIRD_REENROLL")"
  FORCE_PORTAINER_REDEPLOY="$(normalize_yes_no "$FORCE_PORTAINER_REDEPLOY")"

  if [[ "$REPAIR_MODE" == "yes" ]]; then
    # Repair mode forces re-apply of key mutable components.
    INSTALL_DESKTOP="yes"
    INSTALL_PORTAINER="yes"
    CONFIGURE_UFW="yes"
    FORCE_NETBIRD_REENROLL="yes"
    FORCE_PORTAINER_REDEPLOY="yes"
  fi
}

show_mode_summary() {
  log "Mode summary: REPAIR_MODE=$REPAIR_MODE, FORCE_NETBIRD_REENROLL=$FORCE_NETBIRD_REENROLL, FORCE_PORTAINER_REDEPLOY=$FORCE_PORTAINER_REDEPLOY"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script with sudo." >&2
    exit 1
  fi
}

run_apt_update() {
  log "Refreshing apt metadata"
  apt-get update

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

  if id "$ADMIN_USER" >/dev/null 2>&1; then
    local user_home
    user_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    log "Configuring XFCE session for $ADMIN_USER"
    printf 'xfce4-session\n' > "$user_home/.xsession"
    chown "$ADMIN_USER":"$ADMIN_USER" "$user_home/.xsession"
    chmod 755 "$user_home/.xsession"
  else
    log "Skipping user session configuration; user $ADMIN_USER does not exist"
  fi

  log "Configuring XRDP to start XFCE"
  python3 - <<'PY'
from pathlib import Path

path = Path('/etc/xrdp/startwm.sh')
content = path.read_text()
marker = 'export DESKTOP_SESSION=xfce\nexport XDG_CURRENT_DESKTOP=XFCE\nexec startxfce4\n'

if marker in content:
    raise SystemExit(0)

lines = content.splitlines()
while lines and lines[-1].strip() == '':
    lines.pop()

replacement_done = False
for index in range(len(lines) - 1, -1, -1):
    line = lines[index].strip()
    if line.startswith('exec ') or line.startswith('test -x '):
        lines = lines[:index]
        replacement_done = True
        break

if not replacement_done:
    lines.append('')

lines.extend([
    'export DESKTOP_SESSION=xfce',
    'export XDG_CURRENT_DESKTOP=XFCE',
    'exec startxfce4',
    '',
])
path.write_text('\n'.join(lines))
PY

  if id -nG xrdp 2>/dev/null | tr ' ' '\n' | grep -Fxq ssl-cert; then
    log "xrdp is already a member of ssl-cert"
  else
    adduser xrdp ssl-cert
  fi
  enable_service xrdp
  enable_display_manager
}

install_portainer_agent() {
  if [[ "$INSTALL_PORTAINER" != "yes" ]]; then
    log "Skipping Portainer agent deployment"
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log "Skipping Portainer agent; Docker is not available"
    return
  fi

  if docker ps -a --format '{{.Names}}' | grep -Fxq "$PORTAINER_CONTAINER_NAME"; then
    if [[ "$FORCE_PORTAINER_REDEPLOY" == "yes" ]]; then
      log "Force Portainer redeploy enabled; removing existing container"
      docker rm -f "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1 || true
    else
      log "Portainer agent container already exists; ensuring it is running"
      docker start "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1 || true
      if is_container_running "$PORTAINER_CONTAINER_NAME"; then
        log "Portainer agent container is running"
      else
        log "WARNING: Portainer agent container exists but is not running"
        docker ps -a --filter "name=$PORTAINER_CONTAINER_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
      fi
      return
    fi
  fi

  log "Deploying Portainer agent container"
  docker run -d \
    --name "$PORTAINER_CONTAINER_NAME" \
    --restart=always \
    -p 9001:9001 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/volumes:/var/lib/docker/volumes \
    portainer/agent

  if is_container_running "$PORTAINER_CONTAINER_NAME"; then
    log "Portainer agent deployed and running"
  else
    log "WARNING: Portainer agent deployment completed but container is not running"
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

  print_banner "NETBIRD ENROLLMENT"
  enroll_netbird

  print_banner "DESKTOP AND XRDP CONFIGURATION"
  configure_desktop

  print_banner "PORTAINER AGENT DEPLOYMENT"
  install_portainer_agent

  print_banner "LIBRENMS DIRECTORY PREPARATION"
  prepare_librenms_path

  print_banner "FIREWALL CONFIGURATION"
  configure_firewall

  print_banner "POST-INSTALL NEXT STEPS"
  print_next_steps

  print_banner "BOOTSTRAP COMPLETE"
}

main "$@"