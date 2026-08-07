# 🌐 NetPulse

> **Auto-login, monitor, and manage your campus WiFi — from the terminal.**

NetPulse is a zero-dependency shell CLI tool built for **VIT campus WiFi** (ProntoNetworks captive portal). It automatically detects when the captive portal blocks your internet and logs you in — silently, in the background, every 60 seconds.

![Shell Script](https://img.shields.io/badge/Shell-Bash-green?logo=gnu-bash&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-Supported-blue?logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-yellow)

---

## ✨ Features

| Feature | Description |
|---|---|
| 🔐 **Auto-Login** | Detects captive portal and logs in automatically |
| 📡 **Network Stats** | SSID, signal strength, RSSI, SNR, channel, PHY mode, MCS index |
| 🚀 **Speed Test** | Download/upload speed via Cloudflare CDN + latency & jitter |
| 📊 **Data Usage** | Tracks daily download/upload bytes |
| 🖥️ **Live Dashboard** | Real-time monitoring with auto-refresh |
| 🔑 **Keychain Storage** | Credentials stored in macOS Keychain (never plaintext) |
| 👻 **Background Daemon** | macOS LaunchAgent — starts on boot, survives reboots |
| 🔔 **Notifications** | macOS alerts on login success/failure |

---

## 🚀 Quick Start

### 1. Clone & Setup

```bash
git clone https://github.com/ryanfer123/NetPulse.git
cd NetPulse
chmod +x wifi_autologin.sh
```

### 2. Store Credentials

```bash
./wifi_autologin.sh setup
```

Your username and password are stored in **macOS Keychain** — encrypted, never in plaintext.

### 3. Install Background Service

```bash
./wifi_autologin.sh install
```

That's it! NetPulse will now:
- ✅ Check connectivity every **60 seconds**
- ✅ Auto-login when captive portal is detected
- ✅ Start automatically on boot
- ✅ Restart when network state changes

### 4. (Optional) Add to PATH

```bash
ln -sf "$(pwd)/wifi_autologin.sh" /usr/local/bin/vitwifi
# Or if /usr/local/bin needs sudo:
mkdir -p ~/.local/bin
ln -sf "$(pwd)/wifi_autologin.sh" ~/.local/bin/vitwifi
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

Now you can run `vitwifi` from anywhere.

---

## 📖 Usage

### Interactive Menu

```bash
vitwifi
```

Opens a looping interactive menu with quick network status and all options:

```
     ╦  ╦╦╔╦╗  ╦ ╦╦╔═╗╦
     ╚╗╔╝║ ║   ║║║║╠╣ ║
      ╚╝ ╩ ╩   ╚╩╝╩╚  ╩

  v2.2.0

  WiFi        T-VIT  ▂▄▆█  (-54 dBm)
  Internet    ● Online
  Data Today  ↓58.2 MB  ↑61.2 MB
  User        24BCE0605  ✓
  Daemon      ● Running

  1  Setup credentials
  2  Login now
  3  Full network status
  4  Speed test              ↓↑ Mbps
  5  Data usage              📊
  6  Live dashboard
  7  Install background service
  8  View logs
  9  Uninstall service

  q  Quit
```

### All Commands

| Command | Description |
|---|---|
| `vitwifi` | Interactive menu (loops until quit) |
| `vitwifi setup` | Store WiFi credentials in Keychain |
| `vitwifi login` | One-shot captive portal login |
| `vitwifi status` | Full network status with signal details |
| `vitwifi speedtest` | Download/upload speed test |
| `vitwifi data` | Data usage statistics |
| `vitwifi dashboard` | Live auto-refreshing dashboard |
| `vitwifi logs` | Tail the log file |
| `vitwifi install` | Install as macOS background service |
| `vitwifi uninstall` | Remove background service |
| `vitwifi help` | Show help |

---

## 📡 Network Status

```bash
vitwifi status
```

```
  📡 WIRELESS
  Network        T-VIT  ★
  Signal         ██████████░░░░░░░░░░ 52%
  RSSI           -54 dBm  │  Noise -92 dBm
  SNR            38 dB
  Channel        149 (5GHz, 40MHz)
  PHY Mode       802.11n
  TX Rate        130 Mbps
  MCS Index      13
  Security       None

  🌐 NETWORK
  Local IP       172.17.96.155
  Gateway        172.17.96.1
  DNS            1.1.1.3
  Internet       ● Online  (5.6 ms)

  📊 DATA (Today)
  ↓ 58.2 MB  ↑ 61.2 MB  Total 119.4 MB
```

## 🚀 Speed Test

```bash
vitwifi speedtest
```

```
  Ping           5.9 ms  (jitter: 0.7 ms)
  Download       15.1 Mbps  (23.8 MB in 13.2s)
  Upload         9.7 Mbps   (2.0 MB in 1.7s)

  ──────────────────────────────────────────
  Result  ↓ 15.1 Mbps  ↑ 9.7 Mbps  ◎ 5.9 ms
  Server: Cloudflare CDN
```

---

## 🔧 How It Works

```
┌─────────────────────────────────────────┐
│           macOS LaunchAgent             │
│      (runs on boot + network change)    │
└──────────────┬──────────────────────────┘
               │ every 60s
               ▼
       ┌───────────────┐
       │ Connected to   │──── No ──→ Skip
       │   T-VIT ?      │
       └───────┬───────┘
               │ Yes
               ▼
       ┌───────────────┐
       │ Has internet?  │──── Yes ──→ Skip
       └───────┬───────┘
               │ No
               ▼
       ┌───────────────┐
       │  POST login    │
       │  to portal     │
       └───────┬───────┘
               │
        ┌──────┴──────┐
        ▼             ▼
   ✅ Success    ❌ Retry
   (notify)      (backoff)
```

### Key Design Decisions

- **SSID Detection**: Uses `ioreg` (0.01s) for quick checks, `system_profiler` (cached) for detailed stats
- **Credential Storage**: macOS Keychain via `security` CLI — encrypted at rest
- **Captive Portal Detection**: Tests Apple's `captive.apple.com` endpoint + Google's `generate_204`
- **Failure Handling**: Exponential backoff on repeated failures (up to 5 min)
- **Data Usage**: Tracks via `netstat -I en0 -b` interface counters

---

## 📁 Files

| File | Purpose |
|---|---|
| `~/.vit-wifi-autologin.log` | Activity log |
| `~/.vit-wifi-data-usage.dat` | Data usage tracking |
| `~/Library/LaunchAgents/com.user.vit-wifi-autologin.plist` | Background service |
| macOS Keychain (`vit-wifi-autologin`) | Encrypted credentials |

---

## ⚙️ Configuration

Edit these variables at the top of `wifi_autologin.sh`:

```bash
TARGET_SSID="T-VIT"        # WiFi network name
CHECK_INTERVAL=60           # Seconds between checks
PORTAL_URL="http://phc.prontonetworks.com/cgi-bin/authlogin"
```

---

## 🤝 Adapting for Other Campuses

NetPulse works with any **ProntoNetworks** captive portal. To adapt for your campus:

1. Connect to your campus WiFi
2. Note the portal URL from the login page
3. Inspect the form fields (right-click → Inspect Element)
4. Update `PORTAL_URL`, `TARGET_SSID`, and field names in the script

---

## 📜 License

MIT License

---

<p align="center">
  <b>Built by Ryan ☕️</b>
</p>
