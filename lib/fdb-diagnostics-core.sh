#!/bin/bash
# fdb-diagnostics-core.sh
# Core diagnostic functions for Flannel FDB and VXLAN networking
# Part of flannel-registrar's modular network management system

# Module information
MODULE_NAME="fdb-diagnostics-core"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "network-lib" "fdb-core")

# Global variables (minimal)
FDB_DIAG_STATE_DIR="${COMMON_STATE_DIR}/fdb-diagnostics"

# Initialize diagnostics module
init_fdb_diagnostics() {
    # Check dependencies
    for dep in log etcd_get etcd_list_keys; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found."
            return 1
        fi
    done
    
    # Create state directory
    mkdir -p "$FDB_DIAG_STATE_DIR" || {
        log "ERROR" "Failed to create directory: $FDB_DIAG_STATE_DIR"
        return 1
    }
    
    # Register callbacks if fdb-advanced is loaded
    if type register_fdb_diagnostic_callback &>/dev/null; then
        log "INFO" "Registering diagnostic callbacks"
        register_fdb_diagnostic_callback "pre_fix" "run_pre_fix_diagnostics"
        register_fdb_diagnostic_callback "post_fix" "run_post_fix_diagnostics"
    fi
    
    log "INFO" "Initialized fdb-diagnostics-core module (v${MODULE_VERSION})"
    return 0
}

# Generate core FDB diagnostics
# Simplified version with essential data only
get_fdb_diagnostics() {
    log "INFO" "Collecting FDB diagnostics"
    
    local diag="time:$(date +%s)\thost:$(hostname)\n"
    
    # Check interface exists
    if ! ip link show flannel.1 &>/dev/null; then
        diag+="error:interface_missing\tdetail:flannel.1 not found\n"
        echo -e "$diag"
        return 1
    fi
    
    # Get interface state
    local state=$(ip link show flannel.1 | grep -o 'state [^ ]*' | cut -d' ' -f2)
    diag+="iface:flannel.1\tstate:$state\t"
    
    # Get MTU
    local mtu=$(ip link show flannel.1 | grep -o 'mtu [0-9]*' | cut -d' ' -f2)
    diag+="mtu:$mtu\n"
    
    # Get FDB entries
    if command -v bridge &>/dev/null; then
        local count=$(bridge fdb show dev flannel.1 2>/dev/null | grep -v "^$" | wc -l)
        diag+="fdb_entries:$count\n"
        
        # List first 5 entries to avoid excessive output
        local i=0
        bridge fdb show dev flannel.1 2>/dev/null | while read -r entry; do
            [ -z "$entry" ] && continue
            [ $i -ge 5 ] && break
            
            local mac=$(echo "$entry" | awk '{print $1}')
            local dst=$(echo "$entry" | grep -o 'dst [^ ]*' | cut -d' ' -f2 || echo "none")
            diag+="fdb$i:$mac\tdst$i:$dst\n"
            i=$((i+1))
        done
    else
        diag+="error:no_bridge_command\n"
    fi
    
    # Get traffic stats (minimal)
    if ip -s link show flannel.1 &>/dev/null; then
        local stats=$(ip -s link show flannel.1)
        local rx=$(echo "$stats" | grep -A1 RX | tail -1 | awk '{print $1}')
        local tx=$(echo "$stats" | grep -A1 TX | tail -1 | awk '{print $1}')
        diag+="rx_packets:$rx\ttx_packets:$tx\n"
    fi
    
    echo -e "$diag"
    return 0
}

