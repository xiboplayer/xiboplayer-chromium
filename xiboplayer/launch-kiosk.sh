#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2024-2026 Pau Aliagas <linuxnow@gmail.com>
# =============================================================================
# xiboplayer — Self-contained Chromium Kiosk
#
# Starts a local Node.js server that serves the bundled PWA player and proxies
# CMS API requests, then launches Chromium in kiosk mode pointing at localhost.
#
# The PWA player files and server are bundled in the RPM — no external PWA
# server is needed. The PWA setup page handles CMS registration on first run.
# =============================================================================

set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/xiboplayer/chromium"
CONFIG_FILE="${CONFIG_DIR}/config.json"
LOCK_FILE="/tmp/xiboplayer-kiosk.lock"
SERVER_PID_FILE="/tmp/xiboplayer-server.pid"

# Installed paths (RPM/DEB layout)
SERVER_DIR="/usr/libexec/xiboplayer-chromium/server"

# Server defaults (overridden by config.json "serverPort" or --port=XXXX)
SERVER_PORT=8766

# ---------------------------------------------------------------------------
# Defaults (overridden by config.json)
# ---------------------------------------------------------------------------
BROWSER="chromium"
EXTRA_BROWSER_FLAGS=""
KIOSK_MODE="true"
FULLSCREEN="true"
HIDE_MOUSE_CURSOR="true"
PREVENT_SLEEP="true"
WINDOW_WIDTH="1920"
WINDOW_HEIGHT="1080"

# ---------------------------------------------------------------------------
# Load configuration (JSON via jq)
# ---------------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
    echo "[xiboplayer] ERROR: jq is required. Install: sudo dnf install jq" >&2
    exit 1
fi

# Read a JSON key from config, setting the named shell variable if present.
cfg_read() {
    local varname="$1" key="$2" file="$3"
    local val
    # `// empty` treats an explicit false (and null) as absent, so a documented opt-out such
    # as "relaxSslCerts": false could never turn a default of true off. Read presence, not truth.
    val=$(jq -r --arg k "$key" 'if has($k) and .[$k] != null then .[$k] else empty end' "$file" 2>/dev/null) || true
    [[ -n "$val" ]] && printf -v "$varname" '%s' "$val" || true
}

load_config() {
    local file="$1"
    cfg_read BROWSER            browser            "$file"
    cfg_read EXTRA_BROWSER_FLAGS extraBrowserFlags  "$file"
    cfg_read SERVER_PORT        serverPort         "$file"
    cfg_read GOOGLE_GEO_API_KEY googleGeoApiKey    "$file"
    cfg_read KIOSK_MODE         kioskMode          "$file"
    cfg_read FULLSCREEN         fullscreen         "$file"
    cfg_read HIDE_MOUSE_CURSOR  hideMouseCursor    "$file"
    cfg_read PREVENT_SLEEP      preventSleep       "$file"
    cfg_read WINDOW_WIDTH       width              "$file"
    cfg_read WINDOW_HEIGHT      height             "$file"
    cfg_read LOG_LEVEL          logLevel           "$file"
    cfg_read RELAX_SSL_CERTS    relaxSslCerts      "$file"
    cfg_read GPU_PREFERENCE     gpu                "$file"
}

if [[ -f "$CONFIG_FILE" ]]; then
    load_config "$CONFIG_FILE"
else
    # First run — create config directory (PWA setup page handles CMS registration)
    mkdir -p "$CONFIG_DIR"
    if [[ -f /usr/share/xiboplayer-chromium/config.json ]]; then
        cp /usr/share/xiboplayer-chromium/config.json "$CONFIG_FILE"
        echo "[xiboplayer] Created default config at $CONFIG_FILE" >&2
    fi
fi

