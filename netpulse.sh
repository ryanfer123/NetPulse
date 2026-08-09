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
REDIRECT_URI="http://example.com"
SERVICE_NAME="ProntoAuthentication"
KEYCHAIN_SERVICE="netpulse-autologin"
KEYCHAIN_ACCOUNT_USER="wifi-username"
KEYCHAIN_ACCOUNT_PASS="wifi-password"
KEYCHAIN_ACCOUNT_DATALIMIT="wifi-data-limit"
CRED_FILE="$HOME/.netpulse-credentials"
CHECK_INTERVAL=60
LOG_FILE="$HOME/.netpulse-autologin.log"
DATA_FILE="$HOME/.netpulse-data-usage.dat"
DATA_HISTORY="$HOME/.netpulse-history.dat"
LAUNCHAGENT_LABEL="com.user.netpulse"
LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCHAGENT_LABEL}.plist"
SYSTEMD_SERVICE="netpulse.service"
MAX_LOG_LINES=1000
VERSION="5.0.4"
SP_CACHE_FILE="/tmp/.netpulse-cache"

OS=$(uname -s)
if [[ "$OS" == MINGW* || "$OS" == MSYS* || "$OS" == CYGWIN* ]]; then
    OS="Windows"
fi

# NOTE: TARGET_SSID and DATA_LIMIT are loaded after get_credential() is defined below.

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

