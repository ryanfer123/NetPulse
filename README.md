<h1 align="center">NetPulse</h1>
<h3 align="center">Fast, zero-dependency campus WiFi auto-login</h3>

<p align="center">
<pre align="center">
  _   _      _   ___      _          
 | \ | | ___| |_| _ \_  _| |___ ___  
 |  \| |/ -_)  _|  _/ || | (_-&lt;/ -_) 
 |_|\_|\___|\___|_|   \_,_|_/__/\___| 
</pre>
</p>
<p align="center">
  <b>NetPulse</b> is an easy to use & powerful network utility.<br>
  Automate captive portal logins, monitor your connection, and track your data usage right from the terminal.<br><br>
  <i><b>Note:</b> This tool is specifically built for VIT students to authenticate with the campus Pronto networks.</i>
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
- **Menu Bar Plugin**: Generate a macOS (SwiftBar) or Linux (Argos) plugin to view status, switch networks, and see data usage straight from the menu bar!
- **Captive Portal Logout**: Log out your current session so you can connect your phone or iPad to the campus WiFi without hitting the device limit.
- **Smart WiFi Scanner**: Scan nearby access points and get recommendations on the strongest network to connect to.
- **Data Export**: Export your historical data usage to a CSV file for Excel/Numbers.
- **Multi-Network Support**: Seamlessly switch between multiple campus WiFi networks (e.g. `T-VIT`, `M-VIT`) with the same credentials.
- **Fast Status Dashboard**: Real-time stats on your WiFi signal, SNR, channel, data usage, and latency.
- **Live Ping Monitor**: Trace packet loss and latency spikes in real-time.
- **Speed Test**: Built-in CLI speed test (using Cloudflare CDN) without requiring external packages.
- **Data Usage & History**: View daily download/upload totals and a 7-day historical sparkline graph directly from network interface counters.
- **Data Limits**: Get desktop notifications when you exceed a daily data limit.
- **Cross-Platform**: Zero external dependencies. Uses native system tools (`networksetup`, `ioreg`, `system_profiler` on macOS; `nmcli`, `ip` on Linux).

### Installation

The easiest way to install NetPulse is globally via NPM:

```bash
npm install -g netpulse-wifi
```

*(This allows you to run the `netpulse` command from anywhere in your terminal.)*

**Manual Installation (No Node/NPM required):**
If you don't have Node installed, you can simply clone and link the bash script:

```bash
git clone https://github.com/ryanfer123/NetPulse.git
cd NetPulse
chmod +x netpulse.sh
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
netpulse setup          # Store credentials & target networks
netpulse login          # One-shot portal login
netpulse logout         # Disconnect from captive portal
netpulse status         # Print detailed network status
netpulse scan           # Smart WiFi Scanner
netpulse speedtest      # Run a quick ping/download/upload test
netpulse ping           # Live connection monitor
netpulse data           # View data usage stats & history
netpulse export         # Export data usage to CSV
netpulse dashboard      # Open live-updating network monitor
netpulse install        # Install the auto-login background daemon
netpulse uninstall      # Remove the background daemon
netpulse logs           # View logs from the background daemon
netpulse menubar        # Print macOS/Linux menubar plugin code
netpulse faq            # Troubleshooting & common questions
```

### FAQ

**Q: I connect to different networks across campus.**  
**A:** During setup, enter all network names separated by commas: `T-VIT,M-VIT`. NetPulse will auto-login on any of them.

**Q: Where are my credentials stored?**  
**A:** On macOS, they are stored securely in the native **Keychain** (encrypted). On Linux, they are stored in `~/.netpulse-credentials` with `chmod 600` (only your user can read it).

**Q: Login shows "Failed" or "HTTP 000".**  
**A:** This usually means one of:
- You're not on the campus WiFi (e.g. mobile hotspot).
- The portal server `10.10.0.1` is unreachable.
- Your credentials are wrong.
- The campus network is genuinely down.

**Q: It says "Offline" but I have internet.**  
**A:** NetPulse checks Google, Apple, and Cloudflare to detect internet. Some networks or hotspots may block these. Try running `netpulse status` for a detailed check.

**Q: What is the daily data limit?**  
**A:** During setup, you can set a limit in MB (e.g. `500`). The daemon will send a desktop notification when you exceed it. Leave blank during setup to disable.