# CLI overrides
INSTANCE=""
for arg in "$@"; do
    case "$arg" in
        --port=*) SERVER_PORT="${arg#*=}" ;;
        --instance=*) INSTANCE="${arg#*=}" ;;
        --server-dir=*) SERVER_DIR="${arg#*=}" ;;
        --pwa-path=*) PWA_PATH="${arg#*=}" ;;
        --no-kiosk) KIOSK_MODE="false" ;;
        --log-level=*) LOG_LEVEL="${arg#*=}" ;;
        --gpu=*) GPU_PREFERENCE="${arg#*=}" ;;
    esac
done

# Multi-instance support: --instance=NAME isolates config, data, lock, and PID
if [[ -n "$INSTANCE" ]]; then
    CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/xiboplayer/chromium-${INSTANCE}"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    LOCK_FILE="/tmp/xiboplayer-kiosk-${INSTANCE}.lock"
    SERVER_PID_FILE="/tmp/xiboplayer-server-${INSTANCE}.pid"
    # Re-read config from the instance-specific path
    if [[ -f "$CONFIG_FILE" ]]; then
        load_config "$CONFIG_FILE"
    else
        mkdir -p "$CONFIG_DIR"
    fi
fi
PLAYER_URL="http://localhost:${SERVER_PORT}/player/"
[[ -n "${LOG_LEVEL:-}" ]] && PLAYER_URL="${PLAYER_URL}?logLevel=${LOG_LEVEL}"

# No cmsUrl in config.json → unconfigured. Wipe stale browser data so
# the PWA shows the setup screen instead of booting from ghost config.
DATA_SUFFIX="chromium"
[[ -n "$INSTANCE" ]] && DATA_SUFFIX="chromium-${INSTANCE}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/xiboplayer/${DATA_SUFFIX}"
CMS_URL=$(jq -r '.cmsUrl // empty' "$CONFIG_FILE" 2>/dev/null) || true
if [[ -z "$CMS_URL" && -d "$DATA_DIR" ]]; then
    rm -rf "$DATA_DIR/Default/Local Storage" \
           "$DATA_DIR/Default/IndexedDB" \
           "$DATA_DIR/Default/Service Worker" \
           "$DATA_DIR/Default/Cache" \
           "$DATA_DIR/Default/Code Cache" 2>/dev/null || true
    echo "[xiboplayer] Unconfigured — cleared stale browser data" >&2
fi

# ---------------------------------------------------------------------------
# Locking — prevent duplicate instances
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    # Disable trap to prevent re-entry when killing process group
    trap - EXIT INT TERM HUP
    echo "[xiboplayer] Shutting down (exit code: $exit_code)..." >&2
    # Stop the local server
    if [[ -f "$SERVER_PID_FILE" ]]; then
        local srv_pid
        srv_pid=$(cat "$SERVER_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$srv_pid" ]] && kill -0 "$srv_pid" 2>/dev/null; then
            kill "$srv_pid" 2>/dev/null || true
            echo "[xiboplayer] Stopped local server (PID $srv_pid)." >&2
        fi
        rm -f "$SERVER_PID_FILE"
    fi
    rm -f "$LOCK_FILE"
    # Kill unclutter if we started it
    [[ -n "${UNCLUTTER_PID:-}" ]] && kill "$UNCLUTTER_PID" 2>/dev/null || true
    restore_screen_blanking
    # Kill any child processes in our process group
    kill -- -$$ 2>/dev/null || true
    exit "$exit_code"
}

if [[ -f "$LOCK_FILE" ]]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[xiboplayer] Already running (PID $OLD_PID). Exiting." >&2
        exit 1
    fi
    echo "[xiboplayer] Stale lock file found, removing." >&2
    rm -f "$LOCK_FILE"
fi

echo $$ > "$LOCK_FILE"
trap cleanup EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# Disable screen blanking / DPMS
# ---------------------------------------------------------------------------
disable_screen_blanking() {
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        if command -v gsettings &>/dev/null; then
            gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
            gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
            gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null || true
            echo "[xiboplayer] Disabled GNOME screen blanking (Wayland)." >&2
        fi
        if command -v kwriteconfig5 &>/dev/null; then
            kwriteconfig5 --file powermanagementprofilesrc \
                --group AC --group DPMSControl --key idleTime 0 2>/dev/null || true
            echo "[xiboplayer] Disabled KDE screen blanking (Wayland)." >&2
        fi
    fi

    if [[ -n "${DISPLAY:-}" ]]; then
        if command -v xset &>/dev/null; then
            xset s off 2>/dev/null || true
            xset s noblank 2>/dev/null || true
            xset -dpms 2>/dev/null || true
            echo "[xiboplayer] Disabled X11 screen blanking (xset)." >&2
        fi
    fi
}