is_target_ssid() {
    # Match any SSID containing "VIT" or "vit"
    if echo "$1" | grep -iq "vit"; then
        return 0
    fi
    return 1
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

generate_sparkline() {
    local numbers=("$@")
    local max=0
    for n in "${numbers[@]}"; do
        (( n > max )) && max=$n
    done
    [[ "$max" -eq 0 ]] && max=1
    
    local sparks=(" " "▂" "▃" "▄" "▅" "▆" "▇" "█")
    local spark_str=""
    for n in "${numbers[@]}"; do
        local idx=$(( (n * 7) / max ))
        [[ $idx -lt 0 ]] && idx=0
        [[ $idx -gt 7 ]] && idx=7
        spark_str+="${sparks[$idx]}"
    done
    echo "$spark_str"
}

get_historical_usage() {
    [[ ! -f "$DATA_HISTORY" ]] && return
    local usage_array=()
    while read -r date bytes; do
        usage_array+=("$bytes")
    done < <(tail -n 7 "$DATA_HISTORY")
    
    if [[ ${#usage_array[@]} -gt 0 ]]; then
        generate_sparkline "${usage_array[@]}"
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

# ── Load Config (must be after get_credential is defined) ───────────────────
DATA_LIMIT=$(get_credential "$KEYCHAIN_ACCOUNT_DATALIMIT" 2>/dev/null || true)

# ── Fast WiFi Info (ioreg / nmcli) ──────────────────────────────────────────
get_ssid_fast() {
    if [[ "$OS" == "Darwin" ]]; then
        # Try ipconfig (fast, works on modern macOS)
        local iface; iface=$(get_wifi_interface)
        local ssid=""
        if [[ -n "$iface" ]]; then
            ssid=$(ipconfig getsummary "$iface" 2>/dev/null | awk -F': ' '/  SSID /{print $2}')
        fi
        # Fallback: system_profiler (slower but always reliable)
        if [[ -z "$ssid" ]]; then
            ssid=$(system_profiler SPAirPortDataType 2>/dev/null | awk '/Current Network Information:/ {f=1; next} f && /^            [^ ]/ {gsub(/[: ]+$/, ""); gsub(/^  +/, ""); print; exit}')
        fi
        echo "$ssid"
    elif [[ "$OS" == "Windows" ]]; then
        netsh wlan show interfaces 2>/dev/null | awk -F': ' '/^    SSID/{print $2}' | tr -d '\r'
    else
        iwgetid -r 2>/dev/null || nmcli -t -f active,ssid dev wifi 2>/dev/null | egrep '^yes' | cut -d\' -f2 | cut -d: -f2
    fi
}

get_wifi_interface() {
    if [[ "$OS" == "Darwin" ]]; then
        networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2}'
    elif [[ "$OS" == "Windows" ]]; then
        netsh wlan show interfaces 2>/dev/null | awk -F': ' '/^    Name/{print $2}' | tr -d '\r'
    else
        iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' || nmcli -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2=="wifi"{print $1}' | head -n 1
    fi
}

get_local_ip() {
    local iface; iface=$(get_wifi_interface)
    if [[ "$OS" == "Darwin" ]]; then
        [[ -n "$iface" ]] && ipconfig getifaddr "$iface" 2>/dev/null
    elif [[ "$OS" == "Windows" ]]; then
        ipconfig 2>/dev/null | awk '/IPv4 Address/ {print $NF}' | tr -d '\r' | head -n 1
    else
        [[ -n "$iface" ]] && ip -4 addr show dev "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1
    fi
}

get_gateway() {
    if [[ "$OS" == "Darwin" ]]; then
        netstat -rn 2>/dev/null | awk '/default.*en/{print $2; exit}'
    elif [[ "$OS" == "Windows" ]]; then
        ipconfig 2>/dev/null | awk '/Default Gateway/ {print $NF}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tr -d '\r' | head -n 1
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
    if [[ "$OS" == "Windows" ]]; then
        getmac /v /fo csv 2>/dev/null | grep -i "wi-fi" | cut -d, -f3 | tr -d '\"\r'
    else
        [[ -n "$iface" ]] && ifconfig "$iface" 2>/dev/null | awk '/ether/{print $2}' || ip link show dev "$iface" 2>/dev/null | awk '/link\/ether/ {print $2}'
    fi
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
    elif [[ "$OS" == "Windows" ]]; then
        _sp_data=$(netsh wlan show interfaces 2>/dev/null | tr -d '\r')
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
    elif [[ "$OS" == "Windows" ]]; then
        local sig=$(echo "$_sp_data" | awk -F': ' '/^    Signal/{print $2}' | tr -d '% ')
        [[ -n "$sig" ]] && echo "$(( sig / 2 - 100 ))"
    else
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
    elif [[ "$OS" == "Windows" ]]; then
        echo "$_sp_data" | awk -F': ' '/^    Channel/{print $2}' | tr -d ' '
    else
        echo "$_sp_data" | grep -m1 "^\*" | cut -d: -f5
    fi
}

get_tx_rate() {
    if [[ "$OS" == "Darwin" ]]; then
        echo "$_sp_data" | awk '/Current Network Information:/ { f=1; next } f && /Transmit Rate:/ { sub(/.*: /, ""); print; exit }'
    elif [[ "$OS" == "Windows" ]]; then
        echo "$_sp_data" | awk -F': ' '/^    Transmit rate/{print $2}' | tr -d ' '
    else
        echo "$_sp_data" | grep -m1 "^\*" | cut -d: -f6 | tr -d ' '
    fi
}

get_security() {
    if [[ "$OS" == "Darwin" ]]; then
        echo "$_sp_data" | awk '/Current Network Information:/ { f=1; next } f && /Security:/ { sub(/.*: /, ""); print; exit }'
    elif [[ "$OS" == "Windows" ]]; then
        echo "$_sp_data" | awk -F': ' '/^    Authentication/{print $2}' | tr -d ' '
    else
        echo "$_sp_data" | grep -m1 "^\*" | cut -d: -f9
    fi
}

# ── Internet checks ────────────────────────────────────────────────────────
has_internet() {
    # Check 1: Google 204
    local c1; c1=$(curl -s -m 5 "http://www.gstatic.com/generate_204" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [[ "$c1" == "204" ]] && return 0
    
    # Check 2: Apple captive test
    local c2; c2=$(curl -s -m 5 "http://captive.apple.com/hotspot-detect.html" 2>/dev/null || true)
    echo "$c2" | grep -qi "Success" && return 0
    
    # Check 3: Cloudflare HTTPS
    curl -I -s -m 5 "https://1.1.1.1" -o /dev/null 2>/dev/null && return 0
    
    return 1
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
    elif [[ "$OS" == "Windows" ]]; then
        lat=$(ping -n 1 -w 2000 8.8.8.8 2>/dev/null | awk -F'=' '/Average/ {print $3}' | tr -d 'ms\r ')
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
        if [[ -n "$saved_today" && "$saved_today" != "$today" ]]; then
            local old_in; old_in=$(grep '^today_start_in=' "$DATA_FILE" | cut -d= -f2)
            local old_out; old_out=$(grep '^today_start_out=' "$DATA_FILE" | cut -d= -f2)
            local c_in; c_in=$(echo "$now_bytes" | awk '{print $1}')
            local c_out; c_out=$(echo "$now_bytes" | awk '{print $2}')
            
            local used_in=$(( c_in - old_in ))
            [[ $used_in -lt 0 ]] && used_in=$c_in
            local used_out=$(( c_out - old_out ))
            [[ $used_out -lt 0 ]] && used_out=$c_out
            
            echo "$saved_today $((used_in + used_out))" >> "$DATA_HISTORY"

            sed -i.bak "s/^today=.*/today=$today/" "$DATA_FILE"
            sed -i.bak "s/^today_start_in=.*/today_start_in=$c_in/" "$DATA_FILE"
            sed -i.bak "s/^today_start_out=.*/today_start_out=$c_out/" "$DATA_FILE"
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
    
    # History Sparkline
    local spark; spark=$(get_historical_usage)
    if [[ -n "$spark" ]]; then
        local usage_array=()
        if [[ -f "$DATA_HISTORY" ]]; then
            while read -r _ bytes; do
                usage_array+=("$bytes")
            done < <(tail -n 6 "$DATA_HISTORY")
        fi
        usage_array+=("$day_total")
        spark=$(generate_sparkline "${usage_array[@]}")
        
        printf "  ${BOLD}Past 7 Days Trend${RST}\n"
        printf "    ${BCYN}%s${RST}\n" "$spark"
        echo ""
    fi

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

# ── Ping Monitor ────────────────────────────────────────────────────────────
cmd_ping_monitor() {
    echo -e "\n  ${BRAND}${BOLD}NetPulse · Connection Monitor${RST}"
    echo -e "  ${DIM}Pinging 8.8.8.8... Press Ctrl+C to stop.${RST}\n"
    
    if ! has_internet; then
        echo -e "  ${RED}✗ No internet connection.${RST}\n"
        return 1
    fi

    local ping_cmd="ping"
    if [[ "$OS" == "Linux" ]]; then
        ping_cmd="ping -O" # Print failures on Linux
    elif [[ "$OS" == "Windows" ]]; then
        ping_cmd="ping -t" # Continuous ping on Windows
    fi

    $ping_cmd 8.8.8.8 | while read -r line; do
        if echo "$line" | grep -q "time=" || echo "$line" | grep -q "time<"; then
            local time_ms; time_ms=$(echo "$line" | sed -n 's/.*time[=<]\([0-9.]*\)ms.*/\1/p')
            [[ -z "$time_ms" ]] && time_ms=$(echo "$line" | sed -n 's/.*time[=<]\([0-9.]*\) ms.*/\1/p')
            local color="$BGRN"
            (( $(echo "$time_ms > 50" | bc -l 2>/dev/null || echo 0) )) && color="$YEL"
            (( $(echo "$time_ms > 150" | bc -l 2>/dev/null || echo 0) )) && color="$RED"
            
            # Simple bar
            local bar_len=$(echo "scale=0; $time_ms / 10" | bc 2>/dev/null || echo 1)
            [[ $bar_len -gt 40 ]] && bar_len=40
            local bar=$(repeat_char '■' "$bar_len")
            
            printf "  ${DIM}[%s]${RST}  ${color}%5.1f ms${RST}  ${color}%s${RST}\n" "$(short_time)" "$time_ms" "$bar"
        elif echo "$line" | grep -qi "timeout\|unreachable\|loss"; then
            printf "  ${DIM}[%s]${RST}  ${BRED}❌ PACKET LOSS${RST}  %s\n" "$(short_time)" "$line"
        fi
    done
}

# ── Login ───────────────────────────────────────────────────────────────────
get_gateway_ip() {
    if [[ "$OS" == "Darwin" ]]; then
        route -n get default 2>/dev/null | awk '/gateway:/ {print $2}'
    elif [[ "$OS" == "Windows" ]]; then
        ipconfig 2>/dev/null | awk '/Default Gateway/ {print $NF}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tr -d '\r' | head -n 1
    else
        ip route 2>/dev/null | awk '/default/ {print $3}'
    fi
}

do_login() {
    local username password
    username=$(get_credential "$KEYCHAIN_ACCOUNT_USER") || true
    password=$(get_credential "$KEYCHAIN_ACCOUNT_PASS") || true
    [[ -z "$username" || -z "$password" ]] && return 2

    log "Attempting login as '$username'..."
    local response body http_code
    local target_url="${PORTAL_URL}"
    
    response=$(curl -s -m 10 -w '\n%{http_code}' \
        -X POST "${target_url}?URI=${REDIRECT_URI}" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'User-Agent: Mozilla/5.0 (Android)' \
        --data-urlencode "userId=${username}" \
        --data-urlencode "password=${password}" \
        --data-urlencode "serviceName=${SERVICE_NAME}" \
        2>/dev/null) || true

    http_code=$(echo "$response" | tail -1)
    
    # Fallback to Gateway IP if DNS resolution failed (HTTP 000)
    if [[ "$http_code" == "000" ]]; then
        local gw; gw=$(get_gateway_ip)
        if [[ -n "$gw" ]]; then
            log "DNS resolution failed. Retrying with Gateway IP: $gw..."
            target_url="http://${gw}/cgi-bin/authlogin"
            response=$(curl -s -m 10 -w '\n%{http_code}' \
                -X POST "${target_url}?URI=${REDIRECT_URI}" \
                -H 'Content-Type: application/x-www-form-urlencoded' \
                -H 'User-Agent: Mozilla/5.0 (Android)' \
                --data-urlencode "userId=${username}" \
                --data-urlencode "password=${password}" \
                --data-urlencode "serviceName=${SERVICE_NAME}" \
                2>/dev/null) || true
            http_code=$(echo "$response" | tail -1)
        fi
    fi

    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "301" || "$http_code" == "302" ]]; then
        log_success "Login successful (Redirect $http_code)."
        notify "✅ WiFi connected"
        return 0
    elif echo "$body" | grep -qi "access granted\|you have successfully connected\|already logged in\|http-equiv=\"refresh\"\|http://example.com"; then
        log_success "Login successful!"
        notify "✅ WiFi connected"
        return 0
    elif echo "$body" | grep -qi "invalid\|incorrect\|wrong\|denied\|failed"; then
        log_error "Login failed — invalid credentials."
        notify "❌ Login failed"
        return 1
    else
        sleep 2
        has_internet && { log_success "Login OK (verified)."; notify "✅ WiFi connected"; return 0; }
        log_warn "Login unclear (HTTP $http_code)."
        return 1
    fi
}

do_check_and_login() {
    rotate_log
    local ssid; ssid=$(get_ssid_fast)
    [[ -z "$ssid" ]] && return 0
    is_target_ssid "$ssid" || return 0
    has_internet && return 0
    log "Captive portal detected on '$ssid'."
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
    if [[ "$OS" == "Windows" ]]; then
        echo -e "  ${YEL}⚠ Background Daemon is currently not supported on Windows Git Bash.${RST}"
        echo -e "  ${DIM}Please use the manual 'netpulse' command or WSL.${RST}\n"
        return 1
    fi
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
    read -rp "$(echo -e "  ${BOLD}Username ${DIM}(e.g. 24BCExxxx)${RST}${BOLD}: ")" wifi_user
    read -rsp "$(echo -e "  ${BOLD}Password${RST}${BOLD}: ")" wifi_pass; echo ""; echo ""
    read -rp "$(echo -e "  ${BOLD}Daily Data Limit in MB ${DIM}(leave blank for none)${RST}${BOLD}: ")" wifi_limit; echo ""
    
    [[ -z "$wifi_user" || -z "$wifi_pass" ]] && { echo -e "  ${RED}✗ Username and Password cannot be empty.${RST}"; return 1; }
    
    store_credential "$KEYCHAIN_ACCOUNT_USER" "$wifi_user"
    store_credential "$KEYCHAIN_ACCOUNT_PASS" "$wifi_pass"
    store_credential "$KEYCHAIN_ACCOUNT_DATALIMIT" "$wifi_limit"
    DATA_LIMIT="$wifi_limit"
    
    echo -e "  ${BGRN}${BOLD}✓ Setup complete!${RST}"; echo ""
}

cmd_login() {
    echo ""
    echo -e "  ${BRAND}${BOLD}NetPulse · Manual Login${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 30)${RST}"
    echo ""
    has_credentials || { echo -e "  ${RED}✗ Run: netpulse setup${RST}"; echo ""; return 1; }
    local ssid; ssid=$(get_ssid_fast)
    echo -e "  ${DIM}Network:${RST}  ${BOLD}${ssid:-Not connected}${RST}"
    if [[ -z "$ssid" ]]; then
        echo -e "  ${RED}✗ Not connected to any WiFi.${RST}"; echo ""; return 0
    fi
    is_target_ssid "$ssid" || { echo -e "  ${YEL}⚠  Not on a VIT network.${RST}"; echo ""; return 0; }
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
        local sc="$WHT"; is_target_ssid "$ssid" && sc="$BGRN"
        printf "  ${DIM}%-14s${RST} ${sc}${BOLD}%s${RST}" "SSID" "$ssid"
        is_target_ssid "$ssid" && printf "  ${BGRN}★${RST}"; echo ""

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
            local sc="$WHT"; is_target_ssid "$ssid" && sc="$BGRN"
            printf "  ${DIM}%-14s${RST} ${sc}${BOLD}%s${RST}" "SSID" "$ssid"
            is_target_ssid "$ssid" && printf "  ${BGRN}★${RST}"; echo ""
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
        if [[ "$portal_active" == true ]] && has_credentials && is_target_ssid "$ssid"; then
            echo -e "  ${DIM}$(repeat_char '─' 42)${RST}"
            echo -ne "  ${BGRN}Portal detected! Auto-logging in...${RST} "
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
    if [[ "$OS" == "Windows" ]]; then
        echo -e "  ${YEL}⚠ Background Daemon is currently not supported on Windows Git Bash.${RST}\n"
        return 1
    fi
    log "━━━ Daemon started (v${VERSION}, interval=${CHECK_INTERVAL}s) ━━━"
    local fc=0
    while true; do
        do_check_and_login && fc=0 || ((fc++)) || true
        
        # Keep-alive
        local ssid; ssid=$(get_ssid_fast)
        if has_internet && is_target_ssid "$ssid"; then
            curl -I https://1.1.1.1 --connect-timeout 2 -s -o /dev/null || true
        fi
        
        # Data limit check
        if [[ -n "${DATA_LIMIT:-}" && "$DATA_LIMIT" =~ ^[0-9]+$ ]]; then
            local usage; usage=$(get_data_usage)
            local _1 _2 ti to; read -r _1 _2 ti to _ _ <<< "$usage"
            local today_mb=$(( (ti + to) / 1048576 ))
            if (( today_mb >= DATA_LIMIT )); then
                if [[ ! -f "/tmp/.netpulse-data-warned" ]]; then
                    notify "⚠️ Data Limit Exceeded ($today_mb MB / $DATA_LIMIT MB)"
                    log_warn "Data limit ($DATA_LIMIT MB) exceeded."
                    touch "/tmp/.netpulse-data-warned"
                fi
            else
                rm -f "/tmp/.netpulse-data-warned" 2>/dev/null
            fi
        fi

        local st=$CHECK_INTERVAL
        (( fc > 3 )) && { st=$(( CHECK_INTERVAL * (2**(fc-3)) )); (( st > 300 )) && st=300; log_warn "Backoff: ${st}s (fails=$fc)"; }
        sleep "$st"
    done
}

cmd_faq() {
    echo -e "\n  ${BOLD}${WHT}❓ FREQUENTLY ASKED QUESTIONS${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 50)${RST}\n"

    echo -e "  ${BOLD}Q: How do I set up NetPulse for the first time?${RST}"
    echo -e "  ${DIM}A:${RST} Run ${BCYN}netpulse setup${RST}. Enter your VIT registration"
    echo -e "     number (e.g. ${WHT}24BCE0605${RST}) as the username, your WiFi"
    echo -e "     password, and the network name you connect to (e.g."
    echo -e "     ${WHT}T-VIT${RST}). Then run ${BCYN}netpulse install${RST} to enable"
    echo -e "     automatic background login.\n"

    echo -e "  ${BOLD}Q: I connect to different networks across campus.${RST}"
    echo -e "  ${DIM}A:${RST} During setup, enter all network names separated by"
    echo -e "     commas: ${WHT}T-VIT,M-VIT,T block,M block${RST}"
    echo -e "     NetPulse will auto-login on any of them.\n"

    echo -e "  ${BOLD}Q: How do I change my saved password or SSID?${RST}"
    echo -e "  ${DIM}A:${RST} Just run ${BCYN}netpulse setup${RST} again. It will overwrite"
    echo -e "     the old values.\n"

    echo -e "  ${BOLD}Q: Where are my credentials stored?${RST}"
    if [[ "$OS" == "Darwin" ]]; then
        echo -e "  ${DIM}A:${RST} In the macOS Keychain (encrypted). Open ${WHT}Keychain"
        echo -e "     Access${RST} and search for ${WHT}netpulse-autologin${RST} to view.\n"
    else
        echo -e "  ${DIM}A:${RST} In ${WHT}~/.netpulse-credentials${RST} with ${WHT}chmod 600${RST}"
        echo -e "     (only your user can read it).\n"
    fi

    echo -e "  ${BOLD}Q: What is the background daemon / service?${RST}"
    echo -e "  ${DIM}A:${RST} It runs silently, checking every 60s if you're on a"
    echo -e "     target network without internet. If so, it auto-logs"
    echo -e "     you in. It starts on boot automatically.\n"

    echo -e "  ${BOLD}Q: How do I start/stop/check the daemon?${RST}"
    echo -e "  ${DIM}A:${RST} ${BCYN}netpulse install${RST}   → Install & start"
    echo -e "     ${BCYN}netpulse uninstall${RST} → Stop & remove"
    echo -e "     ${BCYN}netpulse status${RST}    → See if it's running\n"

    echo -e "  ${BOLD}Q: Login shows \"Failed\" or \"HTTP 000\".${RST}"
    echo -e "  ${DIM}A:${RST} This usually means one of:"
    echo -e "     ${DIM}•${RST} You're not on the campus WiFi (e.g. mobile hotspot)"
    echo -e "     ${DIM}•${RST} The portal server ${WHT}10.10.0.1${RST} is unreachable"
    echo -e "     ${DIM}•${RST} Your credentials are wrong → re-run ${BCYN}netpulse setup${RST}"
    echo -e "     ${DIM}•${RST} The campus network is genuinely down\n"

    echo -e "  ${BOLD}Q: It says \"Offline\" but I have internet.${RST}"
    echo -e "  ${DIM}A:${RST} NetPulse checks Google, Apple, and Cloudflare to"
    echo -e "     detect internet. Some networks or hotspots may block"
    echo -e "     these. Try ${BCYN}netpulse status${RST} for a detailed check.\n"

    echo -e "  ${BOLD}Q: What is the daily data limit?${RST}"
    echo -e "  ${DIM}A:${RST} During setup, you can set a limit in MB (e.g. ${WHT}500${RST})."
    echo -e "     The daemon will send a desktop notification when you"
    echo -e "     exceed it. Leave blank during setup to disable.\n"

    echo -e "  ${BOLD}Q: How do I completely uninstall NetPulse?${RST}"
    echo -e "  ${DIM}A:${RST} Run these commands:"
    echo -e "     ${BCYN}netpulse uninstall${RST}"
    echo -e "     ${DIM}rm -f ~/.netpulse-autologin.log${RST}"
    echo -e "     ${DIM}rm -f ~/.netpulse-data-usage.dat${RST}"
    echo -e "     ${DIM}rm -f ~/.netpulse-history.dat${RST}"
    if [[ "$OS" == "Darwin" ]]; then
        echo -e "     Then remove keychain entries in Keychain Access"
        echo -e "     (search for ${WHT}netpulse-autologin${RST}).\n"
    else
        echo -e "     ${DIM}rm -f ~/.netpulse-credentials${RST}\n"
    fi
}

cmd_logout() {
    echo ""
    echo -e "  ${BRAND}${BOLD}NetPulse · Captive Portal Logout${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 32)${RST}"
    echo -e "  ${DIM}Terminating session...${RST}"
    
    local http_code
    http_code=$(curl -s -m 5 -w '%{http_code}' "http://phc.prontonetworks.com/cgi-bin/authlogout" -o /dev/null) || true
    
    if [[ "$http_code" == "000" ]]; then
        local gw; gw=$(get_gateway_ip)
        if [[ -n "$gw" ]]; then
            curl -s -m 5 "http://${gw}/cgi-bin/authlogout" -o /dev/null || true
        fi
    fi
    
    echo -e "  ${BGRN}✓ Logged out successfully.${RST}"
    echo -e "  ${DIM}You can now connect another device.${RST}"
    echo ""
}

cmd_export() {
    echo ""
    echo -e "  ${BRAND}${BOLD}NetPulse · Data Export${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 32)${RST}"
    local out_file="$HOME/Desktop/NetPulse_Usage_Report.csv"
    echo "Date,Bytes,Formatted" > "$out_file"
    if [[ -f "$DATA_HISTORY" ]]; then
        while read -r date bytes; do
            echo "$date,$bytes,$(format_bytes "$bytes")" >> "$out_file"
        done < "$DATA_HISTORY"
        echo -e "  ${BGRN}✓ Exported to Desktop!${RST}"
        echo -e "  ${DIM}File: ~/Desktop/NetPulse_Usage_Report.csv${RST}"
    else
        echo -e "  ${YEL}⚠ No historical data found yet.${RST}"
    fi
    echo ""
}

cmd_scan() {
    echo ""
    echo -e "  ${BRAND}${BOLD}NetPulse · Smart WiFi Scanner${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 40)${RST}"
    echo -e "  ${DIM}Scanning for VIT networks...${RST}\n"
    
    local found=0
    
    if [[ "$OS" == "Darwin" ]]; then
        local raw; raw=$(system_profiler SPAirPortDataType 2>/dev/null | awk -F':' '/^[ ]*[^:]+:$/ {ssid=$1; gsub(/^[ ]+/, "", ssid)} /Signal \/ Noise:/ {split($2, a, " "); print ssid ":" a[1]}')
        local sorted; sorted=$(echo "$raw" | sort -t: -k2 -nr)
        
        while IFS=':' read -r ssid sig; do
            if echo "$ssid" | grep -iq "vit" && [[ -n "$sig" ]]; then
                local q="Fair"; local c="$YEL"
                if (( sig > -60 )); then q="Good"; c="$BGRN"; fi
                if (( sig < -80 )); then q="Poor"; c="$BRED"; fi
                printf "  %-20s ${c} %4s dBm ${RST} %s\n" "${ssid:0:20}" "$sig" "($q)"
                found=1
            fi
        done <<< "$sorted"
        
    elif [[ "$OS" == "Windows" ]]; then
        local raw; raw=$(netsh wlan show networks mode=bssid 2>/dev/null | tr -d '\r')
        local sorted; sorted=$(echo "$raw" | awk '/SSID/ {ssid=$4; for(i=5;i<=NF;i++) ssid=ssid " " $i} /Signal/ {print ssid ":" $2}' | sort -t: -k2 -nr)
        
        while IFS=':' read -r ssid sig_pct; do
            local sig=${sig_pct%\%}
            if echo "$ssid" | grep -iq "vit" && [[ -n "$sig" ]]; then
                local q="Fair"; local c="$YEL"
                if (( sig > 70 )); then q="Good"; c="$BGRN"; fi
                if (( sig < 30 )); then q="Poor"; c="$BRED"; fi
                printf "  %-20s ${c} %4s %%  ${RST} %s\n" "${ssid:0:20}" "$sig" "($q)"
                found=1
            fi
        done <<< "$sorted"
        
    else
        local raw; raw=$(nmcli -t -f SSID,SIGNAL dev wifi 2>/dev/null)
        local sorted; sorted=$(echo "$raw" | sort -t: -k2 -nr)
        
        while IFS=':' read -r ssid sig; do
            if echo "$ssid" | grep -iq "vit" && [[ -n "$sig" ]]; then
                local q="Fair"; local c="$YEL"
                if (( sig > 70 )); then q="Good"; c="$BGRN"; fi
                if (( sig < 30 )); then q="Poor"; c="$BRED"; fi
                printf "  %-20s ${c} %4s %%  ${RST} %s\n" "${ssid:0:20}" "$sig" "($q)"
                found=1
            fi
        done <<< "$sorted"
    fi
    
    if [[ $found -eq 0 ]]; then
        echo -e "  ${DIM}No VIT networks found in range.${RST}"
    else
        echo -e "\n  ${DIM}Tip: Connect to the network with the highest signal (Good)${RST}"
    fi
    echo ""
}

cmd_menubar() {
    local is_online=0
    if has_internet; then is_online=1; fi
    
    if [[ $is_online -eq 1 ]]; then
        echo "NetPulse: ● | color=green"
    else
        echo "NetPulse: ● | color=red"
    fi
    echo "---"
    
    local current_ssid="Disconnected"
    if [[ "$OS" == "Darwin" ]]; then
        current_ssid=$(networksetup -getairportnetwork en0 2>/dev/null | awk -F': ' '{print $2}')
    else
        current_ssid=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F':' '/^yes/ {print $2}')
    fi
    [[ -z "$current_ssid" ]] && current_ssid="Unknown"
    
    echo "SSID: $current_ssid"
    
    local today; today=$(date +%Y-%m-%d)
    local usage_bytes=0
    if [[ -f "$DATA_FILE" ]]; then
        local file_date; file_date=$(head -n 1 "$DATA_FILE" | cut -d' ' -f1)
        if [[ "$file_date" == "$today" ]]; then
            usage_bytes=$(head -n 1 "$DATA_FILE" | cut -d' ' -f2)
        fi
    fi
    echo "Data Today: $(format_bytes "$usage_bytes")"
    
    echo "---"
    local script_path; script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    echo "Login Now | bash='$script_path' param1=login terminal=false"
    echo "Open Dashboard | bash='$script_path' param1=dashboard terminal=true"
    echo "Export Data | bash='$script_path' param1=export terminal=true"
}

cmd_help() {
    echo -e "\n${BRAND}${BOLD}"
    cat << 'B'
   _   _      _   ___      _          
  | \ | | ___| |_| _ \_  _| |___ ___  
  |  \| |/ -_)  _|  _/ || | (_-</ -_) 
  |_|\_|\___|\___|_|   \_,_|_/__/\___| 
B
    echo -e "${RST}\n  ${DIM}v${VERSION}${RST}\n"

    echo -e "  ${BOLD}${WHT}🚀 QUICK START${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 50)${RST}"
    echo -e "  ${DIM}1.${RST} Run ${BCYN}netpulse setup${RST} to save your VIT credentials"
    echo -e "  ${DIM}2.${RST} Run ${BCYN}netpulse login${RST} to connect to the campus portal"
    echo -e "  ${DIM}3.${RST} Run ${BCYN}netpulse install${RST} to auto-login in the background"
    echo -e "  ${DIM}4.${RST} Done! NetPulse handles everything from here.\n"

    echo -e "  ${BOLD}${WHT}📋 COMMANDS${RST}"
    echo -e "  ${DIM}$(repeat_char '─' 50)${RST}"
    printf "  ${BCYN}%-14s${RST} %s\n" \
        "setup" "Store credentials & target networks" \
        "login" "One-shot portal login" \
        "logout" "Disconnect from captive portal" \
        "status" "Full network status" \
        "scan" "Smart WiFi Scanner" \
        "speedtest" "Download/upload speed test" \
        "ping" "Live connection monitor" \
        "data" "Data usage stats & history" \
        "export" "Export data usage to CSV" \
        "dashboard" "Live monitoring dashboard" \
        "logs" "View daemon logs" \
        "install" "Install background service" \
        "uninstall" "Remove background service" \
        "menubar" "Print macOS/Linux menubar plugin code" \
        "faq" "Troubleshooting & common questions" \
        "help" "This help page"
    echo ""
}

# ── Interactive Sub-menus ───────────────────────────────────────────────────
cmd_manage_login() {
    if has_credentials; then
        echo -e "\n  ${BRAND}${BOLD}NetPulse · Login Management${RST}\n"
        echo -e "    ${BCYN}${BOLD}1${RST}  Login now"
        echo -e "    ${BCYN}${BOLD}2${RST}  Logout (Disconnect)"
        echo -e "    ${BCYN}${BOLD}3${RST}  Reconfigure credentials"
        echo -e "    ${DIM}${BOLD}b${RST}  ${DIM}Back${RST}\n"
        read -rp "$(echo -e "  ${BOLD}→ ${RST}")" sub_choice
        case "$sub_choice" in
            1) cmd_login; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            2) cmd_logout; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            3) cmd_setup; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
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
    echo -e "  ${BOLD}Run Diagnostics:${RST}"
    echo -e "    ${BCYN}${BOLD}1${RST}  Run speed test"
    echo -e "    ${BCYN}${BOLD}2${RST}  Live Ping Monitor"
    echo -e "    ${DIM}${BOLD}b${RST}  ${DIM}Skip${RST}\n"
    read -rp "$(echo -e "  ${BOLD}→ ${RST}")" diag_choice
    
    case "$diag_choice" in
        1) cmd_speedtest ;;
        2) cmd_ping_monitor ;;
        *) return ;;
    esac
}

