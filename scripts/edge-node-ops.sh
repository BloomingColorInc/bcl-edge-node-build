#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/docker-compose.yml}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-edge-node}"
BOOTSTRAP_SCRIPT="${BOOTSTRAP_SCRIPT:-$REPO_ROOT/scripts/bootstrap-edge-node.sh}"
EDGE_NODE_OPS_DASHBOARD_CLEAR="${EDGE_NODE_OPS_DASHBOARD_CLEAR:-1}"
EDGE_NODE_OPS_PANEL_SPACING_LINES="${EDGE_NODE_OPS_PANEL_SPACING_LINES:-1}"
LIBRENMS_POLLER_CONTAINER_NAME="${LIBRENMS_POLLER_CONTAINER_NAME:-librenms-dispatcher-agent}"
LIBRENMS_POLLER_IMAGE="${LIBRENMS_POLLER_IMAGE:-librenms/librenms:latest}"
MAIN_MENU_REQUESTED=0

if [[ -t 0 ]]; then
  INTERACTIVE=true
else
  INTERACTIVE=false
fi

trim() {
  local input="$1"
  input="${input#${input%%[![:space:]]*}}"
  input="${input%${input##*[![:space:]]}}"
  printf '%s' "$input"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

needs_root=false
if [[ "$EUID" -ne 0 ]]; then
  needs_root=true
fi

run_with_privilege() {
  if [[ "$needs_root" == true ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

ui_use_color() {
  [[ -z "${NO_COLOR:-}" ]] || return 1

  case "${TERM:-}" in
    ""|dumb) return 1 ;;
  esac

  [[ -t 1 || -w /dev/tty ]]
}

ui_color_code() {
  case "${1:-}" in
    blue) echo "34" ;;
    cyan) echo "36" ;;
    green) echo "32" ;;
    magenta) echo "35" ;;
    red) echo "31" ;;
    yellow) echo "33" ;;
    white) echo "37" ;;
    bright_blue) echo "94" ;;
    bright_cyan) echo "96" ;;
    bright_green) echo "92" ;;
    bright_magenta) echo "95" ;;
    bright_red) echo "91" ;;
    bright_yellow) echo "93" ;;
    bright_white) echo "97" ;;
    *) echo "" ;;
  esac
}

ui_style() {
  local text="$1" color="${2:-}" bold="${3:-0}" code=""

  if ! ui_use_color || [[ -z "${color}" ]]; then
    printf "%s" "${text}"
    return 0
  fi

  code="$(ui_color_code "${color}")"
  if [[ -z "${code}" ]]; then
    printf "%s" "${text}"
    return 0
  fi

  if [[ "${bold}" == "1" ]]; then
    printf '\033[1;%sm%s\033[0m' "${code}" "${text}"
  else
    printf '\033[%sm%s\033[0m' "${code}" "${text}"
  fi
}

ui_dimmer_color() {
  case "${1:-}" in
    bright_blue) echo "blue" ;;
    bright_cyan) echo "cyan" ;;
    bright_green) echo "green" ;;
    bright_magenta) echo "magenta" ;;
    bright_red) echo "red" ;;
    bright_yellow) echo "yellow" ;;
    bright_white) echo "white" ;;
    *) echo "${1:-white}" ;;
  esac
}

say() { printf "%s\n" "$(ui_style "INFO: $*" bright_cyan)"; }
ok() { printf "%s\n" "$(ui_style "OK: $*" bright_green)"; }
warn() { printf "%s\n" "$(ui_style "WARN: $*" bright_yellow)"; }
fail() { printf "%s\n" "$(ui_style "ERROR: $*" bright_red 1)"; }

ui_clear() {
  [[ "${EDGE_NODE_OPS_DASHBOARD_CLEAR}" == "1" ]] || return 0

  if [[ -w /dev/tty ]]; then
    tput clear >/dev/tty 2>/dev/null || printf '\033[2J\033[H' >/dev/tty
    return 0
  fi

  [[ -t 1 ]] || return 0
  tput clear 2>/dev/null || printf '\033[2J\033[H'
}

ui_terminal_width() {
  local cols=""
  cols="$(tput cols 2>/dev/null || echo 96)"
  [[ "${cols}" =~ ^[0-9]+$ ]] || cols=96
  (( cols < 72 )) && cols=72
  (( cols > 132 )) && cols=132
  printf "%s" "${cols}"
}

ui_repeat() {
  local char="$1" count="$2" buffer=""
  (( count > 0 )) || { printf ""; return 0; }
  printf -v buffer '%*s' "${count}" ''
  printf "%s" "${buffer// /${char}}"
}

