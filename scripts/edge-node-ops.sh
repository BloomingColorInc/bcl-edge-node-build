#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/docker-compose.yml}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-edge-node}"
BOOTSTRAP_SCRIPT="${BOOTSTRAP_SCRIPT:-$REPO_ROOT/scripts/bootstrap-edge-node.sh}"
EDGE_NODE_OPS_DASHBOARD_CLEAR="${EDGE_NODE_OPS_DASHBOARD_CLEAR:-1}"
EDGE_NODE_OPS_PANEL_SPACING_LINES="${EDGE_NODE_OPS_PANEL_SPACING_LINES:-1}"
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
    read -r -p "Press Enter to continue..." _
  fi
}

_OP_TIMER_PID=""

_op_timer_format_mmss() {
  local total_seconds="$1"
  local mins="$((total_seconds / 60))"
  local secs="$((total_seconds % 60))"
  printf '%02d:%02d' "$mins" "$secs"
}

start_op_timer() {
  [[ -t 2 ]] || return 0
  _OP_TIMER_PID=""
  local op_start
  op_start="$(date +%s)"

  (
    local frames=( '-' '\\' '|' '/' )
    local idx=0
    while true; do
      local now elapsed elapsed_fmt spin
      now="$(date +%s)"
      elapsed=$(( now - op_start ))
      elapsed_fmt="$(_op_timer_format_mmss "$elapsed")"
      spin="${frames[$(( idx % 4 ))]}"
      printf '\r\033[2m⏳ [%s] Running bootstrap... elapsed %s\033[0m ' "$spin" "$elapsed_fmt" >&2
      idx=$(( idx + 1 ))
      sleep 1
    done
  ) &

  _OP_TIMER_PID=$!
}

stop_op_timer() {
  if [[ -n "${_OP_TIMER_PID:-}" ]]; then
    kill "$_OP_TIMER_PID" 2>/dev/null || true
    wait "$_OP_TIMER_PID" 2>/dev/null || true
    _OP_TIMER_PID=""
    printf '\r\033[K' >&2
  fi
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
  local edge_admin_user="netadmin"
  local netbird_setup_key=""
  local netbird_hostname=""
  local install_desktop="yes"
  local install_portainer="yes"
  local configure_ufw="yes"
  local enable_full_upgrade="yes"

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

  ui_clear
  ui_panel "Bootstrap Execution Plan" "bright_magenta" \
    "Script:              ${BOOTSTRAP_SCRIPT}" \
    "EDGE_ADMIN_USER:     ${edge_admin_user}" \
    "NETBIRD_HOSTNAME:    ${netbird_hostname}" \
    "NETBIRD_SETUP_KEY:   $([[ -n "$netbird_setup_key" ]] && echo provided || echo not-provided)" \
    "INSTALL_DESKTOP:     ${install_desktop}" \
    "INSTALL_PORTAINER:   ${install_portainer}" \
    "CONFIGURE_UFW:       ${configure_ufw}" \
    "ENABLE_FULL_UPGRADE: ${enable_full_upgrade}"

  warn "FINAL WARNING: Running bootstrap will configure this node and make major system changes (packages, services, firewall, Docker, and NetBird state)."

  if ! confirm "Do you acknowledge and accept this warning?"; then
    warn "Bootstrap run cancelled: warning was not acknowledged."
    return 0
  fi

  if ! confirm "Run bootstrap now with these settings?"; then
    warn "Bootstrap run cancelled."
    return 0
  fi

  ui_clear
  say "Running bootstrap script..."
  local bootstrap_rc=0
  local bootstrap_start_epoch=0
  local bootstrap_elapsed=0

  bootstrap_start_epoch="$(date +%s)"
  start_op_timer
  if ! run_with_privilege env \
    EDGE_ADMIN_USER="$edge_admin_user" \
    NETBIRD_SETUP_KEY="$netbird_setup_key" \
    NETBIRD_HOSTNAME="$netbird_hostname" \
    INSTALL_DESKTOP="$install_desktop" \
    INSTALL_PORTAINER="$install_portainer" \
    CONFIGURE_UFW="$configure_ufw" \
    ENABLE_FULL_UPGRADE="$enable_full_upgrade" \
    bash "$BOOTSTRAP_SCRIPT"; then
    bootstrap_rc=$?
  fi
  stop_op_timer
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
  say "Portainer Agent"
  run_with_privilege docker ps --filter name=portainer-agent
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

quick_health_check() {
  ui_clear
  say "Service Health"
  if command_exists systemctl; then
    run_with_privilege systemctl is-active docker || true
    run_with_privilege systemctl is-active chrony || true
    run_with_privilege systemctl is-active snmpd || true
    run_with_privilege systemctl is-active xrdp || true
    run_with_privilege systemctl is-active netbird || true
  else
    warn "systemctl not available on this host."
  fi

  echo
  say "Docker Containers"
  if command_exists docker; then
    run_with_privilege docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
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
      "4) Quick Health Check"

    ui_panel "Navigation" "bright_magenta" "q) Quit"

    local choice
    read -r -p "Select action > " choice
    case "$choice" in
      1) if ! run_bootstrap_wizard; then warn "Bootstrap wizard failed."; fi; pause ;;
      2) docker_menu ;;
      3) netbird_menu ;;
      4) if ! quick_health_check; then warn "Health check reported errors."; fi; pause ;;
      q|Q) echo "Exiting edge-node-ops."; exit 0 ;;
      *) warn "Invalid choice"; pause ;;
    esac
  done
}

main_menu
