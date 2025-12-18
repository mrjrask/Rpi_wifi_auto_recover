#!/usr/bin/env bash
# WiFi Auto-Recover Watchdog for Raspberry Pi
# - Detects WLAN interface automatically
# - Verifies association + internet reachability
# - If offline, cycles WiFi every 60s until back online
# - Logs recovery events (start, duration, success) to ~/wifi_recovery.log
# - Logs runtime status to /var/log/wifi_auto_recover.log via systemd

set -euo pipefail

# --- Settings ---
PING_HOSTS=("1.1.1.1" "8.8.8.8")   # IPs to test internet reachability
PING_TIMEOUT=2                     # seconds per ping
CHECK_INTERVAL_OK=15               # seconds between healthy checks
RETRY_INTERVAL=60                  # seconds between recovery cycles
MAX_FAILS=1                        # trigger recovery after this many fails
ENABLE_DNS_CHECK=${ENABLE_DNS_CHECK:-1}  # set to 0 to skip DNS resolution check
STATUS_MODE=0
IFACE_ARG=""

resolve_log_home() {
  local candidate

  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    candidate="$(getent passwd "$SUDO_USER" | awk -F: 'NR==1 {print $6}')"
    if [[ -z "$candidate" || ! -d "$candidate" ]]; then
      if [[ -d /home/pi ]]; then
        candidate="/home/pi"
      else
        candidate="/root"
      fi
    fi
    echo "$candidate"
    return
  fi

  echo "${HOME:-/root}"
}

DEFAULT_LOG_HOME="$(resolve_log_home)"

if [[ -n "${WIFI_RECOVERY_LOG:-}" ]]; then
  HOME_LOG="${WIFI_RECOVERY_LOG/#~/$DEFAULT_LOG_HOME}"
else
  HOME_LOG="${DEFAULT_LOG_HOME}/wifi_recovery.log"
fi

LOCK_FILE="/var/lock/wifi_auto_recover.lock"
LOCK_FALLBACK="${HOME}/.wifi_auto_recover.lock"
LOCK_FD=200
LOCK_HELD=0
should_run=1

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)
        STATUS_MODE=1
        ;;
      -h|--help)
        cat <<EOF
Usage: $0 [--status] [interface]

Options:
  --status   Print last known connectivity status and exit.
  -h, --help Show this help message and exit.

Positional:
  interface  WiFi interface to monitor (defaults to auto-detected).
EOF
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
      *)
        if [[ -z "$IFACE_ARG" ]]; then
          IFACE_ARG="$1"
        else
          echo "Unexpected argument: $1" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  if [[ $# -gt 0 ]]; then
    if [[ -z "$IFACE_ARG" ]]; then
      IFACE_ARG="$1"
    else
      echo "Unexpected argument: $1" >&2
      exit 1
    fi
  fi
}

detect_iface() {
  if [[ -n "${WIFI_INTERFACE:-}" ]]; then
    echo "$WIFI_INTERFACE"
    return 0
  fi
  if [[ $# -gt 0 && -n "${1:-}" ]]; then
    echo "$1"
    return 0
  fi
  local first
  first="$(iw dev | awk '/Interface/ {print $2; exit}')"
  if [[ -z "$first" ]]; then
    return 1
  fi
  echo "$first"
}

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [wifi-auto-recover] $*"
  echo "$line" | tee -a /var/log/wifi_auto_recover.log "$HOME_LOG"
}

userlog() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wifi-recovery] $*" >> "$HOME_LOG"
}

NO_INTERFACE_EXIT=12

parse_args "$@"

if ! IFACE="$(detect_iface "$IFACE_ARG")"; then
  log "⚠️ No wireless interface found; exiting with status ${NO_INTERFACE_EXIT}."
  exit "$NO_INTERFACE_EXIT"
fi

if (( STATUS_MODE )); then
  status_mode
  exit 0
fi

on_signal() {
  local sig=$1
  should_run=0
  log "Received ${sig}; stopping monitoring loop."
}

