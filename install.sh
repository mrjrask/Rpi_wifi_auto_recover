#!/usr/bin/env bash
# Installer/Updater for WiFi Auto-Recover Watchdog
set -euo pipefail

SCRIPT_SRC="wifi_auto_recover.sh"
SCRIPT_DEST="/usr/local/bin/wifi_auto_recover.sh"
SERVICE_SRC="systemd/wifi-auto-recover.service"
SERVICE_DEST="/etc/systemd/system/wifi-auto-recover.service"
SERVICE_NAME="wifi-auto-recover.service"
INSTALL_DEPS=1
MODE="install"

print_usage() {
  cat <<'USAGE'
Usage: sudo ./install.sh [options]

Options:
  --update       Run in update mode (reinstall files, restart service).
  --skip-deps    Skip installing package dependencies.
  -h, --help     Show this help message and exit.

This script installs or updates the WiFi Auto-Recover watchdog, including
its systemd service unit. It must be run with root privileges.
USAGE
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "This installer must be run as root (try with sudo)." >&2
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --update)
        MODE="update"
        ;;
      --skip-deps)
        INSTALL_DEPS=0
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        print_usage
        exit 1
        ;;
    esac
    shift
  done
}

install_dependencies() {
  if (( INSTALL_DEPS == 0 )); then
    return
  fi

  echo "Installing dependencies (iw, wireless-tools)..."
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get not found; skipping dependency installation. Install iw and wireless-tools manually." >&2
    return
  fi

  apt-get update
  apt-get install -y iw wireless-tools
}

install_script() {
  echo "Installing script to ${SCRIPT_DEST}..."
  install -Dm755 "${SCRIPT_SRC}" "${SCRIPT_DEST}"
}

install_service() {
  echo "Installing systemd service to ${SERVICE_DEST}..."
  install -Dm644 "${SERVICE_SRC}" "${SERVICE_DEST}"
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
}

restart_service_if_needed() {
  if [[ "${MODE}" == "update" ]]; then
    echo "Restarting ${SERVICE_NAME} after update..."
    systemctl restart "${SERVICE_NAME}"
  fi
}

main() {
  parse_args "$@"
  require_root

  install_dependencies
  install_script
  install_service
  restart_service_if_needed

  echo "${MODE^} complete."
  systemctl status "${SERVICE_NAME}" --no-pager --lines=3 || true
}

main "$@"
