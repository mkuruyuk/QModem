#!/bin/sh
# esim_ctrl.sh - eSIM/eUICC management integration for QModem
# Provides lpac operations with proper coordination to avoid MBIM conflicts
#
# Usage: esim_ctrl.sh <method> <config_section> [json_data]
#
# Methods:
#   chip_info       - Get eUICC EID (non-disruptive, safe while connected)
#   profile_list    - List eSIM profiles (non-disruptive)
#   profile_enable  - Enable/switch profile (disruptive - disconnects internet)
#   profile_disable - Disable profile (disruptive)
#   profile_download - Download new profile (needs internet, then reconnect)
#   profile_delete  - Delete profile (disruptive)
#   notification_list - List pending notifications (non-disruptive)
#   notification_process - Process notifications (needs internet)

source /usr/share/libubox/jshn.sh
source /lib/functions.sh
source /usr/share/qmodem/modem_util.sh

SCRIPT_DIR="/usr/share/qmodem"
MODEM_RUNDIR="/var/run/qmodem"
ESIM_LOCK="/tmp/lock/esim_operation"

method=$1
config_section=$2
json_data=$3
debug_subject="esim_ctrl"

# Load modem configuration
config_load qmodem
config_get at_port $config_section at_port
config_get manufacturer $config_section manufacturer
config_get platform $config_section platform
config_get modem_path $config_section path

# Determine MBIM device path for lpac
get_mbim_device() {
    local mbim_dev=""
    local wdm_name=""

    # Method 1: Search sysfs under modem path for usbmisc/cdc-wdm*
    if [ -n "$modem_path" ] && [ -d "$modem_path" ]; then
        wdm_name=$(find "$modem_path" -path "*/usbmisc/cdc-wdm*" -name "cdc-wdm*" 2>/dev/null | head -1)
        [ -n "$wdm_name" ] && wdm_name=$(basename "$wdm_name")
    fi

    # Method 2: Check UCI lpac config
    if [ -z "$wdm_name" ]; then
        local uci_dev=$(uci -q get lpac.mbim.device)
        if [ -n "$uci_dev" ] && [ -e "$uci_dev" ]; then
            echo "$uci_dev"
            return
        fi
    fi

    # Method 3: Find cdc-wdm device associated with the same USB parent
    if [ -z "$wdm_name" ]; then
        local net_dev=$(uci -q get qmodem.$config_section.network)
        if [ -n "$net_dev" ] && [ -d "/sys/class/net/$net_dev" ]; then
            local dev_path=$(readlink -f "/sys/class/net/$net_dev/device/")
            if [ -n "$dev_path" ]; then
                local parent_path=$(dirname "$dev_path")
                wdm_name=$(find "$parent_path" -path "*/usbmisc/cdc-wdm*" -name "cdc-wdm*" 2>/dev/null | head -1)
                [ -n "$wdm_name" ] && wdm_name=$(basename "$wdm_name")
            fi
        fi
    fi

    # Method 4: Fallback to /dev/cdc-wdm0
    if [ -n "$wdm_name" ] && [ -e "/dev/$wdm_name" ]; then
        echo "/dev/$wdm_name"
    else
        echo "/dev/cdc-wdm0"
    fi
}

# Check if lpac is installed and functional
check_lpac() {
    if [ ! -x /usr/bin/lpac ] && [ ! -x /usr/lib/lpac ]; then
        json_add_string "error" "lpac not installed. Install lpac package with MBIM support."
        json_add_string "status" "0"
        return 1
    fi
    # Check if libmbim is available (required for MBIM backend)
    if ! ls /usr/lib/libmbim-glib.so* >/dev/null 2>&1; then
        json_add_string "error" "libmbim not installed. Required for MBIM eSIM access."
        json_add_string "status" "0"
        return 1
    fi
    return 0
}

# Check if MBIM device exists and is accessible
check_mbim_device() {
    local mbim_dev=$(get_mbim_device)
    if [ ! -e "$mbim_dev" ]; then
        json_add_string "error" "MBIM device $mbim_dev not found"
        json_add_string "status" "0"
        return 1
    fi
    if [ ! -r "$mbim_dev" ] || [ ! -w "$mbim_dev" ]; then
        json_add_string "error" "MBIM device $mbim_dev not accessible (permission denied)"
        json_add_string "status" "0"
        return 1
    fi
    return 0
}