cleanup() {
  if (( LOCK_HELD )); then
    flock -u "$LOCK_FD" || true
    rm -f "$LOCK_FILE" || true
    log "WiFi Auto-Recover stopped."
  fi
}

select_lock_file() {
  local dir
  dir="$(dirname "$LOCK_FILE")"
  if [[ ! -d "$dir" || ! -w "$dir" ]]; then
    LOCK_FILE="$LOCK_FALLBACK"
  fi
}

acquire_lock() {
  select_lock_file
  if ! eval "exec ${LOCK_FD}>\"$LOCK_FILE\""; then
    echo "Unable to open lock file: $LOCK_FILE" >&2
    exit 1
  fi
  if ! flock -n "$LOCK_FD"; then
    log "Another instance is already running (lock: $LOCK_FILE). Exiting."
    exit 0
  fi
  echo "$$" 1>&${LOCK_FD}
  LOCK_HELD=1
}

check_association() {
  iw dev "$IFACE" link | grep -q "Connected to"
}

check_default_route() {
  ip route show default dev "$IFACE" | grep -q .
}

ping_with_fallback() {
  local host=$1 output rc
  if output=$(ping -I "$IFACE" -c 1 -W "$PING_TIMEOUT" "$host" 2>&1); then
    PING_LOG_DETAIL="Ping via $IFACE to $host succeeded."
    return 0
  fi
  rc=$?
  if [[ "$output" == *"Operation not permitted"* || "$output" == *"Permission denied"* ]]; then
    if output=$(ping -c 1 -W "$PING_TIMEOUT" "$host" 2>&1); then
      PING_LOG_DETAIL="Ping fallback (no interface binding) to $host succeeded."
      return 0
    fi
  fi
  PING_LOG_DETAIL="$output"
  return "$rc"
}

check_ping_hosts() {
  PING_FAILURE_DETAIL=""
  for h in "${PING_HOSTS[@]}"; do
    if ping_with_fallback "$h"; then
      return 0
    fi
    PING_FAILURE_DETAIL="Ping failed to $h (${PING_LOG_DETAIL:-no details}); hosts tried: ${PING_HOSTS[*]}"
  done
  return 1
}

check_dns() {
  if getent hosts dns.google >/dev/null 2>&1; then
    return 0
  fi
  DNS_FAILURE_DETAIL="DNS resolution failed for dns.google"
  return 1
}

disable_powersave() {
  if iw dev "$IFACE" get power_save 2>/dev/null | grep -qi on; then
    iw dev "$IFACE" set power_save off || true
    log "Disabled WiFi power save on $IFACE"
  fi
}

cycle_wifi() {
  log "Cycling WiFi on $IFACE (down → up)"
  ip link set "$IFACE" down || true
  sleep 2
  ip link set "$IFACE" up || true
  if command -v wpa_cli >/dev/null 2>&1; then
    wpa_cli -i "$IFACE" reconfigure >/dev/null 2>&1 || true
  fi
}

report_status() {
  local ssid ipaddr link_info bssid signal freq tx_bitrate default_route_status dns_status
  default_route_status="$1"
  dns_status="$2"
  ssid="$(iwgetid -r 2>/dev/null || echo '?')"
  ipaddr="$(ip -4 addr show dev "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
  link_info="$(iw dev "$IFACE" link 2>/dev/null || true)"
  bssid="$(awk '/Connected to/ {print $3; exit}' <<<"$link_info")"
  signal="$(awk -F'signal: ' '/signal:/ {print $2; exit}' <<<"$link_info" | sed 's/ dBm//')"
  freq="$(awk '/freq:/ {print $2; exit}' <<<"$link_info")"
  tx_bitrate="$(awk -F'tx bitrate: ' '/tx bitrate:/ {print $2; exit}' <<<"$link_info")"

  bssid="${bssid:-none}"
  signal="${signal:-unknown}"
  freq="${freq:-unknown}"
  tx_bitrate="${tx_bitrate:-unknown}"
  log "Status: SSID=${ssid}, BSSID=${bssid}, Signal=${signal} dBm, Freq=${freq} MHz, TX=${tx_bitrate}, IP=${ipaddr:-none}, DefaultRoute=${default_route_status}, DNS=${dns_status}"
}

