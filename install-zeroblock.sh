#!/bin/sh
# ZeroBlock installer for OpenWrt 24.10.3+
# On Routerich devices: auto-install AWG/Opera, DPI check, YouTube list management
# On other devices: install packages only

set -e

DPI_RUNS=20
DPI_PAUSE=2
DPI_TIMEOUT=10
DPI_CONNECT_TIMEOUT=5
DPI_THRESHOLD=$((5 * 1024 * 1024))
DPI_URL="https://test.googlevideo.com/v2/cimg/android/blobs/sha256:6fd8bdac3da660bde7bd0b6f2b6a46e1b686afb74b9a4614def32532b73f5eaa"

LOGFILE="/tmp/install_zeroblock.log"
YOUTUBE_RESULT="/tmp/.zb_yt_result"
IS_ROUTERICH=0
ZEROBLOCK_WAS_INSTALLED=0

AWG10_WAIT_TIMEOUT=60
AWG10_WAIT_INTERVAL=2

log() { echo ">>> $1"; }
die() { echo "!!! $1" >&2; INSTALL_FAILED=1; exit 1; }

zapret2_running() {
    pidof nfqws2 >/dev/null 2>&1
}

stop_zapret2_if_present() {
    if [ -x /etc/init.d/zapret2 ]; then
        log "Stopping zapret2..."
        /etc/init.d/zapret2 stop 2>/dev/null || true
    fi
}

ensure_zapret2_running() {
    if zapret2_running; then
        log "nfqws2 is already running"
        return 0
    fi

    if [ ! -x /etc/init.d/zapret2 ]; then
        log "Warning: /etc/init.d/zapret2 not found, cannot start zapret2"
        return 1
    fi

    log "nfqws2 is not running, starting zapret2..."
    /etc/init.d/zapret2 start 2>/dev/null || true
    sleep 5

    if zapret2_running; then
        log "zapret2 started successfully"
        return 0
    fi

    log "Warning: zapret2 start did not launch nfqws2"
    return 1
}

# --- Check OpenWrt version ---
check_version() {
    local ver
    . /etc/openwrt_release 2>/dev/null || die "Not an OpenWrt device"
    ver="$DISTRIB_RELEASE"
    [ -n "$ver" ] || die "Cannot determine OpenWrt version"

    local major minor patch
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    patch=$(echo "$ver" | cut -d. -f3 | sed 's/[^0-9].*//')
    patch="${patch:-0}"

    if [ "$major" -lt 24 ] || \
       { [ "$major" -eq 24 ] && [ "$minor" -lt 10 ]; } || \
       { [ "$major" -eq 24 ] && [ "$minor" -eq 10 ] && [ "$patch" -lt 3 ]; }; then
        die "OpenWrt $ver not supported (need 24.10.3+)"
    fi

    log "OpenWrt $ver OK"
}

# --- Check device type ---
check_device() {
    local board model
    board=$(cat /tmp/sysinfo/board_name 2>/dev/null) || true
    model=$(cat /tmp/sysinfo/model 2>/dev/null) || true

    case "$board$model" in
        *[Rr]outerich*|*routerich*)
            IS_ROUTERICH=1
            log "Device: $model (Routerich)"
            ;;
        *)
            IS_ROUTERICH=0
            log "Device: ${model:-$board}"
            ;;
    esac
}

# --- Install zapret2 (remove youtubeUnblock if present) ---
install_zapret2() {
    if opkg list-installed 2>/dev/null | grep -q '^zapret2 '; then
        log "zapret2 already installed"
        return
    fi

    # Remove youtubeUnblock if installed (main package first, then luci-app)
    if opkg list-installed 2>/dev/null | grep -q '^youtubeUnblock '; then
        log "Removing youtubeUnblock..."
        if [ -x /etc/init.d/youtubeUnblock ]; then
            /etc/init.d/youtubeUnblock stop 2>/dev/null || true
            /etc/init.d/youtubeUnblock disable 2>/dev/null || true
        fi
        opkg remove youtubeUnblock || true
    fi
    if opkg list-installed 2>/dev/null | grep -q '^luci-app-youtubeUnblock '; then
        log "Removing luci-app-youtubeUnblock..."
        opkg remove luci-app-youtubeUnblock || true
    fi

    log "Installing zapret2..."
    opkg install zapret2 || die "Failed to install zapret2"

    log "Installing luci-app-zapret2..."
    opkg install luci-app-zapret2 || die "Failed to install luci-app-zapret2"
}

# --- Install zeroblock ---
install_zeroblock() {
    if opkg list-installed 2>/dev/null | grep -q '^zeroblock '; then
        ZEROBLOCK_WAS_INSTALLED=1
        log "zeroblock already installed"
    fi

    log "Installing zeroblock..."
    opkg install zeroblock || die "Failed to install zeroblock"

    log "Installing luci-app-zeroblock..."
    opkg install luci-app-zeroblock || die "Failed to install luci-app-zeroblock"
}