ui_truncate() {
  local text="$1" width="$2"
  (( width > 0 )) || { printf ""; return 0; }

  if (( ${#text} <= width )); then
    printf "%s" "${text}"
    return 0
  fi

  if (( width == 1 )); then
    printf "%s" "${text:0:1}"
    return 0
  fi

  printf "%s..." "${text:0:$((width - 3))}"
}

ui_pad_right() {
  local text="$1" width="$2" pad_len=0
  local text_len="${#text}"

  if (( text_len >= width )); then
    printf "%s" "${text}"
    return 0
  fi

  pad_len=$((width - text_len))
  printf "%s%s" "${text}" "$(ui_repeat " " "${pad_len}")"
}

ui_panel_spacing() {
  local lines="${EDGE_NODE_OPS_PANEL_SPACING_LINES:-1}"
  [[ "${lines}" =~ ^[0-9]+$ ]] || lines=1

  while (( lines > 0 )); do
    echo
    lines=$((lines - 1))
  done
}

if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ [Uu][Tt][Ff]-?8 ]]; then
  UI_BOX_TL="╭"
  UI_BOX_TR="╮"
  UI_BOX_BL="╰"
  UI_BOX_BR="╯"
  UI_BOX_H="─"
  UI_BOX_V="│"
else
  UI_BOX_TL="+"
  UI_BOX_TR="+"
  UI_BOX_BL="+"
  UI_BOX_BR="+"
  UI_BOX_H="-"
  UI_BOX_V="|"
fi

ui_panel() {
  local title="$1" accent="${2:-bright_magenta}"
  shift 2
  local -a lines=("$@")
  local width="" inner_width="" frame_width="" title_text="" title_len="" horizontal=""
  local top="" bottom="" wrapped="" left_border="" right_border="" padded=""

  width="$(ui_terminal_width)"
  inner_width=$((width - 4))
  (( inner_width < 24 )) && inner_width=24
  frame_width=$((inner_width + 2))

  title_text="$(ui_truncate " ${title} " "${frame_width}")"
  title_len="${#title_text}"
  horizontal="$(ui_repeat "${UI_BOX_H}" "$((frame_width - title_len))")"
  top="${UI_BOX_TL}${title_text}${horizontal}${UI_BOX_TR}"
  printf "%s\n" "$(ui_style "${top}" "${accent}" 1)"

  left_border="$(ui_style "${UI_BOX_V}" "${accent}")"
  right_border="${left_border}"

  if (( ${#lines[@]} == 0 )); then
    lines=("")
  fi

  for line in "${lines[@]}"; do
    if [[ -z "${line}" ]]; then
      printf "%s %s %s\n" "${left_border}" "$(ui_repeat " " "${inner_width}")" "${right_border}"
      continue
    fi

    while IFS= read -r wrapped; do
      if (( ${#wrapped} > inner_width )); then
        wrapped="$(ui_truncate "${wrapped}" "${inner_width}")"
      fi
      padded="$(ui_pad_right "${wrapped}" "${inner_width}")"
      printf "%s %s %s\n" "${left_border}" "${padded}" "${right_border}"
    done < <(fold -s -w "${inner_width}" <<<"${line}")
  done

  bottom="${UI_BOX_BL}$(ui_repeat "${UI_BOX_H}" "${frame_width}")${UI_BOX_BR}"
  printf "%s\n" "$(ui_style "${bottom}" "${accent}" 1)"
  ui_panel_spacing
}

ui_panel_compact() {
  local spacing_lines="${EDGE_NODE_OPS_PANEL_SPACING_LINES:-1}"
  EDGE_NODE_OPS_PANEL_SPACING_LINES=0
  ui_panel "$@"
  EDGE_NODE_OPS_PANEL_SPACING_LINES="${spacing_lines}"
}

ui_panel_with_corner() {
  local title="$1" corner_text_raw="$2" accent="${3:-bright_magenta}"
  shift 3
  local -a lines=("$@")
  local width="" inner_width="" frame_width="" title_text="" corner_text="" horizontal=""
  local bottom="" wrapped="" left_border="" right_border="" padded=""
  local title_len=0 corner_len=0 title_room=0 horizontal_len=0 corner_color=""

  width="$(ui_terminal_width)"
  inner_width=$((width - 4))
  (( inner_width < 24 )) && inner_width=24
  frame_width=$((inner_width + 2))

  title_text=" ${title} "
  corner_text=" ${corner_text_raw} "

  if (( ${#corner_text} > frame_width - 1 )); then
    corner_text="$(ui_truncate "${corner_text}" "$((frame_width - 1))")"
  fi

  corner_len=${#corner_text}
  title_room=$((frame_width - corner_len))
  (( title_room < 1 )) && title_room=1
  title_text="$(ui_truncate "${title_text}" "${title_room}")"

  title_len=${#title_text}
  horizontal_len=$((frame_width - title_len - corner_len))
  (( horizontal_len < 0 )) && horizontal_len=0
  horizontal="$(ui_repeat "${UI_BOX_H}" "${horizontal_len}")"

  corner_color="$(ui_dimmer_color "${accent}")"
  printf "%s%s%s\n" \
    "$(ui_style "${UI_BOX_TL}${title_text}${horizontal}" "${accent}" 1)" \
    "$(ui_style "${corner_text}" "${corner_color}")" \
    "$(ui_style "${UI_BOX_TR}" "${accent}" 1)"

  left_border="$(ui_style "${UI_BOX_V}" "${accent}")"
  right_border="${left_border}"

  if (( ${#lines[@]} == 0 )); then
    lines=("")
  fi

  for line in "${lines[@]}"; do
    if [[ -z "${line}" ]]; then
      printf "%s %s %s\n" "${left_border}" "$(ui_repeat " " "${inner_width}")" "${right_border}"
      continue
    fi

    while IFS= read -r wrapped; do
      if (( ${#wrapped} > inner_width )); then
        wrapped="$(ui_truncate "${wrapped}" "${inner_width}")"
      fi
      padded="$(ui_pad_right "${wrapped}" "${inner_width}")"
      printf "%s %s %s\n" "${left_border}" "${padded}" "${right_border}"
    done < <(fold -s -w "${inner_width}" <<<"${line}")
  done

  bottom="${UI_BOX_BL}$(ui_repeat "${UI_BOX_H}" "${frame_width}")${UI_BOX_BR}"
  printf "%s\n" "$(ui_style "${bottom}" "${accent}" 1)"
  ui_panel_spacing
}

request_main_menu() {
  MAIN_MENU_REQUESTED=1
}

ui_nav_panel_full() {
  echo
  ui_panel "Navigation" "bright_magenta" \
    "b) Back" \
    "m) Main (h: Home)" \
    "q) Quit"
}

print_header() {
  local current_year=""
  current_year="$(date +%Y)"

  ui_panel_with_corner "BloomingEdge Node Operations" "Beta Version ${current_year} - Blooming Color, Inc" "bright_magenta" \
    "Operations Console • Main Menu" \
    "Manage Docker stack and NetBird lifecycle on this node."

  ui_panel_compact "Environment" "magenta" \
    "Repo root:     ${REPO_ROOT}" \
    "Compose file:  ${COMPOSE_FILE}" \
    "Project name:  ${COMPOSE_PROJECT_NAME}" \
    "Run as root:   $([[ \"${needs_root}\" == false ]] && echo yes || echo no)"
}

show_node_snapshot_lines() {
  local host os uptime_text loadavg mem docker_state netbird_state

  host="$(hostname)"
  os="$(grep -oP '^PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || echo 'Unknown OS')"
  uptime_text="$(uptime -p 2>/dev/null || true)"
  loadavg="$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || echo 'n/a')"
  mem="$(free -h 2>/dev/null | awk '/Mem:/ {print $3" / "$2}' || echo 'n/a')"

  if command_exists systemctl; then
    docker_state="$(systemctl is-active docker 2>/dev/null || echo 'unknown')"
    netbird_state="$(systemctl is-active netbird 2>/dev/null || echo 'unknown')"
  else
    docker_state="unknown"
    netbird_state="unknown"
  fi

  ui_panel_compact "Node Snapshot" "magenta" \
    "Node:            ${host}" \
    "OS:              ${os}" \
    "Uptime:          ${uptime_text:-unknown}" \
    "Load (1/5/15):   ${loadavg}" \
    "Memory:          ${mem}" \
    "Docker service:  ${docker_state}" \
    "NetBird service: ${netbird_state}"
}

pause() {
  if [[ "$INTERACTIVE" == true ]]; then
    # Ensure the prompt always starts on a fresh line after animated output.
    printf '\n'
    read -r -p "Press Enter to continue... " _
  fi
}

_op_timer_format_mmss() {
  local total_seconds="$1"
  local mins="$((total_seconds / 60))"
  local secs="$((total_seconds % 60))"
  printf '%02d:%02d' "$mins" "$secs"
}

detect_compose_cmd() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return
  fi

  if command_exists docker-compose; then
    echo "docker-compose"
    return
  fi

  echo ""
}

COMPOSE_CMD="$(detect_compose_cmd)"

run_compose() {
  if [[ -z "$COMPOSE_CMD" ]]; then
    echo "Error: Docker Compose command not found (docker compose or docker-compose)."
    return 1
  fi

  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "Error: Compose file not found at: $COMPOSE_FILE"
    return 1
  fi

  if [[ "$COMPOSE_CMD" == "docker compose" ]]; then
    run_with_privilege docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
  else
    run_with_privilege docker-compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
  fi
}

check_required_files() {
  if [[ ! -f "$BOOTSTRAP_SCRIPT" ]]; then
    fail "Bootstrap script not found at: $BOOTSTRAP_SCRIPT"
    exit 1
  fi
}

require_tool() {
  local tool="$1"
  local hint="$2"

  if ! command_exists "$tool"; then
    fail "'${tool}' is not installed. ${hint}"
    pause
    return 1
  fi
}

confirm() {
  local prompt="$1"
  local answer

  if [[ "$INTERACTIVE" != true ]]; then
    return 0
  fi

  read -r -p "$prompt [y/N]: " answer
  answer="$(trim "$answer")"
  [[ "$answer" =~ ^[Yy]$ ]]
}

prompt_yes_no_default() {
  local prompt="$1"
  local default_value="$2"
  local answer=""
  local default_hint="Y/n"

  if [[ "$default_value" == "no" ]]; then
    default_hint="y/N"
  fi

  read -r -p "$prompt [$default_hint]: " answer
  answer="$(trim "$answer")"

  if [[ -z "$answer" ]]; then
    printf '%s' "$default_value"
    return 0
  fi

  case "$answer" in
    y|Y|yes|YES) printf '%s' "yes" ;;
    n|N|no|NO) printf '%s' "no" ;;
    *) printf '%s' "$default_value" ;;
  esac
}

run_bootstrap_wizard() {
  local forced_repair_mode="${1:-no}"
  local edge_admin_user="netadmin"
  local netbird_setup_key=""
  local netbird_hostname=""
  local install_desktop="yes"
  local install_portainer="yes"
  local configure_ufw="yes"
  local enable_full_upgrade="yes"
  local repair_mode="no"

  netbird_hostname="$(hostname -s 2>/dev/null || echo edge-node)"

  ui_clear
  ui_panel_compact "Bootstrap Wizard" "magenta" \
    "This runs scripts/bootstrap-edge-node.sh with prompted values." \
    "NetBird setup key is recommended for immediate enrollment." \
    "One-off setup keys are only visible once when created."

  read -r -p "EDGE_ADMIN_USER [${edge_admin_user}]: " edge_admin_user
  edge_admin_user="$(trim "$edge_admin_user")"
  [[ -n "$edge_admin_user" ]] || edge_admin_user="netadmin"

  while true; do
    read -r -p "NETBIRD_SETUP_KEY (required for enrollment): " netbird_setup_key
    netbird_setup_key="$(trim "$netbird_setup_key")"
    if [[ -n "$netbird_setup_key" ]]; then
      break
    fi

    if confirm "Continue without NETBIRD_SETUP_KEY (NetBird enrollment will be skipped)?"; then
      break
    fi
    warn "Provide a setup key or explicitly confirm skipping enrollment."
  done

  read -r -p "NETBIRD_HOSTNAME [${netbird_hostname}]: " netbird_hostname
  netbird_hostname="$(trim "$netbird_hostname")"
  [[ -n "$netbird_hostname" ]] || netbird_hostname="$(hostname -s 2>/dev/null || echo edge-node)"

  install_desktop="$(prompt_yes_no_default "INSTALL_DESKTOP" "yes")"
  install_portainer="$(prompt_yes_no_default "INSTALL_PORTAINER" "yes")"
  configure_ufw="$(prompt_yes_no_default "CONFIGURE_UFW" "yes")"
  enable_full_upgrade="$(prompt_yes_no_default "ENABLE_FULL_UPGRADE" "yes")"

  if [[ "$forced_repair_mode" == "yes" ]]; then
    repair_mode="yes"
  else
    repair_mode="$(prompt_yes_no_default "REPAIR_MODE" "no")"
  fi

  ui_clear
  ui_panel "Bootstrap Execution Plan" "bright_magenta" \
    "Script:              ${BOOTSTRAP_SCRIPT}" \
    "EDGE_ADMIN_USER:     ${edge_admin_user}" \
    "NETBIRD_HOSTNAME:    ${netbird_hostname}" \
    "NETBIRD_SETUP_KEY:   $([[ -n "$netbird_setup_key" ]] && echo provided || echo not-provided)" \
    "INSTALL_DESKTOP:     ${install_desktop}" \
    "INSTALL_PORTAINER:   ${install_portainer}" \
    "CONFIGURE_UFW:       ${configure_ufw}" \
    "ENABLE_FULL_UPGRADE: ${enable_full_upgrade}" \
    "REPAIR_MODE:         ${repair_mode}"

  warn "FINAL WARNING: Running bootstrap will configure this node and make major system changes (packages, services, firewall, Docker, and NetBird state)."

  if ! confirm "Do you acknowledge and accept this warning?"; then
    warn "Bootstrap run cancelled: warning was not acknowledged."
    return 0
  fi

  ui_clear
  say "Running bootstrap script..."
  local bootstrap_rc=0
  local bootstrap_start_epoch=0
  local bootstrap_elapsed=0

  bootstrap_start_epoch="$(date +%s)"
  if ! run_with_privilege env \
    EDGE_ADMIN_USER="$edge_admin_user" \
    NETBIRD_SETUP_KEY="$netbird_setup_key" \
    NETBIRD_HOSTNAME="$netbird_hostname" \
    INSTALL_DESKTOP="$install_desktop" \
    INSTALL_PORTAINER="$install_portainer" \
    CONFIGURE_UFW="$configure_ufw" \
    ENABLE_FULL_UPGRADE="$enable_full_upgrade" \
    REPAIR_MODE="$repair_mode" \
    bash "$BOOTSTRAP_SCRIPT"; then
    bootstrap_rc=$?
  fi
  bootstrap_elapsed=$(( $(date +%s) - bootstrap_start_epoch ))

  if [[ "$bootstrap_rc" -eq 0 ]]; then
    ok "Bootstrap execution completed in $(_op_timer_format_mmss "$bootstrap_elapsed")."
    return 0
  fi

  fail "Bootstrap execution failed in $(_op_timer_format_mmss "$bootstrap_elapsed") (exit=${bootstrap_rc})."
  return "$bootstrap_rc"
}

docker_stack_status() {
  ui_clear
  say "Docker Stack Status"
  run_compose ps
  echo
  say "Portainer (all states)"
  run_with_privilege docker ps -a --filter name=portainer --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}

docker_stack_up() {
  say "Starting Docker stack..."
  run_compose up -d
  ok "Docker stack started."
}

docker_stack_down() {
  if ! confirm "Stop and remove the Docker stack?"; then
    warn "Cancelled."
    return
  fi

  say "Stopping Docker stack..."
  run_compose down
  ok "Docker stack stopped."
}

docker_stack_restart() {
  say "Restarting Docker stack..."
  run_compose down
  run_compose up -d
  ok "Docker stack restarted."
}

docker_stack_pull() {
  say "Pulling latest images..."
  run_compose pull
  ok "Image pull complete."
}

docker_stack_logs() {
  local service
  ui_clear
  read -r -p "Service name for logs (blank for all): " service
  service="$(trim "$service")"

  if [[ -n "$service" ]]; then
    run_compose logs --tail=150 "$service"
  else
    run_compose logs --tail=150
  fi
}

docker_menu() {
  while true; do
    [[ "${MAIN_MENU_REQUESTED}" == "1" ]] && return 0
    ui_clear
    ui_panel_compact "Docker Stack Operations" "magenta" \
      "Compose file: ${COMPOSE_FILE}" \
      "Project: ${COMPOSE_PROJECT_NAME}" \
      "Manage stack lifecycle and logs."
    show_node_snapshot_lines
    ui_panel "Actions" "bright_magenta" \
      "1) Status" \
      "2) Start Stack (up -d)" \
      "3) Stop Stack (down)" \
      "4) Restart Stack" \
      "5) Pull Latest Images" \
      "6) View Logs"
    ui_nav_panel_full

    local choice
    read -r -p "Select action > " choice
    case "$choice" in
      1) if ! docker_stack_status; then warn "Status check failed."; fi; pause ;;
      2) if ! docker_stack_up; then warn "Stack start failed."; fi; pause ;;
      3) if ! docker_stack_down; then warn "Stack stop failed."; fi; pause ;;
      4) if ! docker_stack_restart; then warn "Stack restart failed."; fi; pause ;;
      5) if ! docker_stack_pull; then warn "Image pull failed."; fi; pause ;;
      6) if ! docker_stack_logs; then warn "Log retrieval failed."; fi; pause ;;
      b|B) return ;;
      m|M|h|H) request_main_menu; return ;;
      q|Q) exit 0 ;;
      *) warn "Invalid choice"; pause ;;
    esac
  done
}

netbird_status() {
  ui_clear
  say "NetBird Status"
  if command_exists netbird; then
    run_with_privilege netbird status
  else
    warn "NetBird CLI not found."
  fi

  echo
  say "netbird service"
  if command_exists systemctl; then
    run_with_privilege systemctl status netbird --no-pager -l || true
  else
    warn "systemctl not available on this host."
  fi
}

netbird_up_with_key() {
  local setup_key hostname_value

  if ! command_exists netbird; then
    warn "NetBird CLI not found. Install NetBird before enrollment."
    return
  fi

  warn "NetBird setup keys are visible only once when created."
  read -r -p "Enter setup key: " setup_key
  read -r -p "Enter hostname (default: $(hostname -s)): " hostname_value

  setup_key="$(trim "$setup_key")"
  hostname_value="$(trim "$hostname_value")"

  if [[ -z "$setup_key" ]]; then
    warn "Setup key is required."
    return
  fi

  if [[ -z "$hostname_value" ]]; then
    hostname_value="$(hostname -s)"
  fi

  run_with_privilege netbird up --setup-key "$setup_key" --hostname "$hostname_value"
  ok "NetBird enrollment command sent."
}

netbird_disconnect() {
  if ! command_exists netbird; then
    warn "NetBird CLI not found."
    return
  fi

  if ! confirm "Disconnect this node from NetBird (netbird down)?"; then
    warn "Cancelled."
    return
  fi

  run_with_privilege netbird down
  ok "NetBird disconnect command sent."
}

netbird_service_restart() {
  if ! command_exists systemctl; then
    warn "systemctl not available on this host."
    return
  fi

  run_with_privilege systemctl restart netbird
  run_with_privilege systemctl is-active netbird
  ok "netbird service restarted."
}

netbird_menu() {
  while true; do
    [[ "${MAIN_MENU_REQUESTED}" == "1" ]] && return 0
    ui_clear
    ui_panel_compact "NetBird Operations" "magenta" \
      "Manage peer enrollment and runtime service state."
    show_node_snapshot_lines
    ui_panel "Actions" "bright_magenta" \
      "1) Status and Service Details" \
      "2) Enroll/Re-Enroll Peer (netbird up --setup-key)" \
      "3) Disconnect Peer (netbird down)" \
      "4) Restart netbird Service"
    ui_nav_panel_full

    local choice
    read -r -p "Select action > " choice
    case "$choice" in
      1) if ! netbird_status; then warn "NetBird status check failed."; fi; pause ;;
      2) if ! netbird_up_with_key; then warn "NetBird enroll command failed."; fi; pause ;;
      3) if ! netbird_disconnect; then warn "NetBird disconnect failed."; fi; pause ;;
      4) if ! netbird_service_restart; then warn "NetBird restart failed."; fi; pause ;;
      b|B) return ;;
      m|M|h|H) request_main_menu; return ;;
      q|Q) exit 0 ;;
      *) warn "Invalid choice"; pause ;;
    esac
  done
}

