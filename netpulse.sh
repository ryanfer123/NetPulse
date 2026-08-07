#!/bin/bash
# ============================================================================
#    _   _      _   ___      _          
#   | \ | | ___| |_| _ \_  _| |___ ___  
#   |  \| |/ -_)  _|  _/ || | (_-</ -_) 
#   |_|\_|\___|\__|_|   \_,_|_/__/\___| 
#
#  NetPulse Campus WiFi Auto-Login CLI
# ============================================================================

set -uo pipefail

# ── Configuration ───────────────────────────────────────────────────────────
PORTAL_URL="http://phc.prontonetworks.com/cgi-bin/authlogin"
REDIRECT_URI="http://captive.apple.com/hotspot-detect.html"
SERVICE_NAME="ProntoAuthentication"
KEYCHAIN_SERVICE="netpulse-autologin"
KEYCHAIN_ACCOUNT_USER="wifi-username"
KEYCHAIN_ACCOUNT_PASS="wifi-password"
KEYCHAIN_ACCOUNT_SSID="wifi-target-ssid"
CRED_FILE="$HOME/.netpulse-credentials"
CHECK_INTERVAL=60
LOG_FILE="$HOME/.netpulse-autologin.log"
DATA_FILE="$HOME/.netpulse-data-usage.dat"
LAUNCHAGENT_LABEL="com.user.netpulse"
LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCHAGENT_LABEL}.plist"
SYSTEMD_SERVICE="netpulse.service"
MAX_LOG_LINES=1000
VERSION="3.1.0"
SP_CACHE_FILE="/tmp/.netpulse-cache"

OS=$(uname -s)

# Load target SSID from credentials, fallback to T-VIT
TARGET_SSID=$(get_credential "$KEYCHAIN_ACCOUNT_SSID" 2>/dev/null || true)
[[ -z "$TARGET_SSID" ]] && TARGET_SSID="T-VIT"

