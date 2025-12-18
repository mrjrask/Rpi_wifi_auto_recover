# WiFi Auto-Recover Watchdog for Raspberry Pi

A lightweight systemd-based watchdog that automatically detects and repairs Wi-Fi disconnections on a Raspberry Pi.
Ideal for devices placed at the **edge of a Wi-Fi signal**, where the connection may drop and fail to recover on its own.

---

## 🧠 Overview

This script continuously monitors your Raspberry Pi’s Wi-Fi connection.
If the connection to your router or the internet is lost, it:

1. Detects the loss of network association or connectivity.
2. Logs the event (with timestamps) to a file in your home directory.
3. Disables and re-enables Wi-Fi every 60 seconds until the connection is restored.
4. Records how long recovery took.
5. Disables Wi-Fi power-saving mode to prevent flakiness on weak signals.
6. Keeps detailed system and user logs for diagnostics.

---

## ⚙️ Features

- ✅ Automatic detection of Wi-Fi loss (both association and internet reachability)
- 🔁 Auto-reconnect logic (down → up cycle every 60 s)
- 🕒 Logs how long recovery takes
- 🧾 Two log locations for different purposes:
  - `/var/log/wifi_auto_recover.log` – detailed system logs
  - `~/wifi_recovery.log` – concise summary of when recovery was needed and how long it took
- 🚫 Power-saving mode disabled at startup to improve reliability
- 🧩 Runs automatically at boot via systemd

---

## 📂 File Locations

| Purpose | File Path |
|----------|------------|
| Main Script | `/usr/local/bin/wifi_auto_recover.sh` |
| User Event Log | `~/wifi_recovery.log` |
| System Log | `/var/log/wifi_auto_recover.log` |
| Systemd Unit | `/etc/systemd/system/wifi-auto-recover.service` |

---

## 🛠️ Installation

### Quick install or update (recommended)
Run the installer as root (or via `sudo`). It will install/update the script **and** refresh the systemd service file automatically.

```bash
sudo ./install.sh           # fresh install
sudo ./install.sh --update  # update existing install and restart the service
```

By default the installer also installs dependencies (`iw` and `wireless-tools`). Add `--skip-deps` to skip that step if you manage packages yourself.

### Manual installation (if you prefer)
```bash
sudo apt-get update
sudo apt-get install -y iw wireless-tools
sudo install -Dm755 wifi_auto_recover.sh /usr/local/bin/wifi_auto_recover.sh
sudo install -Dm644 systemd/wifi-auto-recover.service /etc/systemd/system/wifi-auto-recover.service
sudo systemctl daemon-reload
sudo systemctl enable --now wifi-auto-recover.service
```

### Check connectivity status on demand
You can run the script directly with `--status` to query the last known state and current connectivity in one shot:
```bash
sudo /usr/local/bin/wifi_auto_recover.sh --status
```
The status output includes the current SSID, IP address, and the last recorded recovery duration, if available.

---

## ✅ Verifying operation
- Check the service status:
  ```bash
  systemctl status wifi-auto-recover.service
  ```
- Review the detailed log file:
  ```bash
  sudo tail -f /var/log/wifi_auto_recover.log
  ```
- Review the summary log in your home directory:
  ```bash
  tail -f ~/wifi_recovery.log
  ```

---

## 🔧 Troubleshooting tips
- **`status=203/EXEC`** – The script is missing or not executable. Ensure it exists at `/usr/local/bin/wifi_auto_recover.sh` and has the `755` permissions.
- **`Assignment outside of section`** – The unit file is malformed. Reinstall `systemd/wifi-auto-recover.service` so that it begins with `[Unit]`, `[Service]`, and `[Install]` sections as provided here.
- To manually restart Wi-Fi while debugging:
  ```bash
  sudo systemctl restart wifi-auto-recover.service
  ```

If problems persist, inspect `journalctl -u wifi-auto-recover.service` for detailed error messages.

---

## 🔧 Configuration and tips

- **Select a specific interface:** Set `WIFI_INTERFACE=wlan1` (or pass `wlan1` as a positional argument) if your Pi has multiple Wi-Fi adapters.
- **Custom log location:** Point `WIFI_RECOVERY_LOG=/path/to/log` to change the per-user log destination.
- **DNS checking:** The script performs a DNS resolution check by default. Set `ENABLE_DNS_CHECK=0` to disable it if you are on a captive portal or a network with restricted DNS.
- **Permission-less pings:** If binding pings to an interface fails (e.g., due to permissions), the script automatically retries without binding to keep connectivity checks resilient.

> Tip: To avoid lock conflicts, ensure only one instance of the script runs at a time. The systemd unit already enforces this via a lock file.
