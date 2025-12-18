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

HOME_LOG="${HOME}/wifi_recovery.log"

detect_iface() {
  if [[ $# -gt 0 && -n "${1:-}" ]]; then
    echo "$1"
    return
  fi
  local first
  first="$(iw dev | awk '/Interface/ {print $2; exit}')"
  if [[ -z "$first" ]]; then
    echo "No wireless interface found" >&2
    exit 1
  fi
  echo "$first"
}

IFACE="$(detect_iface "${1:-}")"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wifi-auto-recover] $*" | tee -a /var/log/wifi_auto_recover.log
}

userlog() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wifi-recovery] $*" >> "$HOME_LOG"
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
  local ssid ipaddr
  ssid="$(iwgetid -r 2>/dev/null || echo '?')"
  ipaddr="$(ip -4 addr show dev "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
  log "Status: SSID=${ssid}, IP=${ipaddr:-none}"
}

main() {
  log "Starting WiFi Auto-Recover on interface: $IFACE"
  disable_powersave
  report_status

  local fails=0
  local recovery_start=0
  local last_state="ok"
  local state="ok"
  local detail=""

  while true; do
    detail="Connectivity verified."
    if ! check_association; then
      state="no_wifi"
      detail="WiFi not associated on $IFACE (iw dev link)."
    elif ! check_default_route; then
      state="no_internet"
      detail="No default route via $IFACE."
    elif ! check_ping_hosts; then
      state="no_internet"
      detail="${PING_FAILURE_DETAIL:-Ping check failed.}"
    elif [[ "$ENABLE_DNS_CHECK" -eq 1 ]] && ! check_dns; then
      state="no_internet"
      detail="${DNS_FAILURE_DETAIL:-DNS check failed.}"
    else
      state="ok"
    fi

    if [[ "$state" == "ok" ]]; then
      if (( recovery_start > 0 )); then
        local recovery_end
        recovery_end=$(date +%s)
        local duration=$((recovery_end - recovery_start))
        userlog "Recovered connection on $IFACE after ${duration}s."
        log "✅ Connectivity restored after ${duration}s."
        report_status
        recovery_start=0
      fi
      fails=0
      last_state="ok"
      sleep "$CHECK_INTERVAL_OK"
    else
      if [[ "$state" == "$last_state" ]]; then
        ((fails++))
      else
        fails=1
      fi
      log "Connectivity state=${state} (${fails}/${MAX_FAILS}): ${detail}"
      report_status

      if (( fails >= MAX_FAILS )); then
        if (( recovery_start == 0 )); then
          recovery_start=$(date +%s)
          userlog "Lost connection on $IFACE — starting recovery attempts."
        fi
        cycle_wifi
        sleep "$RETRY_INTERVAL"
      else
        sleep 5
      fi
      last_state="$state"
    fi
  done
}

main
