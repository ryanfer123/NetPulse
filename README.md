<div align="center">

# NetPulse - A zero-dependency macOS CLI tool for campus WiFi

**NetPulse** automatically detects when your campus captive portal blocks your internet and logs you in — silently, in the background. Built specifically for ProntoNetworks portals (like VIT).

[Features](#features) • [Installation](#installation) • [Usage](#usage) • [Report Bug](https://github.com/ryanfer123/NetPulse/issues)

<br>

[![macOS](https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white)](#)
[![Bash](https://img.shields.io/badge/Shell_Script-121011?style=for-the-badge&logo=gnu-bash&logoColor=white)](#)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)

<br>
</div>

## Features

- **Auto-Login:** Detects captive portal blocks and logs in automatically every 60 seconds.
- **Live Dashboard:** Real-time monitoring of your connection, including SSID, signal strength (RSSI/SNR), and channel.
- **Speed & Data Tracking:** Built-in Cloudflare CDN speed tests and daily data usage tracking.
- **Secure Storage:** Credentials are saved in the macOS Keychain, never in plaintext.
- **Background Daemon:** Runs as a macOS LaunchAgent. Starts on boot and survives network changes.

---

## Installation

Clone the repository and run the setup script:

```bash
git clone https://github.com/ryanfer123/NetPulse.git
cd NetPulse
chmod +x wifi_autologin.sh
```

### Setup

1. **Store your credentials:**
   ```bash
   ./wifi_autologin.sh setup
   ```
   *Your username and password are encrypted and stored in your macOS Keychain.*

2. **Install the background service:**
   ```bash
   ./wifi_autologin.sh install
   ```

3. **(Optional) Add to your PATH:**
   ```bash
   mkdir -p ~/.local/bin
   ln -sf "$(pwd)/wifi_autologin.sh" ~/.local/bin/vitwifi
   ```

---

## Usage

Run `vitwifi` (or `./wifi_autologin.sh`) to open the interactive menu.

```text
  WiFi        T-VIT  ▂▄▆█  (-54 dBm)
  Internet    ● Online
  Data Today  ↓58.2 MB  ↑61.2 MB
  User        24BCE0605  ✓
  Daemon      ● Running

  1  Setup credentials
  2  Login now
  3  Full network status
  4  Speed test
  5  Data usage
  6  Live dashboard
  7  Install background service
  8  View logs
  9  Uninstall service

  q  Quit
```

### Direct Commands

You can bypass the menu by passing arguments directly:

- `vitwifi status` - View detailed network stats (PHY mode, TX rate, etc.)
- `vitwifi speedtest` - Run a download/upload speed test
- `vitwifi data` - Check your daily bandwidth usage
- `vitwifi dashboard` - Open the live auto-refreshing dashboard
- `vitwifi logs` - View the background service logs

---

## Configuration

By default, NetPulse targets the `T-VIT` network and the ProntoNetworks portal. If you need to adapt this for a different campus, open `wifi_autologin.sh` and edit the configuration block at the top:

```bash
TARGET_SSID="T-VIT"
PORTAL_URL="http://phc.prontonetworks.com/cgi-bin/authlogin"
CHECK_INTERVAL=60
```