# ── ANSI Colors ─────────────────────────────────────────────────────────────
RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[31m';  GRN='\033[32m';  YEL='\033[33m'; CYN='\033[36m'; WHT='\033[37m'
BRED='\033[91m'; BGRN='\033[92m'; BYEL='\033[93m'; BCYN='\033[96m'
BRAND="$BCYN"

# ── Helpers ─────────────────────────────────────────────────────────────────
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
short_time() { date '+%H:%M:%S'; }
repeat_char() { printf '%0.s'"$1" $(seq 1 "$2"); }

log()         { echo -e "[$(timestamp)] $1" >> "$LOG_FILE" 2>/dev/null; }
log_success() { log "✅ $1"; }
log_error()   { log "❌ $1"; }
log_warn()    { log "⚠️  $1"; }

rotate_log() {
    [[ -f "$LOG_FILE" ]] || return
    local lines; lines=$(wc -l < "$LOG_FILE" 2>/dev/null) || return
    (( lines > MAX_LOG_LINES )) && { tail -n $((MAX_LOG_LINES/2)) "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"; } 2>/dev/null
}

notify() {
    if [[ "$OS" == "Darwin" ]]; then
        osascript -e "display notification \"$1\" with title \"NetPulse\"" 2>/dev/null &
    else
        notify-send "NetPulse" "$1" 2>/dev/null &
    fi
}

# ── Human-readable byte formatting ─────────────────────────────────────────
format_bytes() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        printf "%.2f GB" "$(echo "scale=2; $bytes/1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.1f MB" "$(echo "scale=1; $bytes/1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.0f KB" "$(echo "scale=0; $bytes/1024" | bc)"
    else
        printf "%d B" "$bytes"
    fi
}

format_speed() {
    local bps="$1"
    if (( $(echo "$bps >= 1000000" | bc -l) )); then
        printf "%.1f Mbps" "$(echo "scale=1; $bps*8/1000000" | bc)"
    elif (( $(echo "$bps >= 1000" | bc -l) )); then
        printf "%.0f Kbps" "$(echo "scale=0; $bps*8/1000" | bc)"
    else
        printf "%.0f bps" "$(echo "scale=0; $bps*8" | bc)"
    fi
}

# ── Credentials ─────────────────────────────────────────────────────────────
store_credential() {
    if [[ "$OS" == "Darwin" ]]; then
        security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" 2>/dev/null || true
        security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" -w "$2"
    else
        touch "$CRED_FILE"
        chmod 600 "$CRED_FILE"
        if grep -q "^${1}=" "$CRED_FILE" 2>/dev/null; then
            sed -i "s/^${1}=.*/${1}=${2}/" "$CRED_FILE"
        else
            echo "${1}=${2}" >> "$CRED_FILE"
        fi
    fi
}

get_credential() {
    if [[ "$OS" == "Darwin" ]]; then
        security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" -w 2>/dev/null
    else
        [[ -f "$CRED_FILE" ]] && grep "^${1}=" "$CRED_FILE" 2>/dev/null | cut -d= -f2-
    fi
}

has_credentials() {
    get_credential "$KEYCHAIN_ACCOUNT_USER" >/dev/null 2>&1 && get_credential "$KEYCHAIN_ACCOUNT_PASS" >/dev/null 2>&1
}

# ── Fast WiFi Info (ioreg / nmcli) ──────────────────────────────────────────
get_ssid_fast() {
    if [[ "$OS" == "Darwin" ]]; then
        ioreg -l -n AirPortDriver 2>/dev/null | awk -F'"' '/IO80211SSID" =/{print $4; exit}'
    else
        nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '/^yes/{print $2; exit}'
    fi
}

get_wifi_interface() {
    if [[ "$OS" == "Darwin" ]]; then
        networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2}'
    else
        ip route 2>/dev/null | awk '/default/ {print $5; exit}'
    fi
}

get_local_ip() {
    local iface; iface=$(get_wifi_interface)
    if [[ "$OS" == "Darwin" ]]; then
        [[ -n "$iface" ]] && ipconfig getifaddr "$iface" 2>/dev/null
    else
        [[ -n "$iface" ]] && ip -4 addr show dev "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1
    fi
}

get_gateway() {
    if [[ "$OS" == "Darwin" ]]; then
        netstat -rn 2>/dev/null | awk '/default.*en/{print $2; exit}'
    else
        ip route 2>/dev/null | awk '/default/ {print $3; exit}'
    fi
}

get_dns_servers() {
    if [[ "$OS" == "Darwin" ]]; then
        scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | sort -u | head -3 | tr '\n' ' '
    else
        grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | sort -u | head -3 | tr '\n' ' '
    fi
}

get_mac_address() {
    local iface; iface=$(get_wifi_interface)
    [[ -n "$iface" ]] && ifconfig "$iface" 2>/dev/null | awk '/ether/{print $2}' || ip link show dev "$iface" 2>/dev/null | awk '/link\/ether/ {print $2}'
}

# ── Detailed WiFi Info (cached) ─────────────────────────────────────────────
_sp_data=""

_load_sp_data() {
    if [[ -f "$SP_CACHE_FILE" ]]; then
        local cache_time
        if [[ "$OS" == "Darwin" ]]; then
            cache_time=$(stat -f%m "$SP_CACHE_FILE" 2>/dev/null || echo 0)
        else
            cache_time=$(stat -c %Y "$SP_CACHE_FILE" 2>/dev/null || echo 0)
        fi
        local age=$(( $(date +%s) - cache_time ))
        if (( age < 30 )); then
            _sp_data=$(cat "$SP_CACHE_FILE" 2>/dev/null)
            return
        fi
    fi
    if [[ "$OS" == "Darwin" ]]; then
        _sp_data=$(system_profiler SPAirPortDataType 2>/dev/null)
    else
        _sp_data=$(nmcli -t -f all dev wifi 2>/dev/null)
    fi
    echo "$_sp_data" > "$SP_CACHE_FILE" 2>/dev/null
}

_refresh_sp_background() {
    if [[ "$OS" == "Darwin" ]]; then
        ( system_profiler SPAirPortDataType 2>/dev/null > "$SP_CACHE_FILE" ) &
    else
        ( nmcli -t -f all dev wifi 2>/dev/null > "$SP_CACHE_FILE" ) &
    fi
}

get_rssi() {
    if [[ "$OS" == "Darwin" ]]; then
        local sn; sn=$(echo "$_sp_data" | awk '/Current Network Information:/ { f=1; next } f && /Signal \/ Noise:/ { sub(/.*: /, ""); print; exit }')
        echo "$sn" | awk -F'/' '{gsub(/[^0-9-]/,"",$1); print $1}'
    else
        # nmcli gives signal 0-100. Rough RSSI formula: RSSI = (Signal / 2) - 100
        local sig=$(echo "$_sp_data" | grep -m1 "^\*" | cut -d: -f8)
        [[ -n "$sig" ]] && echo "$(( sig / 2 - 100 ))"
    fi
}

get_noise() {
    if [[ "$OS" == "Darwin" ]]; then
        local sn; sn=$(echo "$_sp_data" | awk '/Current Network Information:/ { f=1; next } f && /Signal \/ Noise:/ { sub(/.*: /, ""); print; exit }')
        echo "$sn" | awk -F'/' '{gsub(/[^0-9-]/,"",$2); print $2}'
    else
        echo "" # Hard to get purely from nmcli without root (iw)
    fi
}

get_channel() {
    if [[ "$OS" == "Darwin" ]]; then
        echo "$_sp_data" | awk '/Current Network Information:/ { f=1; next } f && /Channel:/ { sub(/.*: /, ""); print; exit }'
    else
        echo "$_sp_data" | grep -m1 "^\*" | cut -d: -f5
    fi
}

get_tx_rate() {
    if [[ "$OS" == "Darwin" ]]; then
        echo "$_sp_data" | awk '/Current Network Information:/ { f=1; next } f && /Transmit Rate:/ { sub(/.*: /, ""); print; exit }'
    else
        echo "$_sp_data" | grep -m1 "^\*" | cut -d: -f6 | tr -d ' '
    fi
}

get_security() {
    if [[ "$OS" == "Darwin" ]]; then
        echo "$_sp_data" | awk '/Current Network Information:/ { f=1; next } f && /Security:/ { sub(/.*: /, ""); print; exit }'
    else
        echo "$_sp_data" | grep -m1 "^\*" | cut -d: -f9
    fi
}

# ── Internet checks ────────────────────────────────────────────────────────
has_internet() {
    curl -s -m 3 "http://www.google.com/generate_204" -o /dev/null -w '%{http_code}' 2>/dev/null | grep -q "204"
}

is_captive_portal_active() {
    local body
    body=$(curl -s -m 3 "http://captive.apple.com/hotspot-detect.html" 2>/dev/null) || true
    echo "$body" | grep -qi "Success" && return 1
    return 0
}

get_ping_latency() {
    local lat
    if [[ "$OS" == "Darwin" ]]; then
        lat=$(ping -c 1 -t 2 8.8.8.8 2>/dev/null | awk -F'/' '/avg/{print $5}')
    else
        lat=$(ping -c 1 -W 2 8.8.8.8 2>/dev/null | awk -F'/' '/avg/{print $4}')
    fi
    [[ -n "$lat" ]] && printf "%.1f ms" "$lat" || echo "Timeout"
}

# ── Signal helpers ──────────────────────────────────────────────────────────
rssi_to_quality() {
    local r="$1"
    if [[ -z "$r" ]]; then echo 0; return; fi
    if (( r >= -30 )); then echo 100
    elif (( r >= -50 )); then echo $(( 100 - 2*(r*-1 - 30) ))
    elif (( r >= -70 )); then echo $(( 60 - 2*(r*-1 - 50) ))
    elif (( r >= -90 )); then echo $(( 20 - (r*-1 - 70) ))
    else echo 0; fi
}

rssi_to_bars() {
    local q; q=$(rssi_to_quality "$1")
    if   (( q >= 80 )); then echo -e "${BGRN}▂▄▆█${RST}"
    elif (( q >= 60 )); then echo -e "${GRN}▂▄▆${DIM}█${RST}"
    elif (( q >= 40 )); then echo -e "${YEL}▂▄${DIM}▆█${RST}"
    elif (( q >= 20 )); then echo -e "${RED}▂${DIM}▄▆█${RST}"
    else echo -e "${BRED}${DIM}▂▄▆█${RST}"; fi
}

signal_bar_graph() {
    local w=20 q; q=$(rssi_to_quality "$1")
    local f=$(( q*w/100 )) e=$(( w - q*w/100 ))
    local c="$BGRN"
    (( q < 80 )) && c="$GRN"; (( q < 60 )) && c="$YEL"
    (( q < 40 )) && c="$RED"; (( q < 20 )) && c="$BRED"
    printf "${c}"; (( f > 0 )) && printf '%0.s█' $(seq 1 "$f" 2>/dev/null)
    printf "${DIM}"; (( e > 0 )) && printf '%0.s░' $(seq 1 "$e" 2>/dev/null)
    printf "${RST} ${BOLD}%d%%${RST}" "$q"
}

# ── Data Usage ──────────────────────────────────────────────────────────────
get_interface_bytes() {
    local iface; iface=$(get_wifi_interface)
    if [[ "$OS" == "Darwin" ]]; then
        netstat -I "$iface" -b 2>/dev/null | awk 'NR==2{print $7, $10}'
    else
        awk -v iface="${iface}:" '$1 == iface {print $2, $10}' /proc/net/dev
    fi
}

init_data_tracking() {
    local now_bytes today
    now_bytes=$(get_interface_bytes)
    [[ -z "$now_bytes" ]] && now_bytes="0 0"
    today=$(date '+%Y-%m-%d')

    if [[ ! -f "$DATA_FILE" ]]; then
        echo "session_start_in=$(echo "$now_bytes" | awk '{print $1}')" > "$DATA_FILE"
        echo "session_start_out=$(echo "$now_bytes" | awk '{print $2}')" >> "$DATA_FILE"
        echo "session_start_time=$(date +%s)" >> "$DATA_FILE"
        echo "today=$today" >> "$DATA_FILE"
        echo "today_start_in=$(echo "$now_bytes" | awk '{print $1}')" >> "$DATA_FILE"
        echo "today_start_out=$(echo "$now_bytes" | awk '{print $2}')" >> "$DATA_FILE"
    else
        # Reset daily tracking if new day
        local saved_today
        saved_today=$(grep '^today=' "$DATA_FILE" 2>/dev/null | cut -d= -f2)
        if [[ "$saved_today" != "$today" ]]; then
            sed -i.bak "s/^today=.*/today=$today/" "$DATA_FILE"
            sed -i.bak "s/^today_start_in=.*/today_start_in=$(echo "$now_bytes" | awk '{print $1}')/" "$DATA_FILE"
            sed -i.bak "s/^today_start_out=.*/today_start_out=$(echo "$now_bytes" | awk '{print $2}')/" "$DATA_FILE"
            rm -f "${DATA_FILE}.bak" 2>/dev/null
        fi
    fi
}

get_data_usage() {
    [[ ! -f "$DATA_FILE" ]] && init_data_tracking

    local now_in now_out
    read -r now_in now_out <<< "$(get_interface_bytes)"
    [[ -z "$now_in" ]] && now_in=0; [[ -z "$now_out" ]] && now_out=0

    # Source the saved values
    local session_start_in session_start_out today_start_in today_start_out
    session_start_in=$(grep '^session_start_in=' "$DATA_FILE" | cut -d= -f2)
    session_start_out=$(grep '^session_start_out=' "$DATA_FILE" | cut -d= -f2)
    today_start_in=$(grep '^today_start_in=' "$DATA_FILE" | cut -d= -f2)
    today_start_out=$(grep '^today_start_out=' "$DATA_FILE" | cut -d= -f2)

    # Handle counter wraps (reboot resets netstat/proc counters)
    local sess_in=0 sess_out=0 day_in=0 day_out=0
    if (( now_in >= session_start_in )); then sess_in=$(( now_in - session_start_in )); else sess_in=$now_in; fi
    if (( now_out >= session_start_out )); then sess_out=$(( now_out - session_start_out )); else sess_out=$now_out; fi
    if (( now_in >= today_start_in )); then day_in=$(( now_in - today_start_in )); else day_in=$now_in; fi
    if (( now_out >= today_start_out )); then day_out=$(( now_out - today_start_out )); else day_out=$now_out; fi

    echo "$sess_in $sess_out $day_in $day_out $now_in $now_out"
}

show_data_usage() {
    init_data_tracking
    local usage; usage=$(get_data_usage)
    local sess_in sess_out day_in day_out total_in total_out
    read -r sess_in sess_out day_in day_out total_in total_out <<< "$usage"

    echo ""
    echo -e "  ${BOLD}${WHT}📊 DATA USAGE${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 50)${RST}"
    echo ""

    # Today
    local day_total=$(( day_in + day_out ))
    printf "  ${BOLD}Today${RST}\n"
    printf "    ${DIM}%-10s${RST} ${BGRN}↓${RST} ${WHT}%-12s${RST}  ${BCYN}↑${RST} ${WHT}%-12s${RST}  ${DIM}Total${RST} ${BOLD}%s${RST}\n" \
        "" "$(format_bytes "$day_in")" "$(format_bytes "$day_out")" "$(format_bytes "$day_total")"
    echo ""

    # Since boot (total interface counters)
    local boot_total=$(( total_in + total_out ))
    printf "  ${BOLD}Since Boot${RST}\n"
    printf "    ${DIM}%-10s${RST} ${BGRN}↓${RST} ${WHT}%-12s${RST}  ${BCYN}↑${RST} ${WHT}%-12s${RST}  ${DIM}Total${RST} ${BOLD}%s${RST}\n" \
        "" "$(format_bytes "$total_in")" "$(format_bytes "$total_out")" "$(format_bytes "$boot_total")"
    echo ""
}

# ── Speed Test ──────────────────────────────────────────────────────────────
cmd_speedtest() {
    echo ""
    echo -e "  ${BRAND}${BOLD}NetPulse · Speed Test${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 30)${RST}"
    echo ""

    if ! has_internet; then
        echo -e "  ${RED}✗ No internet — cannot run speed test.${RST}"
        echo ""
        return 1
    fi

    echo -e "  ${DIM}Testing latency...${RST}"
    local ping_arg="-t 2"
    [[ "$OS" == "Linux" ]] && ping_arg="-W 2"
    local ping1 ping2 ping3 avg_ping jitter
    ping1=$(ping -c 1 $ping_arg 8.8.8.8 2>/dev/null | awk -F'/' '/avg/{print $(NF-2)}') || ping1="0"
    ping2=$(ping -c 1 $ping_arg 8.8.8.8 2>/dev/null | awk -F'/' '/avg/{print $(NF-2)}') || ping2="0"
    ping3=$(ping -c 1 $ping_arg 8.8.8.8 2>/dev/null | awk -F'/' '/avg/{print $(NF-2)}') || ping3="0"

    avg_ping=$(echo "scale=1; ($ping1 + $ping2 + $ping3) / 3" | bc 2>/dev/null || echo "0")
    jitter=$(echo "scale=1; d1=$ping1-$avg_ping; d2=$ping2-$avg_ping; d3=$ping3-$avg_ping; if(d1<0) d1=-d1; if(d2<0) d2=-d2; if(d3<0) d3=-d3; if(d1>d2 && d1>d3) d1; else if(d2>d3) d2; else d3" | bc 2>/dev/null || echo "0")

    local ping_color="$BGRN"
    (( $(echo "$avg_ping > 20" | bc -l 2>/dev/null || echo 0) )) && ping_color="$GRN"
    (( $(echo "$avg_ping > 50" | bc -l 2>/dev/null || echo 0) )) && ping_color="$YEL"
    (( $(echo "$avg_ping > 100" | bc -l 2>/dev/null || echo 0) )) && ping_color="$RED"

    printf "\r  ${DIM}%-14s${RST} ${ping_color}${BOLD}%s ms${RST}  ${DIM}(jitter: %s ms)${RST}\n" "Ping" "$avg_ping" "$jitter"

    # ── Download ────────────────────────────────
    echo -ne "  ${DIM}Testing download...${RST}  "
    local dl_result dl_speed dl_time dl_size
    dl_result=$(curl -s -m 15 -o /dev/null -w '%{speed_download} %{time_total} %{size_download}' "https://speed.cloudflare.com/__down?bytes=25000000" 2>/dev/null)
    dl_speed=$(echo "$dl_result" | awk '{print $1}')
    dl_time=$(echo "$dl_result" | awk '{print $2}')
    dl_size=$(echo "$dl_result" | awk '{print $3}')

    local dl_formatted=$(format_speed "$dl_speed")
    local dl_color="$BGRN"
    local dl_mbps=$(echo "scale=1; $dl_speed * 8 / 1000000" | bc 2>/dev/null || echo "0")
    (( $(echo "$dl_mbps < 50" | bc -l 2>/dev/null || echo 0) )) && dl_color="$GRN"
    (( $(echo "$dl_mbps < 10" | bc -l 2>/dev/null || echo 0) )) && dl_color="$YEL"
    (( $(echo "$dl_mbps < 2"  | bc -l 2>/dev/null || echo 0) )) && dl_color="$RED"
    printf "\r  ${DIM}%-14s${RST} ${dl_color}${BOLD}%s${RST}  ${DIM}(%s in %ss)${RST}\n" "Download" "$dl_formatted" "$(format_bytes "${dl_size%%.*}")" "${dl_time}"

    # ── Upload ──────────────────────────────────
    echo -ne "  ${DIM}Testing upload...${RST}    "
    local ul_result ul_speed ul_time ul_size
    ul_result=$(dd if=/dev/urandom bs=1024 count=2048 2>/dev/null | curl -s -m 15 -X POST -o /dev/null -w '%{speed_upload} %{time_total} %{size_upload}' -H 'Content-Type: application/octet-stream' --data-binary @- "https://speed.cloudflare.com/__up" 2>/dev/null)
    ul_speed=$(echo "$ul_result" | awk '{print $1}')
    ul_time=$(echo "$ul_result" | awk '{print $2}')
    ul_size=$(echo "$ul_result" | awk '{print $3}')

    local ul_formatted=$(format_speed "$ul_speed")
    local ul_color="$BGRN"
    local ul_mbps=$(echo "scale=1; $ul_speed * 8 / 1000000" | bc 2>/dev/null || echo "0")
    (( $(echo "$ul_mbps < 20" | bc -l 2>/dev/null || echo 0) )) && ul_color="$GRN"
    (( $(echo "$ul_mbps < 5"  | bc -l 2>/dev/null || echo 0) )) && ul_color="$YEL"
    (( $(echo "$ul_mbps < 1"  | bc -l 2>/dev/null || echo 0) )) && ul_color="$RED"
    printf "\r  ${DIM}%-14s${RST} ${ul_color}${BOLD}%s${RST}  ${DIM}(%s in %ss)${RST}\n" "Upload" "$ul_formatted" "$(format_bytes "${ul_size%%.*}")" "${ul_time}"

    echo ""
    echo -e "  ${DIM}$(repeat_char '─' 50)${RST}"
    printf "  ${BOLD}Result${RST}  ↓ ${dl_color}${BOLD}%s${RST}  ↑ ${ul_color}${BOLD}%s${RST}  ◎ ${ping_color}${BOLD}%s ms${RST}\n" "$dl_formatted" "$ul_formatted" "$avg_ping"
    echo -e "  ${DIM}Server: Cloudflare CDN${RST}"
    echo ""
    log "Speed test: ↓$dl_formatted ↑$ul_formatted ping:${avg_ping}ms"
}

# ── Login ───────────────────────────────────────────────────────────────────
do_login() {
    local username password
    username=$(get_credential "$KEYCHAIN_ACCOUNT_USER") || true
    password=$(get_credential "$KEYCHAIN_ACCOUNT_PASS") || true
    [[ -z "$username" || -z "$password" ]] && return 2

    log "Attempting login as '$username'..."
    local response body http_code
    response=$(curl -s -m 10 -w '\n%{http_code}' \
        -X POST "${PORTAL_URL}?URI=${REDIRECT_URI}" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36' \
        -H "Referer: http://phc.prontonetworks.com/" \
        --data-urlencode "userId=${username}" \
        --data-urlencode "password=${password}" \
        --data-urlencode "serviceName=${SERVICE_NAME}" \
        --data-urlencode "Submit22=Login" \
        2>/dev/null) || true

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if echo "$body" | grep -qi "Access Granted\|successfully connected\|success"; then
        log_success "Login successful!"; notify "✅ WiFi connected"; return 0
    elif echo "$body" | grep -qi "already logged in\|already authenticated"; then
        log_success "Already logged in."; return 0
    elif echo "$body" | grep -qi "invalid\|incorrect\|wrong\|denied\|failed"; then
        log_error "Login failed — invalid credentials."; notify "❌ Login failed"; return 1
    else
        sleep 2
        has_internet && { log_success "Login OK (verified)."; notify "✅ WiFi connected"; return 0; }
        log_warn "Login unclear (HTTP $http_code)."; return 1
    fi
}

do_check_and_login() {
    rotate_log
    local ssid; ssid=$(get_ssid_fast)
    [[ -z "$ssid" ]] && return 0
    [[ "$ssid" != "$TARGET_SSID" ]] && return 0
    has_internet && return 0
    log "Captive portal detected on '$TARGET_SSID'."
    do_login
}

# ── Service Management ──────────────────────────────────────────────────────
is_daemon_running() {
    if [[ "$OS" == "Darwin" ]]; then
        [[ -f "$LAUNCHAGENT_PLIST" ]] && launchctl list 2>/dev/null | grep -q "$LAUNCHAGENT_LABEL"
    else
        systemctl --user is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null
    fi
}

cmd_install() {
    echo -e "\n  ${BRAND}${BOLD}NetPulse · Install Service${RST}\n  ${DIM}$(repeat_char '─' 30)${RST}\n"
    has_credentials || { echo -e "  ${RED}✗ Run: netpulse setup${RST}\n"; return 1; }
    local sp; sp="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    if [[ "$OS" == "Darwin" ]]; then
        mkdir -p "$HOME/Library/LaunchAgents"
        cat > "$LAUNCHAGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>${LAUNCHAGENT_LABEL}</string>
    <key>ProgramArguments</key><array><string>/bin/bash</string><string>${sp}</string><string>daemon</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>NetworkState</key><true/></dict>
    <key>StandardOutPath</key><string>${LOG_FILE}</string>
    <key>StandardErrorPath</key><string>${LOG_FILE}</string>
    <key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
PLIST
        launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true
        launchctl load -w "$LAUNCHAGENT_PLIST"
    else
        mkdir -p "$HOME/.config/systemd/user"
        local svc_file="$HOME/.config/systemd/user/${SYSTEMD_SERVICE}"
        cat > "$svc_file" <<EOF
[Unit]
Description=NetPulse Auto-Login Daemon
After=network.target

[Service]
ExecStart=/bin/bash ${sp} daemon
Restart=always
RestartSec=10
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now "$SYSTEMD_SERVICE" 2>/dev/null
    fi
    echo -e "  ${BGRN}${BOLD}✓ Installed & started${RST}  ${DIM}(checks every ${CHECK_INTERVAL}s, starts on boot)${RST}\n"
}

cmd_uninstall() {
    echo -e "\n  ${BRAND}${BOLD}NetPulse · Uninstall${RST}\n"
    if [[ "$OS" == "Darwin" ]]; then
        [[ -f "$LAUNCHAGENT_PLIST" ]] && { launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null; rm -f "$LAUNCHAGENT_PLIST"; echo -e "  ${BGRN}✓ Removed macOS LaunchAgent.${RST}"; } || echo -e "  ${DIM}Nothing installed.${RST}"
    else
        local svc_file="$HOME/.config/systemd/user/${SYSTEMD_SERVICE}"
        [[ -f "$svc_file" ]] && { systemctl --user disable --now "$SYSTEMD_SERVICE" 2>/dev/null; rm -f "$svc_file"; systemctl --user daemon-reload; echo -e "  ${BGRN}✓ Removed systemd service.${RST}"; } || echo -e "  ${DIM}Nothing installed.${RST}"
    fi
    echo ""
}

# ── Commands ────────────────────────────────────────────────────────────────
cmd_setup() {
    echo ""
    echo -e "  ${BRAND}${BOLD}NetPulse · Credential Setup${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 35)${RST}"
    echo ""
    has_credentials && {
        local eu; eu=$(get_credential "$KEYCHAIN_ACCOUNT_USER")
        echo -e "  ${YEL}⚠  Existing: ${BOLD}${eu}${RST} ${DIM}(will overwrite)${RST}"
        echo ""
    }
    if [[ "$OS" == "Darwin" ]]; then
        echo -e "  ${DIM}Stored securely in macOS Keychain.${RST}"
    else
        echo -e "  ${DIM}Stored securely in $CRED_FILE (chmod 600).${RST}"
    fi
    echo ""
    read -rp "$(echo -e "  ${BOLD}Username ${DIM}(e.g. 24BCE0605)${RST}${BOLD}: ")" wifi_user
    read -rsp "$(echo -e "  ${BOLD}Password${RST}${BOLD}: ")" wifi_pass; echo ""; echo ""
    read -rp "$(echo -e "  ${BOLD}Target SSID ${DIM}(default: T-VIT)${RST}${BOLD}: ")" wifi_ssid; echo ""
    [[ -z "$wifi_user" || -z "$wifi_pass" ]] && { echo -e "  ${RED}✗ Username and Password cannot be empty.${RST}"; return 1; }
    [[ -z "$wifi_ssid" ]] && wifi_ssid="T-VIT"
    
    store_credential "$KEYCHAIN_ACCOUNT_USER" "$wifi_user"
    store_credential "$KEYCHAIN_ACCOUNT_PASS" "$wifi_pass"
    store_credential "$KEYCHAIN_ACCOUNT_SSID" "$wifi_ssid"
    TARGET_SSID="$wifi_ssid"
    
    echo -e "  ${BGRN}${BOLD}✓ Credentials and SSID saved${RST}"; echo ""
}

cmd_login() {
    echo ""
    echo -e "  ${BRAND}${BOLD}NetPulse · Manual Login${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 30)${RST}"
    echo ""
    has_credentials || { echo -e "  ${RED}✗ Run: netpulse setup${RST}"; echo ""; return 1; }
    local ssid; ssid=$(get_ssid_fast)
    echo -e "  ${DIM}Network:${RST}  ${BOLD}${ssid:-Not connected}${RST}"
    [[ -z "$ssid" ]] && { echo -e "  ${RED}✗ Not connected to WiFi.${RST}"; echo ""; return 1; }
    [[ "$ssid" != "$TARGET_SSID" ]] && { echo -e "  ${YEL}⚠  Not on ${TARGET_SSID}.${RST}"; echo ""; return 0; }
    has_internet && { echo -e "  ${BGRN}✓ Already online!${RST}"; echo ""; return 0; }
    echo -e "  ${YEL}⟳ Logging in...${RST}"; echo ""
    do_login && echo -e "  ${BGRN}${BOLD}✓ Connected!${RST}" || echo -e "  ${RED}${BOLD}✗ Failed.${RST}"
    echo ""
}

cmd_status() {
    echo ""
    echo -e "  ${BRAND}${BOLD}NetPulse · Network Status${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 30)${RST}"
    echo ""

    echo -ne "  ${DIM}Loading network details...${RST}"
    _load_sp_data
    printf "\r%-40s\r" " "

    local ssid rssi noise channel tx_rate sec local_ip gateway dns mac

    ssid=$(get_ssid_fast); rssi=$(get_rssi); noise=$(get_noise)
    channel=$(get_channel); tx_rate=$(get_tx_rate); sec=$(get_security)
    local_ip=$(get_local_ip); gateway=$(get_gateway)
    dns=$(get_dns_servers); mac=$(get_mac_address)

    echo -e "  ${BOLD}${WHT}📡 WIRELESS${RST}"
    if [[ -n "$ssid" ]]; then
        local sc="$WHT"; [[ "$ssid" == "$TARGET_SSID" ]] && sc="$BGRN"
        printf "  ${DIM}%-14s${RST} ${sc}${BOLD}%s${RST}" "Network" "$ssid"
        [[ "$ssid" == "$TARGET_SSID" ]] && printf "  ${BGRN}★${RST}"; echo ""

        if [[ -n "$rssi" && "$rssi" =~ ^-?[0-9]+$ ]]; then
            printf "  ${DIM}%-14s${RST} " "Signal"; signal_bar_graph "$rssi"; echo ""
            printf "  ${DIM}%-14s${RST} ${WHT}%s dBm${RST}" "RSSI" "$rssi"
            [[ -n "$noise" && "$noise" =~ ^-?[0-9]+$ ]] && printf "  ${DIM}│${RST}  ${DIM}Noise${RST} ${WHT}%s dBm${RST}" "$noise"
            echo ""
            if [[ -n "$noise" && "$noise" =~ ^-?[0-9]+$ ]]; then
                local snr=$(( rssi - noise )); local snrc="$RED"
                (( snr>10 )) && snrc="$YEL"; (( snr>20 )) && snrc="$GRN"; (( snr>30 )) && snrc="$BGRN"
                printf "  ${DIM}%-14s${RST} ${snrc}%s dB${RST}\n" "SNR" "$snr"
            fi
        fi
        [[ -n "$channel" ]] && printf "  ${DIM}%-14s${RST} ${WHT}%s${RST}\n" "Channel" "$channel"
        [[ -n "$tx_rate" ]] && printf "  ${DIM}%-14s${RST} ${WHT}%s Mbps${RST}\n" "TX Rate" "$tx_rate"
        [[ -n "$sec" ]]     && printf "  ${DIM}%-14s${RST} ${WHT}%s${RST}\n" "Security" "$sec"
        [[ -n "$mac" ]]     && printf "  ${DIM}%-14s${RST} ${DIM}%s${RST}\n" "MAC" "$mac"
    else
        echo -e "  ${RED}${BOLD}  ✗ Not connected${RST}"
    fi

    echo ""
    echo -e "  ${BOLD}${WHT}🌐 NETWORK${RST}"
    [[ -n "$local_ip" ]] && printf "  ${DIM}%-14s${RST} ${WHT}%s${RST}\n" "Local IP" "$local_ip"
    [[ -n "$gateway" ]]  && printf "  ${DIM}%-14s${RST} ${WHT}%s${RST}\n" "Gateway" "$gateway"
    [[ -n "$dns" ]]      && printf "  ${DIM}%-14s${RST} ${WHT}%s${RST}\n" "DNS" "$dns"

    if has_internet; then
        local lat; lat=$(get_ping_latency)
        printf "  ${DIM}%-14s${RST} ${BGRN}${BOLD}● Online${RST}  ${DIM}(%s)${RST}\n" "Internet" "$lat"
    else
        printf "  ${DIM}%-14s${RST} ${BRED}${BOLD}● Offline${RST}\n" "Internet"
        is_captive_portal_active && printf "  ${DIM}%-14s${RST} ${YEL}${BOLD}⚠ Login needed${RST}\n" "Portal"
    fi

    # Data usage inline
    init_data_tracking
    local usage; usage=$(get_data_usage)
    local di do ti to; read -r di do ti to _ _ <<< "$usage"
    echo ""
    echo -e "  ${BOLD}${WHT}📊 DATA (Today)${RST}"
    printf "  ${DIM}%-14s${RST} ${BGRN}↓${RST} ${WHT}%s${RST}  ${BCYN}↑${RST} ${WHT}%s${RST}  ${DIM}Total${RST} ${BOLD}%s${RST}\n" \
        "" "$(format_bytes "$ti")" "$(format_bytes "$to")" "$(format_bytes $((ti+to)))"

    echo ""
    echo -e "  ${BOLD}${WHT}🔐 SERVICE${RST}"
    has_credentials && {
        local u; u=$(get_credential "$KEYCHAIN_ACCOUNT_USER")
        printf "  ${DIM}%-14s${RST} ${WHT}%s${RST}  ${BGRN}✓${RST}\n" "User" "$u"
    } || printf "  ${DIM}%-14s${RST} ${RED}Not set${RST}\n" "Credentials"

    if is_daemon_running; then
        printf "  ${DIM}%-14s${RST} ${BGRN}${BOLD}● Running${RST}  ${DIM}(every %ds)${RST}\n" "Daemon" "$CHECK_INTERVAL"
    elif [[ -f "$LAUNCHAGENT_PLIST" ]] || [[ -f "$HOME/.config/systemd/user/${SYSTEMD_SERVICE}" ]]; then
        printf "  ${DIM}%-14s${RST} ${YEL}● Stopped${RST}\n" "Daemon"
    else
        printf "  ${DIM}%-14s${RST} ${DIM}○ Not installed${RST}\n" "Daemon"
    fi
    echo ""
}

cmd_dashboard() {
    tput civis 2>/dev/null
    trap 'tput cnorm 2>/dev/null; echo ""; exit 0' INT TERM EXIT

    local login_count=0 last_login="Never"
    local uptime_start; uptime_start=$(date +%s)
    init_data_tracking

    while true; do
        clear
        _refresh_sp_background  # refresh in background for NEXT cycle

        # Use cached data (from previous cycle or file cache)
        [[ -f "$SP_CACHE_FILE" ]] && _sp_data=$(cat "$SP_CACHE_FILE" 2>/dev/null)

        echo -e "\n${BRAND}${BOLD}"
        cat << 'H'
   _   _      _   ___      _          
  | \ | | ___| |_| _ \_  _| |___ ___  
  |  \| |/ -_)  _|  _/ || | (_-</ -_) 
  |_|\_|\___|\__|_|   \_,_|_/__/\___| 
H
        echo -e "${RST}"
        echo -e "  ${DIM}Live Dashboard${RST}  ${DIM}v${VERSION}${RST}  ${DIM}│${RST}  ${DIM}$(short_time)${RST}"
        echo -e "  ${DIM}$(repeat_char '─' 50)${RST}\n"

        local ssid rssi noise channel tx_rate
        local local_ip gateway portal_active=false

        ssid=$(get_ssid_fast)  # fast path
        local_ip=$(get_local_ip)
        gateway=$(get_gateway)

        # Detailed from cache
        rssi=$(get_rssi); noise=$(get_noise); channel=$(get_channel)
        tx_rate=$(get_tx_rate)

        echo -e "  ${BOLD}${WHT}📡 WIRELESS${RST}"
        echo -e "  ${DIM}$(repeat_char '─' 50)${RST}"
        if [[ -n "$ssid" ]]; then
            local sc="$WHT"; [[ "$ssid" == "$TARGET_SSID" ]] && sc="$BGRN"
            printf "  ${DIM}%-14s${RST} ${sc}${BOLD}%s${RST}" "Network" "$ssid"
            [[ "$ssid" == "$TARGET_SSID" ]] && printf "  ${BGRN}★${RST}"; echo ""
            if [[ -n "$rssi" && "$rssi" =~ ^-?[0-9]+$ ]]; then
                printf "  ${DIM}%-14s${RST} " "Signal"; signal_bar_graph "$rssi"; echo ""
                printf "  ${DIM}%-14s${RST} ${WHT}%s dBm${RST}" "RSSI" "$rssi"
                [[ -n "$noise" && "$noise" =~ ^-?[0-9]+$ ]] && printf "  ${DIM}│${RST}  ${DIM}Noise${RST} ${WHT}%s dBm${RST}" "$noise"
                echo ""
                if [[ -n "$noise" && "$noise" =~ ^-?[0-9]+$ ]]; then
                    local snr=$(( rssi - noise )); local snrc="$RED"
                    (( snr>10 )) && snrc="$YEL"; (( snr>20 )) && snrc="$GRN"; (( snr>30 )) && snrc="$BGRN"
                    printf "  ${DIM}%-14s${RST} ${snrc}%s dB${RST}\n" "SNR" "$snr"
                fi
            fi
            [[ -n "$channel" ]] && printf "  ${DIM}%-14s${RST} ${WHT}%s${RST}\n" "Channel" "$channel"
            [[ -n "$tx_rate" ]] && printf "  ${DIM}%-14s${RST} ${WHT}%s Mbps${RST}\n" "TX Rate" "$tx_rate"
        else
            echo -e "  ${RED}${BOLD}  ✗ Not connected${RST}"
        fi
        echo ""

        echo -e "  ${BOLD}${WHT}🌐 NETWORK${RST}"
        echo -e "  ${DIM}$(repeat_char '─' 50)${RST}"
        [[ -n "$local_ip" ]] && printf "  ${DIM}%-14s${RST} ${WHT}%s${RST}\n" "Local IP" "$local_ip"
        [[ -n "$gateway" ]]  && printf "  ${DIM}%-14s${RST} ${WHT}%s${RST}\n" "Gateway" "$gateway"
        if has_internet; then
            local lat; lat=$(get_ping_latency)
            printf "  ${DIM}%-14s${RST} ${BGRN}${BOLD}● Online${RST}  ${DIM}(%s)${RST}\n" "Internet" "$lat"
        else
            printf "  ${DIM}%-14s${RST} ${BRED}${BOLD}● Offline${RST}\n" "Internet"
            is_captive_portal_active && { portal_active=true; printf "  ${DIM}%-14s${RST} ${YEL}${BOLD}⚠ Login needed${RST}\n" "Portal"; }
        fi
        echo ""

        # Data usage
        local usage; usage=$(get_data_usage)
        local di do ti to; read -r di do ti to _ _ <<< "$usage"
        echo -e "  ${BOLD}${WHT}📊 DATA (Today)${RST}"
        echo -e "  ${DIM}$(repeat_char '─' 50)${RST}"
        printf "  ${BGRN}↓${RST} ${WHT}%-14s${RST} ${BCYN}↑${RST} ${WHT}%-14s${RST} ${DIM}Total${RST} ${BOLD}%s${RST}\n" \
            "$(format_bytes "$ti")" "$(format_bytes "$to")" "$(format_bytes $((ti+to)))"
        echo ""

        echo -e "  ${BOLD}${WHT}🔐 AUTO-LOGIN${RST}"
        echo -e "  ${DIM}$(repeat_char '─' 50)${RST}"
        has_credentials && {
            local u; u=$(get_credential "$KEYCHAIN_ACCOUNT_USER")
            printf "  ${DIM}%-14s${RST} ${WHT}%s${RST}  ${BGRN}✓${RST}\n" "User" "$u"
        }
        if is_daemon_running; then
            printf "  ${DIM}%-14s${RST} ${BGRN}${BOLD}● Running${RST}\n" "Daemon"
        fi
        printf "  ${DIM}%-14s${RST} ${WHT}%d${RST}  ${DIM}(last: %s)${RST}\n" "Logins" "$login_count" "$last_login"
        local now elapsed hrs mins secs; now=$(date +%s); elapsed=$((now - uptime_start))
        hrs=$((elapsed/3600)); mins=$(((elapsed%3600)/60)); secs=$((elapsed%60))
        printf "  ${DIM}%-14s${RST} ${WHT}%02d:%02d:%02d${RST}\n" "Uptime" "$hrs" "$mins" "$secs"
        echo ""

        # Logs
        echo -e "  ${BOLD}${WHT}📋 RECENT${RST}"
        echo -e "  ${DIM}$(repeat_char '─' 50)${RST}"
        if [[ -f "$LOG_FILE" ]] && [[ -s "$LOG_FILE" ]]; then
            tail -4 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
                if echo "$line" | grep -q "✅"; then echo -e "  ${GRN}${line}${RST}"
                elif echo "$line" | grep -q "❌"; then echo -e "  ${RED}${line}${RST}"
                else echo -e "  ${DIM}${line}${RST}"; fi
            done
        else echo -e "  ${DIM}No activity.${RST}"; fi
        echo ""

        echo -e "  ${DIM}$(repeat_char '─' 50)${RST}"
        echo -e "  ${DIM}Refreshes every ${CHECK_INTERVAL}s${RST}  ${DIM}│${RST}  ${BOLD}Ctrl+C${RST} ${DIM}to exit${RST}"

        # Auto-login
        if [[ "$portal_active" == true ]] && has_credentials && [[ "$ssid" == "$TARGET_SSID" ]]; then
            log "Dashboard: auto-login triggered."
            do_login && { ((login_count++)) || true; last_login=$(short_time); }
        fi

        sleep "$CHECK_INTERVAL"
    done
}

cmd_logs() {
    echo -e "\n  ${BRAND}${BOLD}NetPulse · Logs${RST}\n  ${DIM}Ctrl+C to stop${RST}\n"
    [[ ! -f "$LOG_FILE" ]] && touch "$LOG_FILE"
    [[ -s "$LOG_FILE" ]] && tail -20 "$LOG_FILE"
    echo -e "  ${DIM}── live ──${RST}"
    tail -f "$LOG_FILE" 2>/dev/null
}

cmd_daemon() {
    log "━━━ Daemon started (v${VERSION}, interval=${CHECK_INTERVAL}s) ━━━"
    local fc=0
    while true; do
        do_check_and_login && fc=0 || ((fc++)) || true
        local st=$CHECK_INTERVAL
        (( fc > 3 )) && { st=$(( CHECK_INTERVAL * (2**(fc-3)) )); (( st > 300 )) && st=300; log_warn "Backoff: ${st}s (fails=$fc)"; }
        sleep "$st"
    done
}

cmd_help() {
    echo -e "\n${BRAND}${BOLD}"
    cat << 'B'
   _   _      _   ___      _          
  | \ | | ___| |_| _ \_  _| |___ ___  
  |  \| |/ -_)  _|  _/ || | (_-</ -_) 
  |_|\_|\___|\__|_|   \_,_|_/__/\___| 
B
    echo -e "${RST}\n  ${DIM}v${VERSION}${RST}\n"
    printf "  ${BCYN}%-14s${RST} %s\n" "setup" "Store credentials" "login" "One-shot login" \
        "status" "Full network status" "speedtest" "Download/upload speed test" \
        "data" "Data usage stats" "dashboard" "Live monitoring" "logs" "View logs" \
        "install" "Background service" "uninstall" "Remove service" "help" "This help"
    echo ""
}

# ── Interactive Sub-menus ───────────────────────────────────────────────────
cmd_manage_login() {
    if has_credentials; then
        echo -e "\n  ${BRAND}${BOLD}NetPulse · Login Management${RST}\n"
        echo -e "    ${BCYN}${BOLD}1${RST}  Login now"
        echo -e "    ${BCYN}${BOLD}2${RST}  Reconfigure credentials"
        echo -e "    ${DIM}${BOLD}b${RST}  ${DIM}Back${RST}\n"
        read -rp "$(echo -e "  ${BOLD}→ ${RST}")" sub_choice
        case "$sub_choice" in
            1) cmd_login; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            2) cmd_setup; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            *) return ;;
        esac
    else
        cmd_setup
        echo -e "  ${DIM}Press Enter...${RST}"; read -r
    fi
}

