#!/bin/bash
# fdb-advanced.sh
# Advanced FDB management functions for Flannel VXLAN networking
# Part of flannel-registrar's modular network management system

# Module information
MODULE_NAME="fdb-advanced"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "network-lib" "fdb-core")

# ==========================================
# Global variables for advanced FDB management
# ==========================================

# Last optimization time for FDB entries
FDB_LAST_OPTIMIZATION_TIME=0

# Optimization interval for FDB entries (seconds)
FDB_OPTIMIZATION_INTERVAL=${FDB_OPTIMIZATION_INTERVAL:-3600}  # Default 1 hour

# Registered diagnostic callbacks
declare -A FDB_DIAGNOSTIC_CALLBACKS

# ==========================================
# Initialization function
# ==========================================

# Initialize advanced FDB management
init_fdb_advanced() {
    # Check dependencies
    for dep in log etcd_get update_fdb_entries_from_etcd fix_flannel_mtu; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found. Make sure all dependencies are loaded."
            return 1
        fi
    done
    
    # Initialize diagnostic callbacks array
    declare -A FDB_DIAGNOSTIC_CALLBACKS
    
    # Log module initialization
    log "INFO" "Initialized fdb-advanced module (v${MODULE_VERSION})"
    
    return 0
}

# ==========================================
# Advanced FDB management functions
# ==========================================