parse_timestamp() {
  local line_ts
  line_ts="${1:0:19}"
  date -d "$line_ts" +%s 2>/dev/null || echo ""
}

latest_log_line() {
  local regex="$1" latest_line="" latest_epoch=0 log_file line epoch
  for log_file in "$HOME_LOG" /var/log/wifi_auto_recover.log; do
    [[ -f "$log_file" ]] || continue
    line=$(grep -Eh "$regex" "$log_file" 2>/dev/null | tail -n 1 || true)
    [[ -z "$line" ]] && continue
    epoch=$(parse_timestamp "$line")
    [[ -z "$epoch" ]] && continue
    if (( epoch > latest_epoch )); then
      latest_epoch=$epoch
      latest_line="$line"
    fi
  done
  printf '%s' "$latest_line"
}

extract_log_metadata() {
  LOG_STATE=""
  LOG_SSID=""
  LOG_IP=""
  LOG_RECOVERY_DURATION=""

  local state_line status_line recovery_line
  state_line=$(latest_log_line "Connectivity state=")
  if [[ -n "$state_line" ]]; then
    LOG_STATE="$(sed -n 's/.*state=\([^ ]*\).*/\1/p' <<<"$state_line")"
  fi

  status_line=$(latest_log_line "Status: SSID=")
  if [[ -n "$status_line" ]]; then
    LOG_SSID="$(sed -n 's/.*SSID=\([^,]*\),.*/\1/p' <<<"$status_line")"
    LOG_IP="$(sed -n 's/.*IP=\([^,]*\),.*/\1/p' <<<"$status_line")"
  fi

  recovery_line=$(latest_log_line "Recovered connection|Connectivity restored after")
  if [[ -n "$recovery_line" ]]; then
    LOG_RECOVERY_DURATION="$(sed -n 's/.*after \([0-9]\+\)s.*/\1/p' <<<"$recovery_line")"
  fi
}

run_one_shot_check() {
  local state="ok" detail="Connectivity verified." default_route_ok=0 dns_status="disabled"

  if ! check_association; then
    state="no_wifi"
    detail="WiFi not associated on $IFACE (iw dev link)."
  fi

  if [[ "$state" == "ok" ]]; then
    if check_default_route; then
      default_route_ok=1
    else
      state="no_internet"
      detail="No default route via $IFACE."
    fi
  fi

  if [[ "$state" == "ok" ]] && ! check_ping_hosts; then
    state="no_internet"
    detail="${PING_FAILURE_DETAIL:-Ping check failed.}"
  fi

  if [[ "$ENABLE_DNS_CHECK" -eq 1 ]]; then
    dns_status="no"
    if check_dns; then
      dns_status="yes"
    fi
    if [[ "$state" == "ok" && "$dns_status" != "yes" ]]; then
      state="no_internet"
      detail="${DNS_FAILURE_DETAIL:-DNS check failed.}"
    fi
  fi

  local ssid ipaddr
  ssid="$(iwgetid -r 2>/dev/null || echo '?')"
  ipaddr="$(ip -4 addr show dev "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"

  ONE_SHOT_STATE="$state"
  ONE_SHOT_SSID="${ssid:-unknown}"
  ONE_SHOT_IP="${ipaddr:-none}"
  ONE_SHOT_DETAIL="$detail"
  ONE_SHOT_DNS="$dns_status"
}