restore_screen_blanking() {
    if [[ -n "${DISPLAY:-}" ]] && command -v xset &>/dev/null; then
        xset +dpms 2>/dev/null || true
        xset s on 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Resolve browser binary
# ---------------------------------------------------------------------------
resolve_browser() {
    local browser_lower
    browser_lower=$(echo "$BROWSER" | tr '[:upper:]' '[:lower:]')

    case "$browser_lower" in
        chromium|chromium-browser)
            for bin in chromium-browser chromium; do
                if command -v "$bin" &>/dev/null; then
                    echo "$bin"
                    return
                fi
            done
            # Fallback: config says chromium but only chrome is installed
            for bin in google-chrome-stable google-chrome; do
                if command -v "$bin" &>/dev/null; then
                    echo "$bin"
                    return
                fi
            done
            ;;
        chrome|google-chrome|google-chrome-stable)
            for bin in google-chrome-stable google-chrome chrome; do
                if command -v "$bin" &>/dev/null; then
                    echo "$bin"
                    return
                fi
            done
            ;;
        *)
            if command -v "$browser_lower" &>/dev/null; then
                echo "$browser_lower"
                return
            fi
            ;;
    esac

    echo ""
}

# ---------------------------------------------------------------------------
# Start local server
# ---------------------------------------------------------------------------
start_server() {
    if ! command -v node &>/dev/null; then
        echo "[xiboplayer] ERROR: Node.js is required. Install: sudo dnf install nodejs" >&2
        exit 1
    fi

    local server_args=(--port="$SERVER_PORT")
    [[ -n "${PWA_PATH:-}" ]] && server_args+=(--pwa-path="$PWA_PATH")
    [[ -n "${INSTANCE:-}" ]] && server_args+=(--instance="$INSTANCE")

    echo "[xiboplayer] Starting local server on port $SERVER_PORT..." >&2
    node "$SERVER_DIR/server.js" "${server_args[@]}" &
    local srv_pid=$!
    echo "$srv_pid" > "$SERVER_PID_FILE"

    # Wait for server to be ready (up to 10 seconds)
    local retries=0
    while (( retries < 50 )); do
        if curl -s -o /dev/null "http://localhost:${SERVER_PORT}/" 2>/dev/null; then
            echo "[xiboplayer] Server ready (PID $srv_pid)." >&2
            return 0
        fi
        # Check if server process died
        if ! kill -0 "$srv_pid" 2>/dev/null; then
            echo "[xiboplayer] ERROR: Server process died." >&2
            return 1
        fi
        sleep 0.2
        retries=$((retries + 1))
    done

    echo "[xiboplayer] ERROR: Server did not start within 10 seconds." >&2
    kill "$srv_pid" 2>/dev/null || true
    return 1
}

