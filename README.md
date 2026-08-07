# NetPulse

NetPulse is a lightweight, zero-dependency command-line utility that automates logging into captive portal WiFi networks (like university or corporate campus networks) from your terminal. It detects when you're behind a portal, logs in automatically, and offers a sleek dashboard to monitor your connection, speed, and data usage.

Supports **macOS** and **Linux**.

## Features

- **Auto-Login Daemon**: Runs in the background (LaunchAgent on macOS, systemd on Linux) and automatically handles captive portals so you never have to see a login page.
- **Fast Status Dashboard**: Real-time stats on your WiFi signal, SNR, channel, data usage, and latency.
- **Speed Test**: Built-in CLI speed test (using Cloudflare CDN) without requiring external packages.
- **Data Usage Tracking**: View daily download/upload totals directly from the network interface counters.
- **Cross-Platform**: Zero external dependencies. Uses native system tools (`networksetup`, `ioreg`, `system_profiler` on macOS; `nmcli`, `ip` on Linux).

## Installation

Clone the repository and run the script:

```bash
git clone https://github.com/ryanfer123/NetPulse.git
cd NetPulse

# Make it executable
chmod +x netpulse.sh

# (Optional) Add an alias to your shell profile for easy access
echo 'alias netpulse="/path/to/NetPulse/netpulse.sh"' >> ~/.zshrc
source ~/.zshrc
```

## Setup

First, save your WiFi credentials securely.
On macOS, this uses the native Keychain. On Linux, it saves to a restricted file (`~/.netpulse-credentials` with 600 permissions).

```bash
netpulse setup
```
*It will ask for your username and password.*

## Usage

Simply run `netpulse` to open the interactive menu. Alternatively, use the direct commands below:

```bash
netpulse                # Open interactive menu
netpulse status         # Print detailed network status
netpulse dashboard      # Open live-updating network monitor
netpulse speedtest      # Run a quick ping/download/upload test
netpulse data           # View data usage statistics
netpulse install        # Install the auto-login background daemon
netpulse uninstall      # Remove the background daemon
netpulse logs           # View logs from the background daemon
```

## How the Background Daemon Works

When you run `netpulse install`, it creates a background service (`launchd` for macOS, `systemd` for Linux) that runs every 60 seconds. 

The daemon checks if you are connected to the target network. If you are, it makes a lightweight HTTP request to detect a captive portal block. If a block is detected, it securely fetches your credentials and submits the login payload automatically. It uses an exponential backoff if logins fail.

## License

MIT License