librenms_poller_status() {
  ui_clear
  say "LibreNMS Poller Agent Status"

  if ! command_exists docker; then
    warn "docker CLI not installed"
    return
  fi

  run_with_privilege docker ps -a --filter "name=${LIBRENMS_POLLER_CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}

librenms_poller_deploy() {
  if ! command_exists docker; then
    warn "docker CLI not installed"
    return
  fi

  local container_name image_name node_id tz
  local db_host db_port db_name db_user db_password
  local redis_host redis_port

  container_name="$LIBRENMS_POLLER_CONTAINER_NAME"
  image_name="$LIBRENMS_POLLER_IMAGE"
  node_id="$(hostname -s)-poller"
  tz="UTC"
  db_port="3306"
  redis_port="6379"

  ui_clear
  ui_panel_compact "LibreNMS Poller Deployment" "magenta" \
    "Deploys a distributed LibreNMS dispatcher/poller container." \
    "Use AWS Triad LibreNMS DB/Redis endpoints reachable over NetBird."

  read -r -p "Container name [${container_name}]: " container_name
  container_name="$(trim "$container_name")"
  [[ -n "$container_name" ]] || container_name="$LIBRENMS_POLLER_CONTAINER_NAME"

  read -r -p "Image [${image_name}]: " image_name
  image_name="$(trim "$image_name")"
  [[ -n "$image_name" ]] || image_name="$LIBRENMS_POLLER_IMAGE"

  read -r -p "DISPATCHER_NODE_ID [${node_id}]: " node_id
  node_id="$(trim "$node_id")"
  [[ -n "$node_id" ]] || node_id="$(hostname -s)-poller"

  read -r -p "TZ [${tz}]: " tz
  tz="$(trim "$tz")"
  [[ -n "$tz" ]] || tz="UTC"

  read -r -p "AWS Triad LibreNMS DB_HOST: " db_host
  db_host="$(trim "$db_host")"

  read -r -p "DB_PORT [${db_port}]: " db_port
  db_port="$(trim "$db_port")"
  [[ -n "$db_port" ]] || db_port="3306"

  read -r -p "DB_NAME: " db_name
  db_name="$(trim "$db_name")"

  read -r -p "DB_USER: " db_user
  db_user="$(trim "$db_user")"

  read -r -s -p "DB_PASSWORD: " db_password
  echo
  db_password="$(trim "$db_password")"

  read -r -p "AWS Triad Redis REDIS_HOST: " redis_host
  redis_host="$(trim "$redis_host")"

  read -r -p "REDIS_PORT [${redis_port}]: " redis_port
  redis_port="$(trim "$redis_port")"
  [[ -n "$redis_port" ]] || redis_port="6379"

  if [[ -z "$db_host" || -z "$db_name" || -z "$db_user" || -z "$db_password" || -z "$redis_host" ]]; then
    warn "DB_HOST, DB_NAME, DB_USER, DB_PASSWORD, and REDIS_HOST are required."
    return
  fi

  if run_with_privilege docker ps -a --format '{{.Names}}' | grep -Fxq "$container_name"; then
    if ! confirm "Container '${container_name}' exists. Recreate it with new settings?"; then
      warn "Cancelled."
      return
    fi
    run_with_privilege docker rm -f "$container_name" >/dev/null 2>&1 || true
  fi

  run_with_privilege mkdir -p /opt/librenms

  say "Deploying LibreNMS poller agent container..."
  run_with_privilege docker run -d \
    --name "$container_name" \
    --restart unless-stopped \
    -e TZ="$tz" \
    -e SIDECAR_DISPATCHER="1" \
    -e DISPATCHER_NODE_ID="$node_id" \
    -e DB_HOST="$db_host" \
    -e DB_PORT="$db_port" \
    -e DB_NAME="$db_name" \
    -e DB_USER="$db_user" \
    -e DB_PASSWORD="$db_password" \
    -e REDIS_HOST="$redis_host" \
    -e REDIS_PORT="$redis_port" \
    -v /opt/librenms:/data \
    "$image_name" >/dev/null

  LIBRENMS_POLLER_CONTAINER_NAME="$container_name"
  ok "LibreNMS poller agent deployed."
  run_with_privilege docker ps -a --filter "name=${LIBRENMS_POLLER_CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}

librenms_poller_logs() {
  if ! command_exists docker; then
    warn "docker CLI not installed"
    return
  fi

  run_with_privilege docker logs --tail 150 "$LIBRENMS_POLLER_CONTAINER_NAME"
}

librenms_poller_remove() {
  if ! command_exists docker; then
    warn "docker CLI not installed"
    return
  fi

  if ! run_with_privilege docker ps -a --format '{{.Names}}' | grep -Fxq "$LIBRENMS_POLLER_CONTAINER_NAME"; then
    warn "Poller container '${LIBRENMS_POLLER_CONTAINER_NAME}' not found."
    return
  fi

  if ! confirm "Remove LibreNMS poller container '${LIBRENMS_POLLER_CONTAINER_NAME}'?"; then
    warn "Cancelled."
    return
  fi

  run_with_privilege docker rm -f "$LIBRENMS_POLLER_CONTAINER_NAME"
  ok "LibreNMS poller container removed."
}

librenms_poller_menu() {
  while true; do
    [[ "${MAIN_MENU_REQUESTED}" == "1" ]] && return 0
    ui_clear
    ui_panel_compact "LibreNMS Poller Agent" "magenta" \
      "Manage distributed poller deployment for AWS Triad LibreNMS." \
      "Default container: ${LIBRENMS_POLLER_CONTAINER_NAME}"
    show_node_snapshot_lines
    ui_panel "Actions" "bright_magenta" \
      "1) Poller Container Status" \
      "2) Deploy/Re-Deploy Poller Agent" \
      "3) View Poller Logs" \
      "4) Remove Poller Agent"
    ui_nav_panel_full

    local choice
    read -r -p "Select action > " choice
    case "$choice" in
      1) if ! librenms_poller_status; then warn "Status check failed."; fi; pause ;;
      2) if ! librenms_poller_deploy; then warn "Poller deploy failed."; fi; pause ;;
      3) if ! librenms_poller_logs; then warn "Log retrieval failed."; fi; pause ;;
      4) if ! librenms_poller_remove; then warn "Poller removal failed."; fi; pause ;;
      b|B) return ;;
      m|M|h|H) request_main_menu; return ;;
      q|Q) exit 0 ;;
      *) warn "Invalid choice"; pause ;;
    esac
  done
}