# ---------------------------------------------------------------------------
# GPU Detection & Selection
# Scans /sys/class/drm for GPUs, ranks discrete > integrated.
# Override: --gpu=nvidia|intel|amd|auto|/dev/dri/renderDNNN, config.gpu, XIBO_GPU
# ---------------------------------------------------------------------------
detect_and_select_gpu() {
    local pref="${GPU_PREFERENCE:-${XIBO_GPU:-auto}}"
    local -a gpu_names=() gpu_vendors=() gpu_render_nodes=() gpu_ranks=() gpu_va_drivers=() gpu_has_display=() gpu_is_virtual=()
    local best_idx=-1 best_rank=-99

    for card_dir in /sys/class/drm/card[0-9]*; do
        [[ -d "$card_dir/device" ]] || continue
        local card_name vendor device driver render_node card_realpath has_display
        card_name=$(basename "$card_dir")
        vendor=$(cat "$card_dir/device/vendor" 2>/dev/null) || continue
        device=$(cat "$card_dir/device/device" 2>/dev/null) || continue
        driver=$(basename "$(readlink "$card_dir/device/driver" 2>/dev/null)" 2>/dev/null) || driver="unknown"
        card_realpath=$(readlink -f "$card_dir/device")

        # Find the render node for this card
        render_node=""
        for rn_dir in /sys/class/drm/renderD*; do
            local rn_realpath
            rn_realpath=$(readlink -f "$rn_dir/device" 2>/dev/null) || continue
            if [[ "$rn_realpath" == "$card_realpath" ]]; then
                render_node="/dev/dri/$(basename "$rn_dir")"
                break
            fi
        done
        [[ -z "$render_node" ]] && continue

        # Check if this card has display connectors (DP, HDMI, eDP, VGA, etc.)
        has_display="false"
        for conn in /sys/class/drm/${card_name}-*; do
            if [[ "$(basename "$conn")" =~ -(DP|HDMI|eDP|VGA|DVI|DSI|LVDS) ]]; then
                has_display="true"
                break
            fi
        done

        local name rank va_driver is_virtual
        case "$vendor" in
            0x10de) name="nvidia";  rank=3;  va_driver="nvidia";   is_virtual=false ;;
            0x1002) name="amd";     rank=2;  va_driver="radeonsi"; is_virtual=false ;;
            0x8086) name="intel";   rank=1;  va_driver="iHD";      is_virtual=false ;;
            # Virtual GPUs — GNOME Boxes / libvirt / QEMU defaults.
            # Detection finds these (they expose a DRM render node) but
            # hardware-accelerated Chromium ops fail at runtime with
            # EACCES on DRM_IOCTL_MODE_CREATE_DUMB when the host doesn't
            # provide virglrenderer. Rank -1 so a real GPU always wins
            # when both present (rare — GPU passthrough to a VM uses the
            # real vendor ID). On a pure-virtual setup we still select
            # this GPU but skip --render-node-override and force
            # software rendering so Chromium uses SwiftShader/CPU.
            0x1af4) name="virtio";  rank=-1; va_driver="";         is_virtual=true  ;;  # Red Hat/Qumranet virtio-gpu
            0x1234) name="qemu";    rank=-1; va_driver="";         is_virtual=true  ;;  # QEMU Bochs VBE (-vga std)
            0x15ad) name="vmware";  rank=-1; va_driver="";         is_virtual=true  ;;  # VMware SVGA II
            *)      name="unknown"; rank=0;  va_driver="";         is_virtual=false ;;
        esac

        local idx=${#gpu_names[@]}
        gpu_names+=("$name")
        gpu_vendors+=("$vendor")
        gpu_render_nodes+=("$render_node")
        gpu_ranks+=("$rank")
        gpu_va_drivers+=("$va_driver")
        gpu_has_display+=("$has_display")
        gpu_is_virtual+=("$is_virtual")
        local display_tag="render-only"
        [[ "$has_display" == "true" ]] && display_tag="display"
        local virtual_tag=""
        [[ "$is_virtual" == "true" ]] && virtual_tag=", virtual"
        echo "[xiboplayer]   GPU:     ${name} ${device} (${driver}) → ${render_node} (${display_tag}${virtual_tag})" >&2
    done

    if (( ${#gpu_names[@]} == 0 )); then
        echo "[xiboplayer]   GPU:     none detected, using Chromium defaults" >&2
        return
    fi

    # Select GPU
    local selected_idx=-1
    if [[ "$pref" == "auto" ]]; then
        # On hybrid GPU (Optimus/PRIME), discrete can't share buffers with
        # display GPU on Wayland. Prefer the GPU with display connectors.
        local has_display_gpu="false" has_renderonly_gpu="false"
        for i in "${!gpu_has_display[@]}"; do
            [[ "${gpu_has_display[i]}" == "true" ]] && has_display_gpu="true"
            [[ "${gpu_has_display[i]}" == "false" ]] && has_renderonly_gpu="true"
        done
        if [[ "$has_display_gpu" == "true" && "$has_renderonly_gpu" == "true" ]]; then
            # Hybrid system: pick highest-ranked display GPU
            for i in "${!gpu_ranks[@]}"; do
                if [[ "${gpu_has_display[i]}" == "true" ]] && (( gpu_ranks[i] > best_rank )); then
                    best_rank=${gpu_ranks[i]}
                    selected_idx=$i
                fi
            done
        else
            # Single GPU or all have displays: pick highest rank
            for i in "${!gpu_ranks[@]}"; do
                if (( gpu_ranks[i] > best_rank )); then
                    best_rank=${gpu_ranks[i]}
                    selected_idx=$i
                fi
            done
        fi
    elif [[ "$pref" == /dev/dri/* ]]; then
        for i in "${!gpu_render_nodes[@]}"; do
            [[ "${gpu_render_nodes[i]}" == "$pref" ]] && selected_idx=$i && break
        done
    else
        for i in "${!gpu_names[@]}"; do
            [[ "${gpu_names[i]}" == "${pref,,}" ]] && selected_idx=$i && break
        done
    fi

    if (( selected_idx < 0 )); then
        echo "[xiboplayer]   GPU:     requested '${pref}' not found, using Chromium defaults" >&2
        return
    fi

    SELECTED_GPU_VA_DRIVER="${gpu_va_drivers[selected_idx]}"
    SELECTED_GPU_IS_VIRTUAL="${gpu_is_virtual[selected_idx]}"

    # On a virtual GPU the render-node-override propagates a device
    # that supports DRM but not usable hardware acceleration — Chromium
    # then crashes with EACCES on MODE_CREATE_DUMB. Skip the override
    # so Chromium falls back to software rendering (SwiftShader).
    # Respect XIBOPLAYER_FORCE_GPU=1 for operators who have a working
    # virgl pipeline and want to opt back in.
    if [[ "$SELECTED_GPU_IS_VIRTUAL" == "true" && "${XIBOPLAYER_FORCE_GPU:-0}" != "1" ]]; then
        SELECTED_GPU_RENDER_NODE=""
        echo "[xiboplayer]   GPU:     selected ${gpu_names[selected_idx]} (virtual) → software rendering" >&2
    else
        SELECTED_GPU_RENDER_NODE="${gpu_render_nodes[selected_idx]}"
        echo "[xiboplayer]   GPU:     selected ${gpu_names[selected_idx]} → ${SELECTED_GPU_RENDER_NODE} (pref: ${pref})" >&2
    fi

    if [[ -n "$SELECTED_GPU_VA_DRIVER" ]]; then
        export LIBVA_DRIVER_NAME="$SELECTED_GPU_VA_DRIVER"
        echo "[xiboplayer]   GPU:     VA-API driver: ${SELECTED_GPU_VA_DRIVER}" >&2
    fi
}

# ---------------------------------------------------------------------------
# Build Chromium arguments
# ---------------------------------------------------------------------------
build_chromium_args() {
    BROWSER_ARGS=(
        --no-first-run
        --disable-translate
        --disable-infobars
        --disable-suggestions-service
        --disable-save-password-bubble
        --disable-session-crashed-bubble
        --disable-component-update
        --noerrdialogs
        --disable-pinch
        --overscroll-history-navigation=0
        --autoplay-policy=no-user-gesture-required
        --check-for-update-interval=31536000
        --disable-features=TranslateUI,Translate,SpareRendererForSitePerProcess
        --disable-extensions
        --disable-ipc-flooding-protection
        --password-store=basic
        --lang=en-US
        "--auto-select-desktop-capture-source=Entire screen"
        --auto-accept-this-tab-capture
        # Larger tiles = fewer raster jobs for fullscreen signage content
        --default-tile-width=512
        --default-tile-height=512
        # Single-origin signage: limit to 1 renderer (default spawns per-frame)
        --renderer-process-limit=1
        # Prevent GPU crash and renderer freeze when screen is locked/off
        --disable-gpu-watchdog
        --disable-gpu-process-crash-limit
        --disable-background-timer-throttling
        --disable-renderer-backgrounding
        # Strip unnecessary Chrome services to reduce memory/CPU (~50-80 MB savings)
        --disable-background-networking
        --disable-client-side-phishing-detection
        --disable-default-apps
        --disable-hang-monitor
        --disable-popup-blocking
        --disable-prompt-on-repost
        --disable-sync
        --disable-domain-reliability
        --no-pings
        --disable-breakpad
        --metrics-recording-only
    )

    # GPU acceleration — split by whether a usable hardware GPU is present.
    # detect_and_select_gpu() sets SELECTED_GPU_IS_VIRTUAL=true for
    # virtio-gpu / QEMU Bochs / VMware SVGA. On those, enabling GPU raster
    # / zero-copy / ignoring blocklist causes Chromium's GPU process to
    # call DRM_IOCTL_MODE_CREATE_DUMB → EACCES → crash loop (4000+ retries).
    # On a real GPU these same flags give real acceleration. Override via
    # XIBOPLAYER_FORCE_GPU=1 for users with working virgl who want to opt in.
    if [[ "${SELECTED_GPU_IS_VIRTUAL:-false}" == "true" && "${XIBOPLAYER_FORCE_GPU:-0}" != "1" ]]; then
        BROWSER_ARGS+=(
            --disable-gpu
            --disable-gpu-compositing
            --disable-gpu-rasterization
        )
    else
        BROWSER_ARGS+=(
            --ignore-gpu-blocklist
            --enable-gpu-rasterization
            --enable-zero-copy
            --enable-features=CanvasOopRasterization
        )
    fi

    # Kiosk / fullscreen / window size
    if [[ "$KIOSK_MODE" == "true" ]]; then
        BROWSER_ARGS=(--kiosk "${BROWSER_ARGS[@]}")
    else
        [[ "$FULLSCREEN" == "true" ]] && BROWSER_ARGS+=(--start-fullscreen)
        BROWSER_ARGS+=(--window-size="${WINDOW_WIDTH},${WINDOW_HEIGHT}")
    fi

    # XDG-compliant profile directory (instance-aware)
    BROWSER_ARGS+=(--user-data-dir="$DATA_DIR")

    # Accept invalid SSL certificates for media/stream URLs (default: true)
    # Self-signed certs on media streams are common in signage deployments.
    # Set "relaxSslCerts": false in config.json to enforce strict SSL.
    if [[ "${RELAX_SSL_CERTS:-true}" == "true" ]]; then
        BROWSER_ARGS+=(--ignore-certificate-errors --test-type)
        echo "[xiboplayer]   SSL:     relaxed (--ignore-certificate-errors)" >&2
    fi

    # Adaptive memory tuning based on device RAM and CPU count
    # Same tiers as Electron (main.js) and SW (calculateChunkConfig)
    local total_ram_kb total_ram_gb cpu_count max_old_space_mb raster_threads
    total_ram_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    total_ram_gb=$(( (total_ram_kb + 524288) / 1048576 ))  # round to nearest GB
    cpu_count=$(nproc 2>/dev/null || echo 2)

    if (( total_ram_gb <= 1 )); then
        max_old_space_mb=128; raster_threads=1
    elif (( total_ram_gb <= 2 )); then
        max_old_space_mb=192; raster_threads=2
    elif (( total_ram_gb <= 4 )); then
        max_old_space_mb=256; raster_threads=$(( cpu_count < 2 ? cpu_count : 2 ))
    elif (( total_ram_gb <= 8 )); then
        max_old_space_mb=512; raster_threads=$(( cpu_count < 4 ? cpu_count : 4 ))
    else
        max_old_space_mb=768; raster_threads=$(( cpu_count < 4 ? cpu_count : 4 ))
    fi

    BROWSER_ARGS+=(
        --js-flags="--max-old-space-size=${max_old_space_mb}"
        --num-raster-threads="$raster_threads"
        --gpu-rasterization-msaa-sample-count=0
    )
    echo "[xiboplayer]   Memory:  ${total_ram_gb}GB RAM, ${cpu_count} CPUs → V8 heap ${max_old_space_mb}MB, ${raster_threads} raster threads" >&2

    # GPU render node override (set by detect_and_select_gpu)
    if [[ -n "${SELECTED_GPU_RENDER_NODE:-}" ]]; then
        BROWSER_ARGS+=(--render-node-override="$SELECTED_GPU_RENDER_NODE")
    fi

    # Forward renderer console (console.log/info/warn/error) to stderr so
    # the launcher log captures it. Without this chromium only writes
    # renderer output to its own /tmp/chrome_debug.log — we'd be blind to
    # XMR / REST / screenshot activity from the PWA.
    # --v=1 promotes info-level messages; bump to --v=2 for more verbose.
    BROWSER_ARGS+=(
        --enable-logging=stderr
        --v=1
    )

    # Optional remote debugging port for monitoring (FPS, memory, tracing).
    # NOT enabled by default — set XIBOPLAYER_DEBUG_PORT=9222 to activate.
    # Security: binds to 127.0.0.1 only (local access).
    # Usage:
    #   systemctl --user set-environment XIBOPLAYER_DEBUG_PORT=9222
    #   systemctl --user restart xiboplayer-chromium
    #   # ... monitor via CDP at http://localhost:9222 ...
    #   systemctl --user unset-environment XIBOPLAYER_DEBUG_PORT
    #   systemctl --user restart xiboplayer-chromium
    if [[ -n "${XIBOPLAYER_DEBUG_PORT:-}" ]]; then
        BROWSER_ARGS+=(
            --remote-debugging-port="$XIBOPLAYER_DEBUG_PORT"
            --remote-debugging-address=127.0.0.1
        )
        echo "[xiboplayer]   Debug:   CDP on port $XIBOPLAYER_DEBUG_PORT (127.0.0.1 only)" >&2
    fi

    # Append any user-defined extra flags
    if [[ -n "$EXTRA_BROWSER_FLAGS" ]]; then
        local -a extra
        read -ra extra <<< "$EXTRA_BROWSER_FLAGS"
        BROWSER_ARGS+=("${extra[@]}")
    fi

    # URL must be last — point at local server, not remote CMS
    BROWSER_ARGS+=("$PLAYER_URL")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "[xiboplayer] Starting xiboplayer (self-contained)" >&2
    [[ -n "$INSTANCE" ]] && echo "[xiboplayer]   Instance: $INSTANCE" >&2
    echo "[xiboplayer]   Browser: $BROWSER" >&2
    echo "[xiboplayer]   Server:  http://localhost:$SERVER_PORT" >&2
    echo "[xiboplayer]   Kiosk:   $KIOSK_MODE  Fullscreen: $FULLSCREEN  Sleep: $PREVENT_SLEEP  Cursor: $([[ $HIDE_MOUSE_CURSOR == true ]] && echo hidden || echo visible)" >&2

    # Wait for display to be available (important for systemd startup)
    local retries=0
    while [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]] && (( retries < 30 )); do
        echo "[xiboplayer] Waiting for display server... (attempt $((retries+1))/30)" >&2
        sleep 2
        retries=$((retries + 1))
    done

    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        echo "[xiboplayer] ERROR: No display server available after 60 seconds." >&2
        exit 1
    fi

    # Disable screen blanking (if configured)
    if [[ "$PREVENT_SLEEP" == "true" ]]; then
        disable_screen_blanking
    fi

    # Hide mouse cursor (if configured)
    if [[ "$HIDE_MOUSE_CURSOR" == "true" ]]; then
        if command -v unclutter &>/dev/null; then
            unclutter --timeout 1 --jitter 2 --hide-on-touch &
            UNCLUTTER_PID=$!
            echo "[xiboplayer] Mouse cursor hidden (unclutter, PID $UNCLUTTER_PID)." >&2
        else
            echo "[xiboplayer] WARNING: unclutter not found, cursor will be visible." >&2
            echo "[xiboplayer]   Install: sudo dnf install unclutter" >&2
        fi
    fi

    # Start the local server (serves PWA + proxies CMS)
    start_server || exit 1

    # Resolve browser binary
    local browser_bin
    browser_bin=$(resolve_browser)
    if [[ -z "$browser_bin" ]]; then
        echo "[xiboplayer] ERROR: Browser '$BROWSER' not found." >&2
        echo "[xiboplayer]   Install: sudo dnf install chromium" >&2
        exit 1
    fi
    echo "[xiboplayer]   Binary:  $browser_bin" >&2

    # Create kiosk policies — write to both profile and system paths.
    # Chromium reads policies from /etc/chromium/policies/managed/ (system)
    # and $DATA_DIR/policies/managed/ (profile). Some versions only check one.
    mkdir -p "$DATA_DIR/policies/managed" 2>/dev/null || true
    for policy_dir in "$DATA_DIR/policies/managed" "/etc/chromium/policies/managed"; do
        mkdir -p "$policy_dir" 2>/dev/null || true
        cat > "$policy_dir/kiosk.json" 2>/dev/null << POLICY || true
{
  "TranslateEnabled": false,
  "AutoFillEnabled": false,
  "PasswordManagerEnabled": false,
  "SearchSuggestEnabled": false,
  "MetricsReportingEnabled": false,
  "SpellCheckServiceEnabled": false,
  "DownloadRestrictions": 3,
  "DefaultGeolocationSetting": 1,
  "DefaultNotificationsSetting": 2,
  "CredentialProviderPromoEnabled": false,
  "VideoCaptureAllowed": true,
  "AudioCaptureAllowed": true,
  "VideoCaptureAllowedUrls": ["http://localhost:${SERVER_PORT}"],
  "AudioCaptureAllowedUrls": ["http://localhost:${SERVER_PORT}"],
  "ScreenCaptureAllowed": true,
  "ScreenCaptureAllowedByOrigins": ["http://localhost:${SERVER_PORT}"],
  "TabCaptureAllowedByOrigins": ["http://localhost:${SERVER_PORT}"],
  "RestoreOnStartup": 4,
  "RestoreOnStartupURLs": []
}
POLICY
    done

    # Suppress "Chrome didn't shut down correctly" restore dialog.
    # Flags (--disable-session-crashed-bubble, --noerrdialogs) don't reliably
    # suppress the infobar. Patching the Preferences file on every launch does.
    local prefs_file="$DATA_DIR/Default/Preferences"
    if [[ -f "$prefs_file" ]]; then
        # Use sed to patch exit_type and exited_cleanly in-place
        sed -i 's/"exit_type":"[^"]*"/"exit_type":"Normal"/g; s/"exited_cleanly":false/"exited_cleanly":true/g' "$prefs_file"
    else
        # First run — create Preferences with geolocation auto-allowed
        mkdir -p "$DATA_DIR/Default"
        cat > "$prefs_file" << 'PREFS'
{
  "profile": {"exit_type": "Normal", "exited_cleanly": true, "content_settings": {"exceptions": {"geolocation": {"*,*": {"setting": 1}}}}}}
PREFS
    fi

    # Export Google Geolocation API key for the SDK (if configured)
    if [[ -n "${GOOGLE_GEO_API_KEY:-}" ]]; then
        export GOOGLE_GEO_API_KEY
        echo "[xiboplayer]   Geo API: configured" >&2
    fi

    # Detect and select GPU
    detect_and_select_gpu

    # Build arguments and launch
    build_chromium_args

    echo "[xiboplayer]   Args:    ${BROWSER_ARGS[*]}" >&2
    echo "[xiboplayer] Launching browser..." >&2

    # Execute the browser — this blocks until the browser exits.
    "$browser_bin" "${BROWSER_ARGS[@]}"
}

main "$@"