status_mode() {
  extract_log_metadata
  run_one_shot_check

  local state_source="one-shot check" ssid ipaddr state
  state="$ONE_SHOT_STATE"
  ssid="$ONE_SHOT_SSID"
  ipaddr="$ONE_SHOT_IP"

  if [[ -z "$state" && -n "$LOG_STATE" ]]; then
    state_source="logs"
    state="$LOG_STATE"
  elif [[ -z "$state" ]]; then
    state_source="unknown"
    state="unknown"
  fi

  if [[ -z "$ssid" && -n "$LOG_SSID" ]]; then
    ssid="$LOG_SSID"
  fi

  if [[ -z "$ipaddr" && -n "$LOG_IP" ]]; then
    ipaddr="$LOG_IP"
  fi

  echo "WiFi Auto-Recover status for interface: $IFACE"
  echo "State: ${state:-unknown} (${state_source})"
  echo "SSID: ${ssid:-unknown}"
  echo "IP: ${ipaddr:-unknown}"
  if [[ -n "$LOG_RECOVERY_DURATION" ]]; then
    echo "Last recovery duration: ${LOG_RECOVERY_DURATION}s"
  else
    echo "Last recovery duration: unknown (no recovery logged)"
  fi
  if [[ -n "$ONE_SHOT_DETAIL" ]]; then
    echo "Detail: $ONE_SHOT_DETAIL"
  elif [[ -n "$LOG_STATE" ]]; then
    echo "Detail: last logged state=$LOG_STATE"
  fi
}

main() {
  acquire_lock
  log "Starting WiFi Auto-Recover on interface: $IFACE"
  disable_powersave
  local initial_dns_status="disabled" initial_route_status="no"
  if check_default_route; then
    initial_route_status="yes"
  fi
  if [[ "$ENABLE_DNS_CHECK" -eq 1 ]]; then
    if check_dns; then
      initial_dns_status="yes"
    else
      initial_dns_status="no"
    fi
  fi
  report_status "$initial_route_status" "$initial_dns_status"

  local fails=0
  local recovery_start=0
  local last_state="ok"
  local state="ok"
  local detail=""

  while (( should_run )); do
    local default_route_ok=0
    local default_route_status="no"
    local dns_status="disabled"
    state="ok"
    detail="Connectivity verified."

    if ! check_association; then
      state="no_wifi"
      detail="WiFi not associated on $IFACE (iw dev link)."
    fi

    if check_default_route; then
      default_route_ok=1
      default_route_status="yes"
    fi

    if [[ "$state" == "ok" && $default_route_ok -eq 0 ]]; then
      state="no_internet"
      detail="No default route via $IFACE."
    elif [[ "$state" == "ok" ]] && ! check_ping_hosts; then
      state="no_internet"
      detail="${PING_FAILURE_DETAIL:-Ping check failed.}"
    fi

    if [[ "$ENABLE_DNS_CHECK" -eq 1 ]]; then
      dns_status="no"
      if check_dns; then
        dns_status="yes"
      fi
      if [[ "$state" == "ok" && "$dns_status" != "yes" ]]; then
        state="no_internet"
        detail="${DNS_FAILURE_DETAIL:-DNS check failed.}"
      fi
    else
      dns_status="disabled"
    fi

    if [[ "$state" == "ok" ]]; then
      if (( recovery_start > 0 )); then
        local recovery_end
        recovery_end=$(date +%s)
        local duration=$((recovery_end - recovery_start))
        userlog "Recovered connection on $IFACE after ${duration}s."
        log "✅ Connectivity restored after ${duration}s."
        report_status "$default_route_status" "$dns_status"
        recovery_start=0
      fi
      fails=0
      last_state="ok"
      sleep "$CHECK_INTERVAL_OK" || true
    else
      if [[ "$state" == "$last_state" ]]; then
        ((fails++))
      else
        fails=1
      fi
      log "Connectivity state=${state} (${fails}/${MAX_FAILS}): ${detail}"
      report_status "$default_route_status" "$dns_status"

      if (( fails >= MAX_FAILS )); then
        if (( recovery_start == 0 )); then
          recovery_start=$(date +%s)
          userlog "Lost connection on $IFACE — starting recovery attempts."
        fi
        cycle_wifi
        sleep "$RETRY_INTERVAL" || true
      else
        sleep 5 || true
      fi
      last_state="$state"
    fi
  done
}

trap 'on_signal SIGINT' INT
trap 'on_signal SIGTERM' TERM
trap cleanup EXIT

main