# Check and fix VXLAN connectivity issues
# Usage: check_and_fix_vxlan [interface] [verbosity]
# Returns: 0 if fixed, 1 if issues persist
check_and_fix_vxlan() {
    local interface="${1:-flannel.1}"
    local verbosity="${2:-normal}"  # Values: minimal, normal, detailed
    
    # Run pre-fix diagnostics if callback registered
    if [ -n "${FDB_DIAGNOSTIC_CALLBACKS[pre_fix]}" ]; then
        log "DEBUG" "Running pre-fix diagnostics"
        ${FDB_DIAGNOSTIC_CALLBACKS[pre_fix]} "$interface"
    fi
    
    # Check if interface exists
    if ! ip link show "$interface" &>/dev/null; then
        log "WARNING" "Interface $interface does not exist, cannot fix"
        return 1
    fi
    
    local issues_detected=0
    local fixes_applied=0
    
    # Fix 1: Ensure MTU is correct
    if [ "$verbosity" != "minimal" ]; then
        log "INFO" "Checking MTU for $interface"
    fi
    if ! fix_flannel_mtu "$interface"; then
        issues_detected=$((issues_detected + 1))
    else
        fixes_applied=$((fixes_applied + 1))
    fi
    
    # Fix 2: Ensure interface is up
    local link_state=$(ip link show "$interface" | grep -o 'state [^ ]*' | cut -d' ' -f2)
    if [ "$link_state" != "UNKNOWN" ]; then
        if [ "$verbosity" != "minimal" ]; then
            log "INFO" "Setting interface $interface to UP"
        fi
        if ip link set "$interface" up; then
            fixes_applied=$((fixes_applied + 1))
        else
            issues_detected=$((issues_detected + 1))
            log "ERROR" "Failed to bring up interface $interface"
        fi
    fi
    
    # Fix 3: Update FDB entries from etcd
    if [ "$verbosity" != "minimal" ]; then
        log "INFO" "Updating FDB entries from etcd"
    fi
    if ! update_fdb_entries_from_etcd; then
        issues_detected=$((issues_detected + 1))
    else
        fixes_applied=$((fixes_applied + 1))
    fi
    
    # Fix 4: Flush ARP cache for known problematic entries
    local arp_cache=$(ip neigh show)
    local flushed_arp=0
    
    while read -r entry; do
        if [[ "$entry" == *"FAILED"* ]]; then
            local ip=$(echo "$entry" | awk '{print $1}')
            if [ "$verbosity" = "detailed" ]; then
                log "INFO" "Flushing failed ARP entry for $ip"
            fi
            ip neigh flush dev $interface to $ip 2>/dev/null || true
            flushed_arp=$((flushed_arp + 1))
        fi
    done <<< "$arp_cache"
    
    if [ $flushed_arp -gt 0 ]; then
        if [ "$verbosity" != "minimal" ]; then
            log "INFO" "Flushed $flushed_arp failed ARP entries"
        fi
        fixes_applied=$((fixes_applied + 1))
    fi
    
    # Fix 5: Check for and remove duplicate FDB entries
    local fdb_entries=$(bridge fdb show dev "$interface" 2>/dev/null)
    local seen_macs=()
    local removed_dupes=0
    
    while read -r entry; do
        if [ -z "$entry" ]; then
            continue
        fi
        
        # Extract MAC address
        local mac=$(echo "$entry" | awk '{print $1}')
        
        # Check if we've seen this MAC before
        for seen_mac in "${seen_macs[@]}"; do
            if [ "$seen_mac" = "$mac" ]; then
                if [ "$verbosity" = "detailed" ]; then
                    log "INFO" "Removing duplicate FDB entry for MAC $mac"
                fi
                bridge fdb del "$mac" dev "$interface"
                removed_dupes=$((removed_dupes + 1))
                break
            fi
        done
        
        seen_macs+=("$mac")
    done <<< "$fdb_entries"
    
    if [ $removed_dupes -gt 0 ]; then
        if [ "$verbosity" != "minimal" ]; then
            log "INFO" "Removed $removed_dupes duplicate FDB entries"
        fi
        fixes_applied=$((fixes_applied + 1))
    fi
    
    # Log summary
    if [ "$verbosity" != "minimal" ]; then
        log "INFO" "VXLAN fixes applied to $interface: $fixes_applied fixes, $issues_detected remaining issues"
    fi
    
    # Run post-fix diagnostics if callback registered
    if [ -n "${FDB_DIAGNOSTIC_CALLBACKS[post_fix]}" ]; then
        log "DEBUG" "Running post-fix diagnostics"
        ${FDB_DIAGNOSTIC_CALLBACKS[post_fix]} "$interface"
    fi
    
    if [ $issues_detected -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Detect one-way communication issues
# Usage: detect_one_way_communication subnet1 subnet2
# Returns: 0 if bidirectional, 1 if one-way or no connectivity
detect_one_way_communication() {
    local subnet1="$1"
    local subnet2="$2"
    
    log "INFO" "Testing bidirectional connectivity between $subnet1 and $subnet2"
    
    # Get test IPs (first usable IP in each subnet)
    local subnet1_base=$(echo "$subnet1" | cut -d'/' -f1)
    local test_ip1="${subnet1_base%.*}.$((${subnet1_base##*.} + 1))"
    
    local subnet2_base=$(echo "$subnet2" | cut -d'/' -f1)
    local test_ip2="${subnet2_base%.*}.$((${subnet2_base##*.} + 1))"
    
    # Find containers in each subnet to use for testing
    local network1=$(docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none' | head -1)
    local network2=$(docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none' | grep -v "$network1" | head -1)
    
    if [ -z "$network1" ] || [ -z "$network2" ]; then
        log "WARNING" "Not enough networks to test bidirectional connectivity"
        return 1
    fi
    
    local container1=$(docker ps --filter network="$network1" --format "{{.Names}}" | head -1)
    local container2=$(docker ps --filter network="$network2" --format "{{.Names}}" | head -1)
    
    # Create temporary containers if needed
    local temp_containers=()
    
    if [ -z "$container1" ]; then
        container1="flannel-bidir-test1-$$"
        docker run --rm -d --name "$container1" --network "$network1" alpine:latest sleep 300 >/dev/null
        temp_containers+=("$container1")
    fi
    
    if [ -z "$container2" ]; then
        container2="flannel-bidir-test2-$$"
        docker run --rm -d --name "$container2" --network "$network2" alpine:latest sleep 300 >/dev/null
        temp_containers+=("$container2")
    fi
    
    # Test 1→2 connectivity
    log "DEBUG" "Testing connectivity from $container1 to $test_ip2"
    local result1to2=$(docker exec "$container1" ping -c 2 -W 3 "$test_ip2" 2>&1)
    local success1to2=$?
    
    # Test 2→1 connectivity
    log "DEBUG" "Testing connectivity from $container2 to $test_ip1"
    local result2to1=$(docker exec "$container2" ping -c 2 -W 3 "$test_ip1" 2>&1)
    local success2to1=$?
    
    # Clean up temporary containers
    for container in "${temp_containers[@]}"; do
        docker rm -f "$container" >/dev/null 2>&1
    done
    
    # Analyze results
    if [ $success1to2 -eq 0 ] && [ $success2to1 -eq 0 ]; then
        log "INFO" "Bidirectional connectivity confirmed between $subnet1 and $subnet2"
        return 0
    elif [ $success1to2 -eq 0 ] && [ $success2to1 -ne 0 ]; then
        log "WARNING" "One-way communication detected: $subnet1 → $subnet2 works, but return path fails"
        return 1
    elif [ $success1to2 -ne 0 ] && [ $success2to1 -eq 0 ]; then
        log "WARNING" "One-way communication detected: $subnet2 → $subnet1 works, but return path fails"
        return 1
    else
        log "WARNING" "No connectivity between $subnet1 and $subnet2 in either direction"
        return 1
    fi
}

# Setup VTEP endpoints for proper VXLAN tunneling
# Usage: setup_vtep_endpoints [force_update]
# Returns: 0 if successful, 1 if failed
setup_vtep_endpoints() {
    local force_update="${1:-false}"
    
    log "INFO" "Setting up VTEP endpoints for VXLAN tunneling"
    
    # Ensure bridge command is available
    if ! command -v bridge &>/dev/null; then
        log "ERROR" "bridge command not available, cannot setup VTEP endpoints"
        return 1
    fi
    
    # Get local VTEP MAC address
    local local_mac=$(get_flannel_mac_address 2>/dev/null)
    if [ -z "$local_mac" ]; then
        log "WARNING" "Could not determine local VTEP MAC address"
    else 
        log "DEBUG" "Local VTEP MAC address: $local_mac"
    fi
    
    # Get all subnet entries
    local subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    if [ -z "$subnet_keys" ]; then
        log "WARNING" "No subnet entries found or could not access etcd"
        return 1
    fi
    
    local setup_count=0
    local error_count=0
    
    for key in $subnet_keys; do
        local subnet_data=$(etcd_get "$key")
        
        if [ -n "$subnet_data" ]; then
            # Extract PublicIP and VTEP MAC
            local public_ip=""
            local vtep_mac=""
            local hostname=""
            
            if command -v jq &>/dev/null; then
                public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
                vtep_mac=$(echo "$subnet_data" | jq -r '.backend.vtepMAC // "unknown"')
                hostname=$(echo "$subnet_data" | jq -r '.hostname // "unknown"')
            else
                public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
                vtep_mac=$(echo "$subnet_data" | grep -o '"vtepMAC":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
                hostname=$(echo "$subnet_data" | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
            fi
            
            # Skip localhost/our own IP or entries with unknown MAC
            if [ "$public_ip" = "127.0.0.1" ] || [ "$public_ip" = "$FLANNELD_PUBLIC_IP" ] || 
               [ -z "$vtep_mac" ] || [ "$vtep_mac" = "unknown" ] || [ "$vtep_mac" = "null" ]; then
                continue
            fi
            
            # Determine appropriate endpoint IP for FDB
            local endpoint_ip="$public_ip"
            if type get_host_gateway &>/dev/null; then
                local gateway=$(get_host_gateway "$public_ip")
                if [ -n "$gateway" ] && [ "$gateway" != "$public_ip" ]; then
                    endpoint_ip="$gateway"
                    log "INFO" "Using gateway $endpoint_ip for VTEP endpoint (host: $public_ip, hostname: $hostname)"
                fi
            fi
            
            # Check if FDB entry already exists
            local current_entry=$(bridge fdb show dev flannel.1 | grep "$vtep_mac" || echo "")
            
            # Determine if we need to update
            local needs_update=false
            if [ -z "$current_entry" ]; then
                needs_update=true
            elif [ "$force_update" = "true" ]; then
                needs_update=true
            elif ! echo "$current_entry" | grep -q "dst $endpoint_ip"; then
                needs_update=true
            fi
            
            if $needs_update; then
                log "INFO" "Setting up VTEP endpoint: MAC=$vtep_mac IP=$endpoint_ip (hostname: $hostname)"
                
                # Remove any existing entry first
                bridge fdb del "$vtep_mac" dev flannel.1 2>/dev/null || true
                
                # Add the new entry
                if bridge fdb add "$vtep_mac" dev flannel.1 dst "$endpoint_ip"; then
                    setup_count=$((setup_count + 1))
                else 
                    log "ERROR" "Failed to add FDB entry for $vtep_mac to $endpoint_ip"
                    error_count=$((error_count + 1))
                fi
            else 
                log "DEBUG" "VTEP endpoint already correctly configured for $hostname"
            fi
        fi
    done
    
    log "INFO" "VTEP endpoint setup completed: $setup_count endpoints configured, $error_count errors"
    
    if [ $error_count -eq 0 ]; then
        return 0
    else 
        return 1
    fi
}

# Check VXLAN interfaces status and configuration
# Extended version over the core implementation
# Usage: check_vxlan_interfaces [interface]
# Returns: 0 if ok, 1 if issues detected
check_vxlan_interfaces() {
    local interface="${1:-flannel.1}"
    
    log "INFO" "Checking VXLAN interface $interface status and configuration"
    
    local issues_detected=0
    
    # Check if interface exists
    if ! ip link show "$interface" &>/dev/null; then
        log "ERROR" "VXLAN interface $interface does not exist"
        return 1
    fi
    
    # Check interface state
    local link_state=$(ip link show "$interface" | grep -o 'state [^ ]*' | cut -d' ' -f2)
    if [ "$link_state" != "UNKNOWN" ]; then
        log "WARNING" "VXLAN interface $interface is in $link_state state, should be UNKNOWN"
        issues_detected=$((issues_detected + 1))
    fi
    
    # Check MTU
    local current_mtu=$(ip link show "$interface" | grep -o 'mtu [0-9]*' | cut -d' ' -f2)
    if [ "$current_mtu" != "1370" ]; then
        log "WARNING" "VXLAN interface $interface has incorrect MTU: $current_mtu, should be 1370"
        issues_detected=$((issues_detected + 1))
    fi
    
    # Check for traffic flow
    local interface_stats=$(ip -s link show "$interface")
    local rx_bytes=$(echo "$interface_stats" | grep -A2 RX | tail -1 | awk '{print $1}')
    local tx_bytes=$(echo "$interface_stats" | grep -A2 TX | tail -1 | awk '{print $1}')

    # Ensure variables contain only numeric values
    rx_bytes=$(echo "$rx_bytes" | grep -o '^[0-9]*$' || echo "0")
    tx_bytes=$(echo "$tx_bytes" | grep -o '^[0-9]*$' || echo "0")
    
    if [ "$rx_bytes" -eq 0 ] && [ "$tx_bytes" -eq 0 ]; then
        log "WARNING" "VXLAN interface $interface has no traffic"
        issues_detected=$((issues_detected + 1))
    fi
    
    # Check for signs of one-way communication
    if [ "$rx_bytes" -gt 100000 ] && [ "$tx_bytes" -lt 1000 ]; then
        log "WARNING" "VXLAN interface $interface shows signs of one-way communication (receiving only)"
        issues_detected=$((issues_detected + 1))
    elif [ "$tx_bytes" -gt 100000 ] && [ "$rx_bytes" -lt 1000 ]; then
        log "WARNING" "VXLAN interface $interface shows signs of one-way communication (sending only)"
        issues_detected=$((issues_detected + 1))
    fi
    
    # Check VXLAN port (8472)
    if command -v ss &>/dev/null; then
        if ! ss -unl | grep -q "8472"; then
            log "WARNING" "VXLAN port 8472 not found in listening UDP sockets"
            issues_detected=$((issues_detected + 1))
        fi
    elif command -v netstat &>/dev/null; then
        if ! netstat -unl | grep -q "8472"; then
            log "WARNING" "VXLAN port 8472 not found in listening UDP sockets"
            issues_detected=$((issues_detected + 1))
        fi
    fi
    
    # Check FDB entries
    local fdb_entries=$(bridge fdb show dev "$interface" 2>/dev/null | wc -l)
    if [ "$fdb_entries" -eq 0 ]; then
        log "WARNING" "No FDB entries found for $interface"
        issues_detected=$((issues_detected + 1))
    fi
    
    # Check kernel module
    if ! lsmod | grep -q vxlan; then
        log "WARNING" "VXLAN kernel module not loaded"
        issues_detected=$((issues_detected + 1))
    fi
    
    if [ $issues_detected -eq 0 ]; then
        log "INFO" "VXLAN interface $interface is properly configured"
        return 0
    else 
        log "WARNING" "VXLAN interface $interface has $issues_detected issues"
        return 1
    fi
}

# Optimize FDB entries for better performance
# Usage: optimize_fdb_entries
# Returns: 0 if successful, 1 if issues encountered
optimize_fdb_entries() {
    local current_time=$(date +%s)
    
    # Only run optimization every FDB_OPTIMIZATION_INTERVAL seconds
    if [ $((current_time - FDB_LAST_OPTIMIZATION_TIME)) -lt $FDB_OPTIMIZATION_INTERVAL ]; then
        log "DEBUG" "Skipping FDB optimization - last optimization was $(($current_time - FDB_LAST_OPTIMIZATION_TIME)) seconds ago"
        return 0
    fi 
    
    log "INFO" "Optimizing FDB entries for VXLAN performance"
    FDB_LAST_OPTIMIZATION_TIME=$current_time
    
    # Ensure bridge command is available
    if ! command -v bridge &>/dev/null; then
        log "ERROR" "bridge command not available, cannot optimize FDB entries"
        return 1
    fi
    
    local fdb_entries=$(bridge fdb show dev flannel.1 2>/dev/null)
    if [ -z "$fdb_entries" ]; then
        log "WARNING" "No FDB entries found to optimize"
        return 0
    fi
    
    local optimized_count=0
    local error_count=0
    
    # Check for stale entries (entries with no matching VTEP MAC in etcd)
    local valid_macs=()
    
    # Get all VTEP MACs from etcd
    for key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/"); do
        local subnet_data=$(etcd_get "$key")
        
        if [ -n "$subnet_data" ]; then
            local vtep_mac=""
            
            if command -v jq &>/dev/null; then
                vtep_mac=$(echo "$subnet_data" | jq -r '.backend.vtepMAC // ""')
            else
                vtep_mac=$(echo "$subnet_data" | grep -o '"vtepMAC":"[^"]*"' | cut -d'"' -f4 || echo "")
            fi
            
            if [ -n "$vtep_mac" ] && [ "$vtep_mac" != "null" ]; then
                valid_macs+=("$vtep_mac")
            fi
        fi
    done
    
    # Remove stale entries
    while read -r entry; do
        if [ -z "$entry" ]; then
            continue
        fi
        
        # Extract MAC address
        local mac=$(echo "$entry" | awk '{print $1}')
        
        # Check if MAC is valid
        local is_valid=false
        for valid_mac in "${valid_macs[@]}"; do
            if [ "$mac" = "$valid_mac" ]; then
                is_valid=true
                break
            fi
        done
        
        if ! $is_valid; then
            log "INFO" "Removing stale FDB entry: $entry"
            if bridge fdb del "$mac" dev flannel.1; then
                optimized_count=$((optimized_count + 1))
            else 
                error_count=$((error_count + 1))
            fi
        fi
    done <<< "$fdb_entries"
    
    log "INFO" "FDB optimization completed: $optimized_count entries removed, $error_count errors"
    
    if [ $error_count -eq 0 ]; then
        return 0
    else 
        return 1
    fi
}

# Register a diagnostic callback function
# Usage: register_fdb_diagnostic_callback trigger_point callback_function
# Returns: 0 if registered, 1 if failed
register_fdb_diagnostic_callback() {
    local trigger_point="$1"
    local callback_function="$2"
    
    if [ -z "$trigger_point" ] || [ -z "$callback_function" ]; then
        log "ERROR" "Both trigger_point and callback_function must be specified"
        return 1
    fi
    
    # Check if callback function exists
    if ! type "$callback_function" &>/dev/null; then
        log "ERROR" "Callback function $callback_function does not exist"
        return 1
    fi
    
    # Register callback
    FDB_DIAGNOSTIC_CALLBACKS["$trigger_point"]="$callback_function"
    log "INFO" "Registered diagnostic callback for trigger point: $trigger_point"
    
    return 0
}

# Export necessary functions and variables
export -f init_fdb_advanced check_and_fix_vxlan detect_one_way_communication
export -f check_vxlan_interfaces setup_vtep_endpoints optimize_fdb_entries
export -f register_fdb_diagnostic_callback
export FDB_LAST_OPTIMIZATION_TIME FDB_OPTIMIZATION_INTERVAL
export -A FDB_DIAGNOSTIC_CALLBACKS