quick_health_check() {
  ui_clear
  say "Service Health"
  if command_exists systemctl; then
    local svc state
    for svc in docker chrony snmpd xrdp netbird; do
      state="$(run_with_privilege systemctl is-active "$svc" 2>/dev/null || true)"
      state="${state:-unknown}"
      printf '%-12s %s\n' "${svc}:" "$state"
    done
  else
    warn "systemctl not available on this host."
  fi

  echo
  say "Docker Containers (running)"
  if command_exists docker; then
    run_with_privilege docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

    echo
    say "Portainer (all states)"
    run_with_privilege docker ps -a --filter name=portainer --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

    echo
    say "LibreNMS Poller Agent (all states)"
    run_with_privilege docker ps -a --filter "name=${LIBRENMS_POLLER_CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  else
    warn "docker CLI not installed"
  fi

  echo
  say "NetBird"
  if command_exists netbird; then
    run_with_privilege netbird status || true
  else
    warn "netbird CLI not installed"
  fi
}

network_interface_report_core() {
  if ! command_exists ip; then
    warn "ip command is required but was not found."
    return 1
  fi

  say "Network Interface Report"
  printf 'Host: %s\n' "$(hostname)"
  printf 'Generated: %s\n' "$(date -Is)"

  echo
  say "Interface State (brief)"
  ip -br link || true

  echo
  say "Traffic Counters (RX/TX)"
  ip -s -br link || true

  echo
  say "IPv4 Addresses"
  ip -br -4 addr || true

  echo
  say "IPv6 Addresses"
  ip -br -6 addr || true

  echo
  say "Routing Tables"
  printf 'IPv4 routes:\n'
  ip -4 route show table main || true
  echo
  printf 'IPv6 routes:\n'
  ip -6 route show table main || true

  echo
  say "Default Route"
  ip route show default || true
  ip -6 route show default || true

  echo
  say "DNS Resolver"
  if command_exists resolvectl; then
    resolvectl dns || true
    resolvectl domain || true
  else
    grep -E '^(nameserver|search)' /etc/resolv.conf 2>/dev/null || true
  fi

  echo
  say "NetworkManager Device State"
  if command_exists nmcli; then
    nmcli --terse --fields DEVICE,TYPE,STATE,CONNECTION device status || true
  else
    warn "nmcli not found (NetworkManager CLI not installed)."
  fi

  echo
  say "Per-Interface Details"
  local iface operstate mtu mac speed duplex carrier driver ipv4_addrs ipv6_addrs
  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue

    operstate="$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo unknown)"
    mtu="$(cat "/sys/class/net/${iface}/mtu" 2>/dev/null || echo unknown)"
    mac="$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo unknown)"
    carrier="$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo unknown)"
    speed="$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || echo unknown)"
    duplex="$(cat "/sys/class/net/${iface}/duplex" 2>/dev/null || echo unknown)"
    driver="$(basename "$(readlink -f "/sys/class/net/${iface}/device/driver" 2>/dev/null || echo unknown)")"

    ipv4_addrs="$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | paste -sd ',' -)"
    ipv6_addrs="$(ip -o -6 addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | paste -sd ',' -)"

    [[ -n "$ipv4_addrs" ]] || ipv4_addrs="none"
    [[ -n "$ipv6_addrs" ]] || ipv6_addrs="none"

    printf '\n[%s]\n' "$iface"
    printf '  state:   %s\n' "$operstate"
    printf '  carrier: %s\n' "$carrier"
    printf '  mtu:     %s\n' "$mtu"
    printf '  mac:     %s\n' "$mac"
    printf '  speed:   %s\n' "$speed"
    printf '  duplex:  %s\n' "$duplex"
    printf '  driver:  %s\n' "$driver"
    printf '  ipv4:    %s\n' "$ipv4_addrs"
    printf '  ipv6:    %s\n' "$ipv6_addrs"

    if command_exists ethtool && [[ "$iface" != "lo" ]]; then
      local ethtool_summary
      ethtool_summary="$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed|Duplex|Port|Link detected/ {printf "%s=%s ", $1, $2}')"
      if [[ -n "$ethtool_summary" ]]; then
        printf '  ethtool: %s\n' "$ethtool_summary"
      fi
    fi
  done < <(ls /sys/class/net 2>/dev/null | sort)
}