# --- Existing install gate: unsuppress missing auto-template sections ---
clear_missing_auto_template_suppressions() {
    [ "$ZEROBLOCK_WAS_INSTALLED" = 1 ] || return 0

    local cleared=0

    if ! uci -q get zeroblock.awg10 >/dev/null 2>&1; then
        if [ "$(uci -q get zeroblock.auto_config.awg10_suppressed 2>/dev/null)" = "1" ]; then
            log "Existing ZeroBlock install: awg10 missing, clearing awg10_suppressed"
            uci -q delete zeroblock.auto_config.awg10_suppressed
            cleared=1
        fi
    fi

    if ! uci -q get zeroblock.opera >/dev/null 2>&1; then
        if [ "$(uci -q get zeroblock.auto_config.opera_suppressed 2>/dev/null)" = "1" ]; then
            log "Existing ZeroBlock install: opera missing, clearing opera_suppressed"
            uci -q delete zeroblock.auto_config.opera_suppressed
            cleared=1
        fi
    fi

    if [ "$cleared" = 1 ]; then
        log "Existing ZeroBlock install: missing auto-template section(s) unsuppressed before reload"
    fi
}

# --- Configure (Routerich only) ---
configure_routerich() {
    log "Configuring auto-install flags..."
    uci -q set zeroblock.auto_config=auto_config
    uci -q set zeroblock.auto_config.awg_auto_config='1'
    uci -q set zeroblock.auto_config.opera_auto_config='1'
    clear_missing_auto_template_suppressions
    uci commit zeroblock

    log "Triggering auto-install reload..."
    if ! ubus call zeroblock reload '{"scope":"auto_install"}' >/dev/null 2>&1; then
        log "Warning: ubus auto_install reload failed, falling back to init.d reload"
        /etc/init.d/zeroblock reload
    fi
}

# --- YouTube DPI check: first OK stops, only FAIL continues ---
dpi_check() {
    log "YouTube CDN DPI check (up to $DPI_RUNS attempts, ${DPI_PAUSE}s pause)"
    echo ""

    # Default: blocked
    echo "0" > "$YOUTUBE_RESULT"

    local i=1
    while [ "$i" -le "$DPI_RUNS" ]; do
        local result bytes http_code mb

        result=$(curl -s -L --connect-to ::google.com: \
            -H "Host: mirror.gcr.io" \
            --max-time "$DPI_TIMEOUT" --connect-timeout "$DPI_CONNECT_TIMEOUT" \
            -o /dev/null -w '%{size_download} %{http_code}' \
            "$DPI_URL" 2>/dev/null) || true

        bytes=$(echo "$result" | awk '{print int($1)}')
        http_code=$(echo "$result" | awk '{print $2}')
        bytes="${bytes:-0}"
        mb=$(awk "BEGIN {printf \"%.1f\", ${bytes}/1048576}")

        if [ "$bytes" -ge "$DPI_THRESHOLD" ]; then
            printf "  %2d/%d  OK       %s MB  HTTP %s\n" "$i" "$DPI_RUNS" "$mb" "$http_code"
            echo ""
            log "YouTube accessible without proxy"
            echo "1" > "$YOUTUBE_RESULT"
            return
        elif [ "$bytes" -gt 0 ]; then
            printf "  %2d/%d  SLOW     %s MB  HTTP %s\n" "$i" "$DPI_RUNS" "$mb" "$http_code"
        else
            printf "  %2d/%d  BLOCKED  %s MB  HTTP %s\n" "$i" "$DPI_RUNS" "$mb" "$http_code"
        fi

        if [ "$i" -lt "$DPI_RUNS" ]; then sleep "$DPI_PAUSE"; fi
        i=$((i + 1))
    done

    echo ""
    log "YouTube blocked by DPI (all $DPI_RUNS attempts failed)"
}

# --- Wait for UCI section to appear (created by auto_config) ---
wait_for_section() {
    local section="$1"
    local elapsed=0

    log "Waiting for section '$section' (up to ${AWG10_WAIT_TIMEOUT}s)..."
    while [ "$elapsed" -lt "$AWG10_WAIT_TIMEOUT" ]; do
        if uci -q get "zeroblock.$section" >/dev/null 2>&1; then
            log "Section '$section' ready (${elapsed}s)"
            return 0
        fi
        sleep "$AWG10_WAIT_INTERVAL"
        elapsed=$((elapsed + AWG10_WAIT_INTERVAL))
    done

    log "Warning: section '$section' not found after ${AWG10_WAIT_TIMEOUT}s"
    return 1
}