cmd_diagnostics() {
    cmd_status
    echo ""
    read -rp "$(echo -e "  ${BOLD}Run speed test? [y/N]: ${RST}")" run_st
    if [[ "$run_st" =~ ^[Yy]$ ]]; then
        cmd_speedtest
    fi
}

cmd_manage_daemon() {
    if is_daemon_running || [[ -f "$LAUNCHAGENT_PLIST" ]] || [[ -f "$HOME/.config/systemd/user/${SYSTEMD_SERVICE}" ]]; then
        echo -e "\n  ${BRAND}${BOLD}NetPulse · Daemon Management${RST}\n"
        echo -e "    ${BCYN}${BOLD}1${RST}  View live logs"
        echo -e "    ${RED}${BOLD}2${RST}  Uninstall daemon"
        echo -e "    ${DIM}${BOLD}b${RST}  ${DIM}Back${RST}\n"
        read -rp "$(echo -e "  ${BOLD}→ ${RST}")" sub_choice
        case "$sub_choice" in
            1) cmd_logs ;;
            2) cmd_uninstall; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            *) return ;;
        esac
    else
        cmd_install
        echo -e "  ${DIM}Press Enter...${RST}"; read -r
    fi
}

# ── Interactive Menu (loops until quit) ─────────────────────────────────────
cmd_interactive() {
    init_data_tracking
    _refresh_sp_background  # pre-warm cache in background

    while true; do
        clear
        echo -e "${BRAND}${BOLD}"
        cat << 'B'
   _   _      _   ___      _          
  | \ | | ___| |_| _ \_  _| |___ ___  
  |  \| |/ -_)  _|  _/ || | (_-</ -_) 
  |_|\_|\___|\__|_|   \_,_|_/__/\___| 