# Basic VXLAN troubleshooting
troubleshoot_vxlan() {
    local iface="${1:-flannel.1}"
    local remote_ip="$2"
    
    log "INFO" "Troubleshooting VXLAN on $iface"
    
    local diag="time:$(date +%s)\tiface:$iface\n"
    
    # Check interface exists
    if ! ip link show "$iface" &>/dev/null; then
        diag+="error:interface_missing\n"
        echo -e "$diag"
        return 1
    fi
    
    # Check interface state
    local state=$(ip link show "$iface" | grep -o 'state [^ ]*' | cut -d' ' -f2)
    diag+="state:$state\t"
    [ "$state" != "UNKNOWN" ] && diag+="warn:wrong_state\t"
    
    # Check MTU
    local mtu=$(ip link show "$iface" | grep -o 'mtu [0-9]*' | cut -d' ' -f2)
    diag+="mtu:$mtu\n"
    [ "$mtu" != "1370" ] && diag+="warn:wrong_mtu\t"
    
    # Check kernel module
    if lsmod | grep -q vxlan; then
        diag+="vxlan_module:loaded\n"
    else
        diag+="vxlan_module:missing\twarn:missing_module\n"
    fi
    
    # Check VXLAN port
    if command -v ss &>/dev/null && ss -unl | grep -q "8472"; then
        diag+="vxlan_port:open\n"
    elif command -v netstat &>/dev/null && netstat -unl | grep -q "8472"; then
        diag+="vxlan_port:open\n"
    else
        diag+="vxlan_port:unknown\twarn:port_not_found\n"
    fi
    
    # Check traffic stats
    if ip -s link show "$iface" &>/dev/null; then
        local stats=$(ip -s link show "$iface")
        local rx=$(echo "$stats" | grep -A1 RX | tail -1 | awk '{print $1}')
        local tx=$(echo "$stats" | grep -A1 TX | tail -1 | awk '{print $1}')
        diag+="rx_packets:$rx\ttx_packets:$tx\n"
        
        # Check for one-way patterns
        if [ $rx -gt 100000 ] && [ $tx -lt 1000 ]; then
            diag+="warn:one_way_rx\n"
        elif [ $tx -gt 100000 ] && [ $rx -lt 1000 ]; then
            diag+="warn:one_way_tx\n"
        fi
    fi
    
    # Check remote IP if specified
    if [ -n "$remote_ip" ]; then
        diag+="remote:$remote_ip\t"
        if ping -c 1 -W 2 "$remote_ip" &>/dev/null; then
            diag+="ping:success\n"
        else
            diag+="ping:failed\n"
            
            # Check if gateway is defined
            if type get_host_gateway &>/dev/null; then
                local gateway=$(get_host_gateway "$remote_ip")
                if [ -n "$gateway" ] && [ "$gateway" != "$remote_ip" ]; then
                    diag+="gateway:$gateway\t"
                    ping -c 1 -W 2 "$gateway" &>/dev/null && \
                        diag+="gateway_ping:success\n" || \
                        diag+="gateway_ping:failed\n"
                fi
            fi
        fi
    fi
    
    echo -e "$diag"
    return 0
}

