<h1 align="center">NetPulse - Fast, zero-dependency campus WiFi auto-login</h1>

<p align="center">
  <b>NetPulse</b> is an easy to use & powerful network utility.<br>
  Automate captive portal logins, monitor your connection, and track your data usage right from the terminal.
</p>

<p align="center">
  <a href="#features"><b>Features</b></a> - 
  <a href="#installation"><b>Installation</b></a> - 
  <a href="https://github.com/ryanfer123/NetPulse/issues"><b>Report Bug</b></a> - 
  <a href="https://github.com/ryanfer123/NetPulse/issues"><b>Request a Feature</b></a>
</p>

<p align="center">
  <a href="https://github.com/ryanfer123/NetPulse">
    <img src="https://img.shields.io/badge/Get_it_on-GitHub-181717?style=for-the-badge&logo=github&logoColor=white" alt="Get it on GitHub" />
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS" />
  <img src="https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Linux" />
  <img src="https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white" alt="Bash" />
  <img src="https://img.shields.io/github/stars/ryanfer123/NetPulse?style=for-the-badge&color=ffb3b3" alt="Stars" />
  <img src="https://img.shields.io/github/issues/ryanfer123/NetPulse?style=for-the-badge&color=ffcccc" alt="Issues" />
</p>

<br>

### Features
- **Auto-Login Daemon**: Runs in the background (LaunchAgent on macOS, systemd on Linux). Automatically handles captive portals so you never see a login page.
- **Fast Status Dashboard**: Real-time stats on your WiFi signal, SNR, channel, data usage, and latency.
- **Speed Test**: Built-in CLI speed test (using Cloudflare CDN) without requiring external packages.
- **Data Usage Tracking**: View daily download/upload totals directly from the network interface counters.
- **Cross-Platform**: Zero external dependencies. Uses native system tools (`networksetup`, `ioreg`, `system_profiler` on macOS; `nmcli`, `ip` on Linux).

### Installation
Clone the repository and make the script executable:

```bash
git clone https://github.com/ryanfer123/NetPulse.git
cd NetPulse

# Make it executable
chmod +x netpulse.sh

# Install globally
mkdir -p ~/.local/bin
ln -sf $(pwd)/netpulse.sh ~/.local/bin/netpulse
```

### Setup
Save your WiFi credentials securely. On macOS, this uses the native Keychain. On Linux, it saves to a restricted file (`~/.netpulse-credentials` with 600 permissions).

```bash
netpulse setup
```

### Usage
Run `netpulse` to open the interactive menu, or use direct commands:

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