# Acquire exclusive lock for eSIM operations to prevent concurrent access
acquire_esim_lock() {
    mkdir -p /tmp/lock
    # Check for stale lock (older than 5 minutes = 300 seconds)
    if [ -f "$ESIM_LOCK" ]; then
        local file_time=""
        # Use find -mmin for portable stale detection (works on all BusyBox)
        local stale=$(find "$ESIM_LOCK" -mmin +5 2>/dev/null)
        if [ -n "$stale" ]; then
            m_debug "removing stale eSIM lock (older than 5 minutes)"
            lock -u "$ESIM_LOCK"
            rm -f "$ESIM_LOCK"
        fi
    fi
    lock -n "$ESIM_LOCK"
    if [ $? -ne 0 ]; then
        json_add_string "error" "Another eSIM operation is in progress"
        json_add_string "status" "0"
        return 1
    fi
    return 0
}

release_esim_lock() {
    lock -u "$ESIM_LOCK"
}

# Setup lpac environment variables
setup_lpac_env() {
    local mbim_dev=$(get_mbim_device)
    local use_proxy=$(uci -q get lpac.mbim.proxy)
    local skip_slot=$(uci -q get lpac.mbim.skip_slot_mapping)
    local custom_aid=$(uci -q get lpac.global.custom_isd_r_aid)

    export LPAC_APDU="mbim"
    export LPAC_HTTP="curl"
    export LPAC_APDU_MBIM_DEVICE="$mbim_dev"
    export LPAC_APDU_MBIM_USE_PROXY="${use_proxy:-1}"
    export LPAC_APDU_MBIM_SKIP_SLOT_MAPPING="${skip_slot:-1}"
    [ -n "$custom_aid" ] && export LPAC_CUSTOM_ISD_R_AID="$custom_aid"
}

# Ensure mbim-proxy is running (needed for shared access)
ensure_mbim_proxy() {
    # Only needed if proxy mode is enabled
    local use_proxy=$(uci -q get lpac.mbim.proxy)
    [ "$use_proxy" != "1" ] && return 0

    # Check if mbim-proxy is already running
    if pidof mbim-proxy >/dev/null 2>&1; then
        return 0
    fi

    # Preferred path: ask the procd service. It is started before
    # qmodem_network at boot, so this is mostly a safety net for the
    # case where the user disabled it manually.
    if [ -x /etc/init.d/mbim-proxy ]; then
        /etc/init.d/mbim-proxy start >/dev/null 2>&1
        local i=0
        while [ $i -lt 5 ]; do
            pidof mbim-proxy >/dev/null 2>&1 && return 0
            sleep 1
            i=$((i + 1))
        done
    fi

    # Last-resort manual fallback (no procd unit available).
    local proxy_bin=""
    if [ -x /usr/libexec/mbim-proxy ]; then
        proxy_bin="/usr/libexec/mbim-proxy"
    elif [ -x /usr/lib/mbim-proxy ]; then
        proxy_bin="/usr/lib/mbim-proxy"
    elif [ -x /usr/bin/mbim-proxy ]; then
        proxy_bin="/usr/bin/mbim-proxy"
    fi

    if [ -z "$proxy_bin" ]; then
        m_debug "warning: mbim-proxy binary not found, lpac will try to auto-spawn"
        # libmbim can auto-spawn mbim-proxy, so this is not fatal
        return 0
    fi

    m_debug "starting mbim-proxy daemon (manual fallback)"
    $proxy_bin --no-exit >/dev/null 2>&1 &
    sleep 1

    if ! pidof mbim-proxy >/dev/null 2>&1; then
        m_debug "warning: mbim-proxy failed to start"
        return 1
    fi
    return 0
}

# Run lpac command and capture output
run_lpac() {
    # Always set environment for the specific modem we're operating on
    # This overrides any defaults in the lpac wrapper or UCI config
    setup_lpac_env

    # Use the wrapper if available (it reads UCI config but our env overrides it)
    local lpac_bin="/usr/bin/lpac"
    if [ ! -x "$lpac_bin" ]; then
        lpac_bin="/usr/lib/lpac"
        if [ ! -x "$lpac_bin" ]; then
            echo '{"error":"lpac binary not found"}'
            return 1
        fi
    fi

    ensure_mbim_proxy

    local result
    local stderr_file="/tmp/lpac_stderr_$$"
    result=$($lpac_bin "$@" 2>"$stderr_file")
    local ret=$?
    local stderr_out=$(cat "$stderr_file" 2>/dev/null)
    rm -f "$stderr_file"

    if [ -n "$stderr_out" ]; then
        m_debug "lpac stderr: $stderr_out"
    fi

    echo "$result"
    return $ret
}