network_interface_report() {
  ui_clear
  network_interface_report_core
}

network_interface_report_save() {
  ui_clear

  local timestamp diagnostics_dir report_file report_rc=0
  timestamp="$(date +%Y%m%d-%H%M%S)"
  diagnostics_dir="$REPO_ROOT/diagnostics"
  report_file="$diagnostics_dir/network-interface-report-${timestamp}.log"

  if [[ -n "${SUDO_USER:-}" ]]; then
    runuser -u "$SUDO_USER" -- mkdir -p "$diagnostics_dir" 2>/dev/null || mkdir -p "$diagnostics_dir"
  else
    mkdir -p "$diagnostics_dir"
  fi

  if ! NO_COLOR=1 network_interface_report_core >"$report_file" 2>&1; then
    report_rc=$?
  fi

  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER":"$SUDO_USER" "$report_file" 2>/dev/null || true
  fi

  if [[ "$report_rc" -eq 0 ]]; then
    ok "Network interface report saved: $report_file"
    return 0
  fi

  warn "Network interface report encountered errors. Partial report saved: $report_file"
  return "$report_rc"
}

collect_desktop_chrome_diagnostics() {
  ui_clear

  local diag_user="${SUDO_USER:-$USER}"
  local timestamp diagnostics_dir diagnostics_file
  timestamp="$(date +%Y%m%d-%H%M%S)"
  diagnostics_dir="$REPO_ROOT/diagnostics"
  diagnostics_file="$diagnostics_dir/desktop-chrome-diagnostics-${timestamp}.log"

  if [[ -n "${SUDO_USER:-}" ]]; then
    runuser -u "$SUDO_USER" -- mkdir -p "$diagnostics_dir" 2>/dev/null || mkdir -p "$diagnostics_dir"
  else
    mkdir -p "$diagnostics_dir"
  fi

  : > "$diagnostics_file"

  _diag_append_cmd() {
    local label="$1"
    local cmd="$2"
    {
      echo
      echo "### ${label}"
      echo "\$ ${cmd}"
      bash -lc "$cmd" 2>&1 || true
    } >> "$diagnostics_file"
  }

  _diag_append_user_cmd() {
    local label="$1"
    local cmd="$2"
    {
      echo
      echo "### ${label}"
      echo "\$ (as ${diag_user}) ${cmd}"
      if [[ "$USER" == "$diag_user" ]]; then
        bash -lc "$cmd" 2>&1 || true
      elif [[ "$needs_root" == true ]] && command_exists runuser; then
        runuser -u "$diag_user" -- bash -lc "$cmd" 2>&1 || true
      elif command_exists sudo; then
        sudo -u "$diag_user" bash -lc "$cmd" 2>&1 || true
      else
        bash -lc "$cmd" 2>&1 || true
      fi
    } >> "$diagnostics_file"
  }

  {
    echo "BloomingEdge Desktop/Chrome Diagnostics"
    echo "Generated: $(date -Is)"
    echo "Host: $(hostname)"
    echo "User context: $diag_user"
    echo "Repo root: $REPO_ROOT"
  } >> "$diagnostics_file"

  _diag_append_user_cmd "Desktop Defaults" "xdg-settings get default-web-browser; xdg-mime query default x-scheme-handler/http; xdg-mime query default text/html"
  _diag_append_user_cmd "XFCE/Exo Browser Launch" "exo-open --launch WebBrowser https://example.com"
  _diag_append_user_cmd "Chrome Direct Launch Test" "timeout 12s /usr/bin/google-chrome-stable --password-store=basic --enable-logging=stderr --v=1 about:blank"
  _diag_append_user_cmd "Chrome Profile Paths" "ls -la ~/.config/google-chrome; ls -la ~/.cache/google-chrome"
  _diag_append_user_cmd "Chrome Debug Logs" "tail -n 200 ~/.config/google-chrome/chrome_debug.log 2>/dev/null; tail -n 200 ~/.cache/google-chrome/chrome_debug.log 2>/dev/null"
  _diag_append_user_cmd "XFCE Browser Config Files" "sed -n '1,220p' ~/.config/xfce4/helpers.rc 2>/dev/null; sed -n '1,260p' ~/.config/xfce4/xfconf/xfce-perchannel-xml/exo.xml 2>/dev/null; sed -n '1,260p' ~/.config/mimeapps.list 2>/dev/null"
  _diag_append_user_cmd "Wallpaper/Display Config Files" "sed -n '1,260p' ~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml 2>/dev/null; sed -n '1,260p' ~/.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml 2>/dev/null"
  _diag_append_user_cmd "User Session Logs" "journalctl --user -b --no-pager | grep -Ei 'chrome|exo|xdg|browser|keyring|xfce4-display|xfdesktop' | tail -n 400; grep -Ei 'chrome|exo|xdg|browser|keyring|xfce4-display|xfdesktop' ~/.xsession-errors 2>/dev/null | tail -n 200"
  _diag_append_cmd "Chrome Binary Checks" "command -v google-chrome-stable; ls -l /usr/bin/google-chrome-stable; file /usr/bin/google-chrome-stable"
  _diag_append_cmd "Autostart Entries" "find /etc/xdg/autostart /etc/xdg/xdg-xubuntu/autostart -maxdepth 1 -type f 2>/dev/null | sort"
  _diag_append_cmd "Running Display Processes" "ps -ef | grep -E 'xfce4-display-settings|xfdesktop|xfce4-session' | grep -v grep"

  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER":"$SUDO_USER" "$diagnostics_file" 2>/dev/null || true
  fi

  ok "Desktop/Chrome diagnostics collected: $diagnostics_file"
}