cmd_manage_data() {
    echo -e "\n  ${BRAND}${BOLD}NetPulse · Data & Usage${RST}\n"
    echo -e "    ${BCYN}${BOLD}1${RST}  View Data Usage Stats & History"
    echo -e "    ${BCYN}${BOLD}2${RST}  Export Data to CSV (Desktop)"
    echo -e "    ${DIM}${BOLD}b${RST}  ${DIM}Back${RST}\n"
    read -rp "$(echo -e "  ${BOLD}→ ${RST}")" sub_choice
    case "$sub_choice" in
        1) show_data_usage; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
        2) cmd_export; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
        *) return ;;
    esac
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
        echo -e "    ${BCYN}${BOLD}2${RST}  Smart WiFi Scanner"
        echo -e "    ${BCYN}${BOLD}3${RST}  Network Diagnostics"
        echo -e "    ${BCYN}${BOLD}4${RST}  Live Dashboard"
        echo -e "    ${BCYN}${BOLD}5${RST}  Data & Export"
        echo -e "    ${BCYN}${BOLD}6${RST}  Background Service (Daemon)"
        echo -e "    ${BCYN}${BOLD}7${RST}  Help & FAQ"
        echo ""
        echo -e "    ${DIM}${BOLD}q${RST}  ${DIM}Quit${RST}"
        echo ""

        read -rp "$(echo -e "  ${BOLD}→ ${RST}")" choice

        case "$choice" in
            1) cmd_manage_login ;;
            2) cmd_scan; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            3) cmd_diagnostics ;;
            4) cmd_dashboard ;;
            5) cmd_manage_data ;;
            6) cmd_manage_daemon ;;
            7) cmd_help; cmd_faq; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
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
    logout|--logout)         cmd_logout ;;
    scan|--scan)             cmd_scan ;;
    export|--export)         cmd_export ;;
    menubar|--menubar)       cmd_menubar ;;
    status|--status)         cmd_status ;;
    speedtest|--speedtest)   cmd_speedtest ;;
    ping|--ping)             cmd_ping_monitor ;;
    data|--data)             show_data_usage ;;
    dashboard|--dashboard)   cmd_dashboard ;;
    logs|--logs)             cmd_logs ;;
    install|--install|-i)    cmd_install ;;
    uninstall|--uninstall)   cmd_uninstall ;;
    daemon|--daemon|-d)      cmd_daemon ;;
    help|--help|-h)          cmd_help ;;
    faq|--faq)               cmd_faq ;;
    "")                      cmd_interactive ;;
    *) echo -e "  ${RED}Unknown: $1${RST}  ${DIM}— netpulse help${RST}"; exit 1 ;;
esac