# Non-disruptive operations (safe while internet is connected)
# These use mbim-proxy to share access with quectel-CM
do_chip_info() {
    local result
    result=$(run_lpac chip info)
    local ret=$?
    if [ $ret -eq 0 ] && echo "$result" | jq -e '.payload' >/dev/null 2>&1; then
        json_add_string "status" "1"
        json_add_string "raw" "$result"
        # Parse EID from JSON output
        local eid=$(echo "$result" | jq -r '.payload.data.eidValue // empty' 2>/dev/null)
        [ -n "$eid" ] && json_add_string "eid" "$eid"
    else
        json_add_string "status" "0"
        json_add_string "error" "lpac chip info failed (exit=$ret)"
        json_add_string "raw" "$result"
    fi
}

do_profile_list() {
    local result
    result=$(run_lpac profile list)
    local ret=$?
    if [ $ret -eq 0 ] && echo "$result" | jq -e '.payload' >/dev/null 2>&1; then
        json_add_string "status" "1"
        json_add_string "raw" "$result"
    else
        json_add_string "status" "0"
        json_add_string "error" "lpac profile list failed (exit=$ret)"
        json_add_string "raw" "$result"
    fi
}

do_notification_list() {
    local result
    result=$(run_lpac notification list)
    local ret=$?
    if [ $ret -eq 0 ]; then
        json_add_string "status" "1"
        json_add_string "raw" "$result"
    else
        json_add_string "status" "0"
        json_add_string "error" "lpac notification list failed (exit=$ret)"
        json_add_string "raw" "$result"
    fi
}

# Disruptive operations - need to stop dial first, then restart after
stop_dial_for_esim() {
    m_debug "stopping dial for eSIM operation on $config_section"

    # Kill the quectel-CM process via qmodem_network
    /etc/init.d/qmodem_network hang "$config_section"

    # Wait for quectel-CM to fully exit and release resources
    local wait_count=0
    local pid_file="${MODEM_RUNDIR}/${config_section}_dir/${config_section}.pid"
    while [ $wait_count -lt 10 ]; do
        if [ -f "$pid_file" ]; then
            local old_pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
                sleep 1
                wait_count=$((wait_count + 1))
                continue
            fi
        fi
        break
    done

    # Extra safety margin for MBIM session cleanup
    sleep 2
    m_debug "dial stopped, MBIM device should be available"
}

restart_dial_after_esim() {
    m_debug "restarting dial after eSIM operation on $config_section"

    # Wait for modem to re-register after profile switch
    # The modem needs time to:
    # 1. Process the profile switch internally
    # 2. Re-initialize the new profile's UICC applet
    # 3. Register on the network with new credentials
    local retries=30
    local sim_ready=0

    # First wait a bit for modem to process the switch
    sleep 5

    while [ $retries -gt 0 ]; do
        # Check if AT port is responsive
        local cpin=$(at "$at_port" "AT+CPIN?" 2>/dev/null)
        if [ -z "$cpin" ]; then
            m_debug "AT port not responding, waiting..."
            sleep 2
            retries=$((retries - 1))
            continue
        fi

        if echo "$cpin" | grep -q "READY"; then
            m_debug "SIM ready after eSIM operation"
            sim_ready=1
            break
        elif echo "$cpin" | grep -q "SIM PIN"; then
            m_debug "SIM requires PIN after profile switch"
            sim_ready=1
            break
        elif echo "$cpin" | grep -q "ERROR"; then
            # SIM not inserted or not ready yet
            m_debug "SIM not ready yet: $cpin"
            sleep 2
            retries=$((retries - 1))
            continue
        fi

        sleep 2
        retries=$((retries - 1))
    done

    if [ $sim_ready -eq 0 ]; then
        m_debug "warning: SIM not ready after 65s, attempting dial anyway"
    fi

    # Restart dial via qmodem_network
    /etc/init.d/qmodem_network dial "$config_section"
}

do_profile_enable() {
    local iccid=$(echo "$json_data" | jq -r '.iccid // empty' 2>/dev/null)
    local refresh=$(echo "$json_data" | jq -r '.refresh // "0"' 2>/dev/null)

    if [ -z "$iccid" ]; then
        json_add_string "status" "0"
        json_add_string "error" "iccid is required"
        return
    fi

    # Profile enable is disruptive - stop dial first
    stop_dial_for_esim

    local result
    result=$(run_lpac profile enable "$iccid" "$refresh")
    local ret=$?

    if [ $ret -eq 0 ]; then
        json_add_string "status" "1"
        json_add_string "raw" "$result"
        m_debug "profile enable success: $iccid"
    else
        json_add_string "status" "0"
        json_add_string "error" "lpac profile enable failed (exit=$ret)"
        json_add_string "raw" "$result"
        m_debug "profile enable failed: $iccid"
    fi

    # Always restart dial after profile operation (even on failure)
    restart_dial_after_esim
}