main_menu() {
  check_required_files

  while true; do
    [[ "${MAIN_MENU_REQUESTED}" == "1" ]] && MAIN_MENU_REQUESTED=0
    ui_clear
    print_header
    show_node_snapshot_lines
    ui_panel "Main Actions" "bright_magenta" \
      "1) Run Bootstrap Wizard" \
      "2) Docker Stack Operations" \
      "3) NetBird Operations" \
      "4) LibreNMS Poller Agent" \
      "5) Quick Health Check" \
      "6) Run Bootstrap in Repair Mode" \
      "7) Collect Desktop/Chrome Diagnostics" \
      "8) Network Interface Report" \
      "9) Save Network Interface Report"
    ui_panel "Navigation" "bright_magenta" "q) Quit"

    local choice
    read -r -p "Select action > " choice
    case "$choice" in
      1) if ! run_bootstrap_wizard; then warn "Bootstrap wizard failed."; fi; pause ;;
      2) docker_menu ;;
      3) netbird_menu ;;
      4) librenms_poller_menu ;;
      5) if ! quick_health_check; then warn "Health check reported errors."; fi; pause ;;
      6) if ! run_bootstrap_wizard yes; then warn "Repair bootstrap wizard failed."; fi; pause ;;
      7) if ! collect_desktop_chrome_diagnostics; then warn "Diagnostics collection failed."; fi; pause ;;
      8) if ! network_interface_report; then warn "Network interface report failed."; fi; pause ;;
      9) if ! network_interface_report_save; then warn "Network report save failed."; fi; pause ;;
      q|Q) echo "Exiting edge-node-ops."; exit 0 ;;
      *) warn "Invalid choice"; pause ;;
    esac  done
}

run_cli_command() {
  local cmd="${1:-}"

  case "${cmd}" in
    menu)
      main_menu
      ;;
    health|quick-health)
      quick_health_check
      ;;
    network|net|network-report|net-report)
      network_interface_report
      ;;
    network-save|net-save|network-report-save|net-report-save)
      network_interface_report_save
      ;;
    diagnostics|desktop-diagnostics)
      collect_desktop_chrome_diagnostics
      ;;
    *)      fail "Unknown command: ${cmd}"
      echo "Usage:"
      echo "  bash scripts/edge-node-ops.sh                     # interactive menu"
      echo "  bash scripts/edge-node-ops.sh menu                # interactive menu"
      echo "  bash scripts/edge-node-ops.sh quick-health        # quick health check"
      echo "  bash scripts/edge-node-ops.sh network-report      # network interface report"
      echo "  bash scripts/edge-node-ops.sh network-report-save # save network report to diagnostics"
      echo "  bash scripts/edge-node-ops.sh diagnostics         # desktop/chrome diagnostics"
      return 1      ;;
  esac
}

if (( $# > 0 )); then
  check_required_files
  run_cli_command "$1"
else
  main_menu
fi