# --- Remove youtube from awg10 lists if accessible ---
apply_youtube_result() {
    local yt_accessible
    yt_accessible=$(cat "$YOUTUBE_RESULT" 2>/dev/null)
    rm -f "$YOUTUBE_RESULT"

    if [ "$yt_accessible" = "1" ]; then
        log "Removing youtube from awg10 section..."

        # Remove 'youtube' from community_lists
        local lists
        lists=$(uci -q get zeroblock.awg10.community_lists 2>/dev/null) || true
        if echo "$lists" | grep -q 'youtube'; then
            uci -q delete zeroblock.awg10.community_lists
            for item in $lists; do
                [ "$item" = "youtube" ] && continue
                uci -q add_list zeroblock.awg10.community_lists="$item"
            done
        fi

        # Remove 'youtube' from server_community_lists
        lists=$(uci -q get zeroblock.awg10.server_community_lists 2>/dev/null) || true
        if echo "$lists" | grep -q 'youtube'; then
            uci -q delete zeroblock.awg10.server_community_lists
            for item in $lists; do
                [ "$item" = "youtube" ] && continue
                uci -q add_list zeroblock.awg10.server_community_lists="$item"
            done
        fi

        # Remove youtube/googlevideo from excluded_domains_text
        lists=$(uci -q get zeroblock.awg10.excluded_domains_text 2>/dev/null) || true
        if echo "$lists" | grep -q 'youtube\|googlevideo'; then
            uci -q delete zeroblock.awg10.excluded_domains_text
            for item in $lists; do
                case "$item" in
                    *youtube*|*googlevideo*) continue ;;
                esac
                uci -q add_list zeroblock.awg10.excluded_domains_text="$item"
            done
        fi

        uci commit zeroblock
        log "YouTube lists removed from awg10, restarting..."
        /etc/init.d/zeroblock reload
    else
        # If zeroblock already running — add youtube to awg10
        if uci -q get zeroblock.awg10 >/dev/null 2>&1; then
            local has_yt
            has_yt=$(uci -q get zeroblock.awg10.community_lists 2>/dev/null) || true
            if ! echo "$has_yt" | grep -q 'youtube'; then
                log "Adding youtube to awg10 section..."
                uci -q add_list zeroblock.awg10.community_lists='youtube'
                uci -q add_list zeroblock.awg10.server_community_lists='youtube'
                uci commit zeroblock
                log "YouTube lists added to awg10, restarting..."
                /etc/init.d/zeroblock reload
            else
                log "YouTube blocked — youtube already in awg10 lists"
            fi
        else
            log "YouTube blocked — keeping youtube in awg10 lists"
        fi
    fi
}

# --- Main (all output tee'd to log) ---
main() {
    echo "=== ZeroBlock install: $(date) ==="
    check_version
    check_device

    # Stop zeroblock before DPI check (otherwise traffic goes through proxy)
    if [ -x /etc/init.d/zeroblock ]; then
        /etc/init.d/zeroblock stop 2>/dev/null || true
    fi

    stop_zapret2_if_present

    # podkop installs competing nftables rules that clash with zeroblock's
    # tproxy/mark scheme. Stop + disable before touching feeds to avoid
    # it interfering with opkg network traffic.
    if [ -x /etc/init.d/podkop ]; then
        log "Stopping and disabling podkop (conflicts with zeroblock)..."
        /etc/init.d/podkop stop 2>/dev/null || true
        /etc/init.d/podkop disable 2>/dev/null || true
    fi

    log "Updating package lists..."
    opkg update || { log "Warning: opkg update had errors (continuing)"; true; }
    install_zapret2
    ensure_zapret2_running || log "Continuing without running zapret2..."
    install_zeroblock

    if [ "$IS_ROUTERICH" = 1 ]; then
        if ensure_zapret2_running; then
            dpi_check
        else
            log "Skipping DPI check because nfqws2 is not running"
        fi
        configure_routerich
        wait_for_section awg10 || true
        apply_youtube_result
    fi

    echo ""
    echo "========================================"
    echo "  ZeroBlock installed successfully!"
    echo "  Need re-login to LuCI."
    echo "========================================"
    echo ""
    sleep 5
    /etc/init.d/rpcd restart
}

FIFO="/tmp/.zb_install_fifo.$$"
cleanup() {
    rm -f "$FIFO" "$YOUTUBE_RESULT"
    if [ "${TEE_PID:-}" ]; then wait "$TEE_PID" 2>/dev/null; fi
}
trap cleanup EXIT

mkfifo "$FIFO"
tee "$LOGFILE" < "$FIFO" &
TEE_PID=$!
main > "$FIFO" 2>&1