do_profile_disable() {
    local iccid=$(echo "$json_data" | jq -r '.iccid // empty' 2>/dev/null)

    if [ -z "$iccid" ]; then
        json_add_string "status" "0"
        json_add_string "error" "iccid is required"
        return
    fi

    stop_dial_for_esim

    local result
    result=$(run_lpac profile disable "$iccid")
    local ret=$?

    if [ $ret -eq 0 ]; then
        json_add_string "status" "1"
        json_add_string "raw" "$result"
    else
        json_add_string "status" "0"
        json_add_string "error" "lpac profile disable failed (exit=$ret)"
        json_add_string "raw" "$result"
    fi

    restart_dial_after_esim
}

do_profile_download() {
    local activation_code=$(echo "$json_data" | jq -r '.activation_code // empty' 2>/dev/null)
    local smdp=$(echo "$json_data" | jq -r '.smdp // empty' 2>/dev/null)
    local matching_id=$(echo "$json_data" | jq -r '.matching_id // empty' 2>/dev/null)
    local confirmation_code=$(echo "$json_data" | jq -r '.confirmation_code // empty' 2>/dev/null)

    if [ -z "$activation_code" ] && [ -z "$smdp" ]; then
        json_add_string "status" "0"
        json_add_string "error" "activation_code or smdp is required"
        return
    fi

    # Download needs internet - do NOT stop dial
    # Profile download communicates with SM-DP+ server over the internet
    # After download completes, profile is stored but NOT active
    # User must call profile_enable separately to activate it

    local result
    if [ -n "$activation_code" ]; then
        result=$(run_lpac profile download -a "$activation_code")
    elif [ -n "$confirmation_code" ]; then
        result=$(run_lpac profile download -s "$smdp" -m "$matching_id" -c "$confirmation_code")
    elif [ -n "$matching_id" ]; then
        result=$(run_lpac profile download -s "$smdp" -m "$matching_id")
    else
        result=$(run_lpac profile download -s "$smdp")
    fi
    local ret=$?

    if [ $ret -eq 0 ]; then
        json_add_string "status" "1"
        json_add_string "raw" "$result"
    else
        json_add_string "status" "0"
        json_add_string "error" "lpac profile download failed (exit=$ret)"
        json_add_string "raw" "$result"
    fi
}

do_profile_delete() {
    local iccid=$(echo "$json_data" | jq -r '.iccid // empty' 2>/dev/null)

    if [ -z "$iccid" ]; then
        json_add_string "status" "0"
        json_add_string "error" "iccid is required"
        return
    fi

    stop_dial_for_esim

    local result
    result=$(run_lpac profile delete "$iccid")
    local ret=$?

    if [ $ret -eq 0 ]; then
        json_add_string "status" "1"
        json_add_string "raw" "$result"
    else
        json_add_string "status" "0"
        json_add_string "error" "lpac profile delete failed (exit=$ret)"
        json_add_string "raw" "$result"
    fi

    restart_dial_after_esim
}

do_notification_process() {
    # Process notifications needs internet (sends to SM-DP+ server)
    # This is non-disruptive for the connection
    local result
    result=$(run_lpac notification process -a -r)
    local ret=$?

    if [ $ret -eq 0 ]; then
        json_add_string "status" "1"
        json_add_string "raw" "$result"
    else
        json_add_string "status" "0"
        json_add_string "error" "lpac notification process failed (exit=$ret)"
        json_add_string "raw" "$result"
    fi
}

# Main dispatch
json_init
json_add_object result

# Pre-flight checks
check_lpac || { json_close_object; json_dump; exit 1; }
check_mbim_device || { json_close_object; json_dump; exit 1; }

# Acquire lock to prevent concurrent eSIM operations
acquire_esim_lock || { json_close_object; json_dump; exit 1; }

# Trap to ensure lock is released on exit/error
trap 'release_esim_lock' EXIT

case $method in
    "chip_info")
        do_chip_info
        ;;
    "profile_list")
        do_profile_list
        ;;
    "profile_enable")
        do_profile_enable
        ;;
    "profile_disable")
        do_profile_disable
        ;;
    "profile_download")
        do_profile_download
        ;;
    "profile_delete")
        do_profile_delete
        ;;
    "notification_list")
        do_notification_list
        ;;
    "notification_process")
        do_notification_process
        ;;
    *)
        json_add_string "status" "0"
        json_add_string "error" "unknown method: $method"
        ;;
esac

json_close_object
json_dump