# Check for stale FDB entries
check_stale_fdb_entries() {
    log "INFO" "Checking for stale FDB entries"
    
    if ! command -v bridge &>/dev/null; then
        echo "error:no_bridge_command"
        return 1
    fi
    
    local diag="time:$(date +%s)\n"
    local stale_count=0
    local wrong_dst=0
    local missing=0
    
    # Get all valid MACs from etcd
    local valid_macs=()
    local valid_dsts=()
    
    for key in $(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/subnets/_host_status/"); do
        local host=$(basename "$key")
        local status_data=$(etcd_get "$key")
        [ -z "$status_data" ] && continue
        
        # Extract MAC
        local mac=""
        if command -v jq &>/dev/null; then
            mac=$(echo "$status_data" | jq -r '.vtep_mac // ""')
        else
            mac=$(echo "$status_data" | grep -o '"vtep_mac":"[^"]*"' | cut -d'"' -f4 || echo "")
        fi
        
        [ -z "$mac" ] || [ "$mac" = "null" ] || [ "$mac" = "unknown" ] && continue
        
        # Find IP for this host
        local ip=""
        for subnet_key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/"); do
            local subnet_data=$(etcd_get "$subnet_key")
            if [ -n "$subnet_data" ] && echo "$subnet_data" | grep -q "\"hostname\":\"$host\""; then
                if command -v jq &>/dev/null; then
                    ip=$(echo "$subnet_data" | jq -r '.PublicIP')
                else
                    ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
                fi
                break
            fi
        done
        
        [ -z "$ip" ] && continue
        
        # Determine correct destination (direct or via gateway)
        local dst="$ip"
        if type get_host_gateway &>/dev/null; then
            local gateway=$(get_host_gateway "$ip")
            [ -n "$gateway" ] && [ "$gateway" != "$ip" ] && dst="$gateway"
        fi
        
        valid_macs+=("$mac")
        valid_dsts+=("$dst")
    done
    
    # Check current FDB entries
    local current_macs=()
    local current_dsts=()
    
    bridge fdb show dev flannel.1 2>/dev/null | while read -r entry; do
        [ -z "$entry" ] && continue
        
        local mac=$(echo "$entry" | awk '{print $1}')
        local dst=$(echo "$entry" | grep -o 'dst [^ ]*' | cut -d' ' -f2 || echo "")
        
        current_macs+=("$mac")
        current_dsts+=("$dst")
        
        # Check if MAC is valid
        local valid=false
        local expected_dst=""
        
        for i in "${!valid_macs[@]}"; do
            if [ "${valid_macs[$i]}" = "$mac" ]; then
                valid=true
                expected_dst="${valid_dsts[$i]}"
                break
            fi
        done
        
        if ! $valid; then
            stale_count=$((stale_count + 1))
            diag+="stale:$mac\tdst:$dst\n"
        elif [ -n "$expected_dst" ] && [ "$dst" != "$expected_dst" ]; then
            wrong_dst=$((wrong_dst + 1))
            diag+="wrong_dst:$mac\tcurrent:$dst\texpected:$expected_dst\n"
        fi
    done
    
    # Check for missing entries
    for i in "${!valid_macs[@]}"; do
        local found=false
        
        for j in "${!current_macs[@]}"; do
            if [ "${valid_macs[$i]}" = "${current_macs[$j]}" ]; then
                found=true
                break
            fi
        done
        
        if ! $found; then
            missing=$((missing + 1))
            diag+="missing:${valid_macs[$i]}\tdst:${valid_dsts[$i]}\n"
        fi
    done
    
    diag+="stale_count:$stale_count\twrong_dst:$wrong_dst\tmissing:$missing\n"
    
    echo -e "$diag"
    return $(( stale_count + wrong_dst + missing > 0 ? 1 : 0 ))
}

# Register diagnostic callback with operational module
register_diag_callback() {
    local trigger="$1"
    local callback="$2"
    
    # Validate inputs
    if [ -z "$trigger" ] || [ -z "$callback" ]; then
        log "ERROR" "Both trigger and callback must be specified"
        return 1
    fi
    
    # Check if callback function exists
    if ! type "$callback" &>/dev/null; then
        log "ERROR" "Callback function $callback not found"
        return 1
    fi
    
    # Register with fdb-advanced if available
    if type register_fdb_diagnostic_callback &>/dev/null; then
        register_fdb_diagnostic_callback "$trigger" "$callback"
        log "INFO" "Registered callback $callback for trigger $trigger"
        return 0
    else
        log "WARNING" "fdb-advanced not loaded, callback not registered"
        return 1
    fi
}

# Run pre-fix diagnostics
run_pre_fix_diagnostics() {
    local iface="$1"
    log "DEBUG" "Running pre-fix diagnostics for $iface"
    
    # Save diagnostics to temp file
    local diag_file="${FDB_DIAG_STATE_DIR}/pre_fix_$(date +%s).diag"
    troubleshoot_vxlan "$iface" > "$diag_file"
    
    # Log summary
    if grep -q "warn:" "$diag_file"; then
        local warns=$(grep "warn:" "$diag_file" | wc -l)
        log "WARNING" "Pre-fix diagnostics found $warns warnings"
    else
        log "INFO" "Pre-fix diagnostics completed, no issues detected"
    fi
    
    return 0
}

# Run post-fix diagnostics
run_post_fix_diagnostics() {
    local iface="$1"
    log "DEBUG" "Running post-fix diagnostics for $iface"
    
    # Save diagnostics to temp file
    local diag_file="${FDB_DIAG_STATE_DIR}/post_fix_$(date +%s).diag"
    troubleshoot_vxlan "$iface" > "$diag_file"
    
    # Compare with pre-fix if available
    local pre_file=$(ls -t ${FDB_DIAG_STATE_DIR}/pre_fix_*.diag 2>/dev/null | head -1)
    if [ -n "$pre_file" ]; then
        local pre_warns=$(grep "warn:" "$pre_file" 2>/dev/null | wc -l)
        local post_warns=$(grep "warn:" "$diag_file" | wc -l)
        
        if [ $post_warns -lt $pre_warns ]; then
            log "INFO" "Fix improved status: $pre_warns -> $post_warns warnings"
        elif [ $post_warns -eq $pre_warns ]; then
            log "INFO" "Fix had no effect on warnings: $post_warns remain"
        else
            log "WARNING" "Fix may have caused new issues: $pre_warns -> $post_warns warnings"
        fi
    fi
    
    return 0
}

# Export necessary functions and variables
export -f init_fdb_diagnostics get_fdb_diagnostics troubleshoot_vxlan
export -f check_stale_fdb_entries register_diag_callback
export -f run_pre_fix_diagnostics run_post_fix_diagnostics
export FDB_DIAG_STATE_DIR
