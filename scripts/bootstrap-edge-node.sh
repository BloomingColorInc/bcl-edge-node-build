#!/usr/bin/env bash

set -euo pipefail

DEFAULT_ADMIN_USER="${SUDO_USER:-netadmin}"
ADMIN_USER="${EDGE_ADMIN_USER:-$DEFAULT_ADMIN_USER}"
NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"
NETBIRD_HOSTNAME="${NETBIRD_HOSTNAME:-$(hostname -s)}"
INSTALL_DESKTOP="${INSTALL_DESKTOP:-yes}"
INSTALL_NETDATA="${INSTALL_NETDATA:-yes}"
INSTALL_PORTAINER="${INSTALL_PORTAINER:-yes}"
CONFIGURE_UFW="${CONFIGURE_UFW:-yes}"
ENABLE_FULL_UPGRADE="${ENABLE_FULL_UPGRADE:-yes}"
PORTAINER_CONTAINER_NAME="${PORTAINER_CONTAINER_NAME:-portainer-agent}"

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
    log "Applying package upgrades"
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

  adduser xrdp ssl-cert
  enable_service xrdp
  enable_service display-manager
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
    log "Portainer agent container already exists"
    docker start "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1 || true
    return
  fi

  log "Deploying Portainer agent container"
  docker run -d \
    --name "$PORTAINER_CONTAINER_NAME" \
    --restart=always \
    -p 9001:9001 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/volumes:/var/lib/docker/volumes \
    portainer/agent
}

install_netdata() {
  if [[ "$INSTALL_NETDATA" != "yes" ]]; then
    log "Skipping Netdata installation"
    return
  fi

  if command -v netdata >/dev/null 2>&1; then
    log "Netdata already installed"
    return
  fi

  log "Installing Netdata"
  bash <(curl -Ss https://my-netdata.io/kickstart.sh) --non-interactive
}

configure_firewall() {
  if [[ "$CONFIGURE_UFW" != "yes" ]]; then
    log "Skipping UFW configuration"
    return
  fi

  log "Allowing SSH and XRDP through UFW"
  ufw allow ssh
  ufw allow 3389/tcp
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
  run_apt_update
  install_packages "${BASE_PACKAGES[@]}"
  enable_service chrony
  enable_service snmpd
  install_docker
  install_netbird
  enroll_netbird
  configure_desktop
  install_portainer_agent
  install_netdata
  prepare_librenms_path
  configure_firewall
  print_next_steps
}

main "$@"