B
        echo -e "${RST}\n  ${DIM}v${VERSION}${RST}\n"

        # Fast status bar (no system_profiler call)
        local ssid; ssid=$(get_ssid_fast)

        if [[ -n "$ssid" ]]; then
            printf "  ${DIM}WiFi${RST}        ${BOLD}%s${RST}" "$ssid"
            # Use cached RSSI if available
            if [[ -f "$SP_CACHE_FILE" ]]; then
                _sp_data=$(cat "$SP_CACHE_FILE" 2>/dev/null)
                local rssi; rssi=$(get_rssi)
                [[ -n "$rssi" && "$rssi" =~ ^-?[0-9]+$ ]] && printf "  $(rssi_to_bars "$rssi")  ${DIM}(%s dBm)${RST}" "$rssi"
            fi
            echo ""
        else
            echo -e "  ${DIM}WiFi${RST}        ${RED}Not connected${RST}"
        fi

        if has_internet; then
            echo -e "  ${DIM}Internet${RST}    ${BGRN}● Online${RST}"
        else
            echo -e "  ${DIM}Internet${RST}    ${BRED}● Offline${RST}"
        fi

        # Quick data usage
        local usage; usage=$(get_data_usage)
        local _1 _2 ti to; read -r _1 _2 ti to _ _ <<< "$usage"
        printf "  ${DIM}Data Today${RST}  ${BGRN}↓${RST}${WHT}%s${RST}  ${BCYN}↑${RST}${WHT}%s${RST}\n" "$(format_bytes "$ti")" "$(format_bytes "$to")"

        has_credentials && {
            local u; u=$(get_credential "$KEYCHAIN_ACCOUNT_USER")
            echo -e "  ${DIM}User${RST}        ${WHT}${u}${RST}  ${BGRN}✓${RST}"
        } || echo -e "  ${DIM}User${RST}        ${RED}Not set${RST}"

        if is_daemon_running; then
            echo -e "  ${DIM}Daemon${RST}      ${BGRN}● Running${RST}"
        elif [[ -f "$LAUNCHAGENT_PLIST" ]] || [[ -f "$HOME/.config/systemd/user/${SYSTEMD_SERVICE}" ]]; then
            echo -e "  ${DIM}Daemon${RST}      ${YEL}● Stopped${RST}"
        else
            echo -e "  ${DIM}Daemon${RST}      ${DIM}○ Not installed${RST}"
        fi

        echo -e "\n  ${DIM}$(repeat_char '─' 42)${RST}\n"
        echo -e "  ${BOLD}Select an option:${RST}\n"

        if ! has_credentials; then
            echo -e "    ${BGRN}${BOLD}1${RST}  Manage Login & Credentials  ${DIM}← start here${RST}"
        else
            echo -e "    ${BCYN}${BOLD}1${RST}  Manage Login & Credentials"
        fi
        echo -e "    ${BCYN}${BOLD}2${RST}  Network Diagnostics"
        echo -e "    ${BCYN}${BOLD}3${RST}  Live Dashboard"
        echo -e "    ${BCYN}${BOLD}4${RST}  Background Service (Daemon)"
        echo ""
        echo -e "    ${DIM}${BOLD}q${RST}  ${DIM}Quit${RST}"
        echo ""

        read -rp "$(echo -e "  ${BOLD}→ ${RST}")" choice

        case "$choice" in
            1) cmd_manage_login ;;
            2) cmd_diagnostics; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            3) cmd_dashboard ;;
            4) cmd_manage_daemon ;;
            q|Q|exit) echo -e "\n  ${DIM}Goodbye! 👋${RST}\n"; exit 0 ;;
            "") _refresh_sp_background ;;
            *) echo -e "  ${RED}Invalid.${RST}"; sleep 0.5 ;;
        esac
    done
}

# ── Main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
    setup|--setup|-s)        cmd_setup ;;
    login|--login|-l)        cmd_login ;;
    status|--status)         cmd_status ;;
    speedtest|--speedtest)   cmd_speedtest ;;
    data|--data)             show_data_usage ;;
    dashboard|--dashboard)   cmd_dashboard ;;
    logs|--logs)             cmd_logs ;;
    install|--install|-i)    cmd_install ;;
    uninstall|--uninstall)   cmd_uninstall ;;
    daemon|--daemon|-d)      cmd_daemon ;;
    help|--help|-h)          cmd_help ;;
    "")                      cmd_interactive ;;
    *) echo -e "  ${RED}Unknown: $1${RST}  ${DIM}— netpulse help${RST}"; exit 1 ;;
esac
