#!/bin/bash
# fdb-core.sh
# Core functions for managing Flannel FDB entries
# Part of flannel-registrar's modular network management system

# Module information
MODULE_NAME="fdb-core"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "network-lib")

# ==========================================
# Global variables for FDB management
# ==========================================

# Last update time for FDB entries
FDB_LAST_UPDATE_TIME=0

# Update interval for FDB entries (seconds)
FDB_UPDATE_INTERVAL=${FDB_UPDATE_INTERVAL:-120}  # Default 2 minutes

# State directory for FDB management
FDB_STATE_DIR="${COMMON_STATE_DIR}/fdb"

# Backup file for FDB entries
FDB_BACKUP_FILE="$FDB_STATE_DIR/fdb_backup.json"

# ==========================================
# Initialization function
# ==========================================

# Initialize FDB management
init_fdb_management() {
    # Check dependencies
    for dep in log etcd_get etcd_list_keys get_flannel_mac_address; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found. Make sure all dependencies are loaded."
            return 1
        fi
    done
    
    # Create state directory if it doesn't exist
    mkdir -p "$FDB_STATE_DIR" || {
        log "ERROR" "Failed to create FDB state directory: $FDB_STATE_DIR"
        return 1
    }
    
    # Restore from backup if it exists and is recent
    if [ -f "$FDB_BACKUP_FILE" ]; then
        local backup_age=$(($(date +%s) - $(stat -c %Y "$FDB_BACKUP_FILE")))
        
        if [ $backup_age -lt 3600 ]; then  # Backup less than 1 hour old
            log "INFO" "Found recent FDB backup (age: $backup_age seconds), restoring"
            restore_fdb_from_backup
        else
            log "INFO" "Found outdated FDB backup (age: $backup_age seconds), ignoring"
        fi
    fi
    
    # Log module initialization
    log "INFO" "Initialized fdb-core module (v${MODULE_VERSION})"
    
    return 0
}

# ==========================================
# FDB backup and restore functions
# ==========================================

# Backup current FDB entries
# Usage: backup_fdb_entries
backup_fdb_entries() {
    # Ensure backup directory exists before writing the file
    mkdir -p "$(dirname "$FDB_BACKUP_FILE")" || {
        log "WARNING" "Failed to create backup directory: $(dirname "$FDB_BACKUP_FILE")"
    }

    # Get current FDB entries for flannel.1
    if command -v bridge &>/dev/null; then
        local fdb_entries=$(bridge fdb show dev flannel.1 2>/dev/null)
        
        if [ -n "$fdb_entries" ]; then
            # Convert to JSON for easier parsing later
            local fdb_json="["
            local first=true
            
            while read -r entry; do
                if [ -z "$entry" ]; then
                    continue
                fi
                
                # Extract MAC and destination
                local mac=$(echo "$entry" | awk '{print $1}')
                local dst=$(echo "$entry" | grep -o 'dst [^ ]*' | cut -d' ' -f2 || echo "")
                
                if ! $first; then
                    fdb_json+=","
                fi
                first=false
                
                fdb_json+="{\"mac\":\"$mac\",\"dst\":\"$dst\"}"
            done <<< "$fdb_entries"
            
            fdb_json+="]"
            
            # Save to file
            echo "$fdb_json" > "$FDB_BACKUP_FILE"
            log "DEBUG" "Backed up $(echo "$fdb_json" | grep -o "mac" | wc -l) FDB entries"
        else
            log "WARNING" "No FDB entries found to backup"
            echo "[]" > "$FDB_BACKUP_FILE"
        fi
    else
        log "WARNING" "bridge command not available, cannot backup FDB entries"
        echo "[]" > "$FDB_BACKUP_FILE"
    fi
    
    return 0
}

# Restore FDB entries from backup
# Usage: restore_fdb_from_backup
restore_fdb_from_backup() {
    if [ ! -f "$FDB_BACKUP_FILE" ]; then
        log "WARNING" "No FDB backup file found"
        return 1
    fi
    
    if ! command -v bridge &>/dev/null; then
        log "WARNING" "bridge command not available, cannot restore FDB entries"
        return 1
    fi
    
    log "INFO" "Restoring FDB entries from backup"
    
    local entries=0
    local successes=0
    
    # Read the JSON backup
    if command -v jq &>/dev/null; then
        # Parse JSON with jq
        local count=$(jq length "$FDB_BACKUP_FILE")
        
        for ((i=0; i<count; i++)); do
            local mac=$(jq -r ".[$i].mac" "$FDB_BACKUP_FILE")
            local dst=$(jq -r ".[$i].dst" "$FDB_BACKUP_FILE")
            
            if [ -n "$mac" ] && [ -n "$dst" ] && [ "$mac" != "null" ] && [ "$dst" != "null" ]; then
                entries=$((entries + 1))
                
                # Delete any existing entry for this MAC
                bridge fdb del "$mac" dev flannel.1 2>/dev/null || true
                
                # Add the new entry
                if bridge fdb add "$mac" dev flannel.1 dst "$dst"; then
                    successes=$((successes + 1))
                fi
            fi
        done
    else
        # Fallback to grep/sed parsing if jq is not available
        # Extract MAC addresses
        local macs=$(grep -o '"mac":"[^"]*"' "$FDB_BACKUP_FILE" | cut -d'"' -f4)
        local dsts=$(grep -o '"dst":"[^"]*"' "$FDB_BACKUP_FILE" | cut -d'"' -f4)
        
        # Convert to arrays
        local mac_array=()
        local dst_array=()
        
        while read -r mac; do
            if [ -n "$mac" ]; then
                mac_array+=("$mac")
            fi
        done <<< "$macs"
        
        while read -r dst; do
            if [ -n "$dst" ]; then
                dst_array+=("$dst")
            fi
        done <<< "$dsts"
        
        # Add FDB entries
        for ((i=0; i<${#mac_array[@]}; i++)); do
            if [ -n "${mac_array[$i]}" ] && [ -n "${dst_array[$i]}" ]; then
                entries=$((entries + 1))
                
                # Delete any existing entry for this MAC
                bridge fdb del "${mac_array[$i]}" dev flannel.1 2>/dev/null || true
                
                # Add the new entry
                if bridge fdb add "${mac_array[$i]}" dev flannel.1 dst "${dst_array[$i]}"; then
                    successes=$((successes + 1))
                fi
            fi
        done
    fi
    
    log "INFO" "Restored $successes/$entries FDB entries from backup"
    return 0
}

# ==========================================
# Core FDB management functions
# ==========================================

# Update FDB entries from etcd
# Usage: update_fdb_entries_from_etcd
update_fdb_entries_from_etcd() {
    local current_time=$(date +%s)
    
    # Only run full update every FDB_UPDATE_INTERVAL seconds
    if [ $((current_time - FDB_LAST_UPDATE_TIME)) -lt $FDB_UPDATE_INTERVAL ]; then
        log "DEBUG" "Skipping FDB update - last update was $(($current_time - FDB_LAST_UPDATE_TIME)) seconds ago"
        return 0
    fi
    
    log "INFO" "Updating FDB entries from etcd"
    FDB_LAST_UPDATE_TIME=$current_time
    
    if ! command -v bridge &>/dev/null; then
        log "WARNING" "bridge command not available, cannot update FDB entries"
        return 1
    fi
    
    # Get all host status entries to find MAC addresses
    log "DEBUG" "Retrieving host status entries from etcd"
    local status_keys=$(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/")
    local host_macs=()
    local host_names=()
    local host_count=0
    
    # Check if we have host status entries
    if [ -z "$status_keys" ]; then
        log "WARNING" "No host status entries found in etcd. Host status registration may not be configured."
        # Try to register our own host status as fallback
        if type register_host_status &>/dev/null; then
            log "INFO" "Attempting to register local host status as fallback"
            register_host_status
            # Refresh the keys after registration
            status_keys=$(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/")
        fi
    fi
    
    # Process host status entries if available
    for key in $status_keys; do
        if [ -z "$key" ]; then
            continue
        fi
        
        local host=$(basename "$key")
        log "DEBUG" "Processing host status for $host"
        local status_data=$(etcd_get "$key")
        
        if [ -n "$status_data" ]; then
            local vtep_mac=""
            
            if command -v jq &>/dev/null; then
                vtep_mac=$(echo "$status_data" | jq -r '.vtep_mac')
            else
                vtep_mac=$(echo "$status_data" | grep -o '"vtep_mac":"[^"]*"' | cut -d'"' -f4)
            fi
            
            if [ -n "$vtep_mac" ] && [ "$vtep_mac" != "unknown" ] && [ "$vtep_mac" != "null" ]; then
                host_macs+=("$vtep_mac")
                host_names+=("$host")
                host_count=$((host_count + 1))
                log "DEBUG" "Found VTEP MAC for $host: $vtep_mac"
            else
                log "WARNING" "Invalid or missing VTEP MAC for host $host"
            fi
        else
            log "WARNING" "Empty status data for host $host"
        fi
    done
    
    log "INFO" "Found $host_count hosts with VTEP MAC addresses"
    
    # Get subnet entries to find IP addresses
    log "DEBUG" "Retrieving subnet entries from etcd"
    local subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    local host_ips=()
    local subnet_hosts=()
    local subnet_count=0
    
    if [ -z "$subnet_keys" ]; then
        log "WARNING" "No subnet entries found in etcd. Flannel may not be properly configured."
    fi
    
    for key in $subnet_keys; do
        if [ -z "$key" ]; then
            continue
        fi
        
        # Filter out non-subnet entries (like date-format strings)
        if ! echo "$key" | grep -q -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
            log "DEBUG" "Skipping non-subnet key: $key"
            continue
        fi
        
        local subnet_data=$(etcd_get "$key")
        
        if [ -n "$subnet_data" ]; then
            local public_ip=""
            local host=""
            
            if command -v jq &>/dev/null; then
                public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
                host=$(echo "$subnet_data" | jq -r '.hostname // ""')
            else
                public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
                host=$(echo "$subnet_data" | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4 || echo "")
            fi
            
            if [ -n "$public_ip" ] && [ "$public_ip" != "127.0.0.1" ] && [ "$public_ip" != "null" ]; then
                host_ips+=("$public_ip")
                subnet_hosts+=("$host")
                subnet_count=$((subnet_count + 1))
                log "DEBUG" "Found subnet entry with PublicIP: $public_ip, hostname: $host"
            else
                log "WARNING" "Invalid or localhost PublicIP in subnet data: $key"
            fi
        else 
            log "WARNING" "Empty subnet data for key: $key"
        fi
    done
    
    log "INFO" "Found $subnet_count subnet entries with valid PublicIPs"
    
    # Fallback: If no host status entries but we have subnet entries, try to discover VTEP MACs
    if [ $host_count -eq 0 ] && [ $subnet_count -gt 0 ]; then
        log "WARNING" "No host status entries with VTEP MACs found. Attempting fallback discovery."
        
        # Get local VTEP MAC for reference
        local local_vtep_mac=$(get_flannel_mac_address)
        if [ -n "$local_vtep_mac" ]; then
            log "DEBUG" "Local VTEP MAC: $local_vtep_mac"
            
            # Add our own host to the lists
            local local_hostname=$(hostname)
            host_macs+=("$local_vtep_mac")
            host_names+=("$local_hostname")
            host_count=$((host_count + 1))
            
            # Try to register our host status to help others
            if type register_host_status &>/dev/null; then
                log "INFO" "Registering local host status to help other hosts"
                register_host_status
            fi
        else
            log "ERROR" "Failed to get local VTEP MAC address for fallback"
        fi
        
        # Generate synthetic VTEP MACs for other hosts if needed
        # This is a last resort fallback that assumes standard VTEP MAC generation
        for i in "${!subnet_hosts[@]}"; do
            # Skip if it's our own host
            if [ "${subnet_hosts[$i]}" = "$(hostname)" ]; then
                continue
            fi
            
            # Skip if this host already has a VTEP MAC
            local found=false
            for j in "${!host_names[@]}"; do
                if [ "${host_names[$j]}" = "${subnet_hosts[$i]}" ]; then
                    found=true
                    break
                fi
            done
            
            if ! $found && [ -n "${subnet_hosts[$i]}" ]; then
                # Create a synthetic MAC based on host info
                # This is a fallback approach that may work for standard deployments
                local ip="${host_ips[$i]}"
                local ip_hex=$(echo "$ip" | awk -F. '{printf "02:42:%02x:%02x:%02x:%02x", $1, $2, $3, $4}')
                
                log "WARNING" "Using synthetic VTEP MAC $ip_hex for host ${subnet_hosts[$i]} ($ip)"
                host_macs+=("$ip_hex")
                host_names+=("${subnet_hosts[$i]}")
                host_count=$((host_count + 1))
            fi
        done
    fi
    
    # If we still have no MAC addresses, report an error
    if [ $host_count -eq 0 ]; then
        log "ERROR" "Failed to find any VTEP MAC addresses. FDB entries cannot be created."
        return 1
    fi
    
    # Current FDB entries
    local current_fdb=$(bridge fdb show dev flannel.1 2>/dev/null)
    local updated=0
    local added=0
    local removed=0
    
    # Process each host
    for i in "${!host_names[@]}"; do
        local host="${host_names[$i]}"
        local mac="${host_macs[$i]}"
        local ip=""
        
        # Skip ourselves
        if [ "$host" = "$(hostname)" ]; then
            log "DEBUG" "Skipping FDB entry for our own host: $host"
            continue
        fi
        
        # Find IP for this host
        for j in "${!subnet_hosts[@]}"; do
            if [ "${subnet_hosts[$j]}" = "$host" ]; then
                ip="${host_ips[$j]}"
                log "DEBUG" "Found IP $ip for host $host"
                break
            fi
        done
        
        # If no exact hostname match, try to find by IP pattern (for older entries without hostname)
        if [ -z "$ip" ]; then
            log "DEBUG" "No exact hostname match for $host, trying IP resolution"
            
            # Try to match by hostname resolution
            local resolved_ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1}')
            if [ -n "$resolved_ip" ]; then
                for j in "${!host_ips[@]}"; do
                    if [ "$resolved_ip" = "${host_ips[$j]}" ]; then
                        ip="${host_ips[$j]}"
                        log "DEBUG" "Matched $host to IP $ip by hostname resolution"
                        break
                    fi
                done
            fi
            
            # If still no match, try to use any available IP (best effort)
            if [ -z "$ip" ] && [ ${#host_ips[@]} -gt 0 ]; then
                # Use first available IP as fallback for this host
                for j in "${!subnet_hosts[@]}"; do
                    if [ -n "${host_ips[$j]}" ] && [ "${host_ips[$j]}" != "127.0.0.1" ]; then
                        ip="${host_ips[$j]}"
                        log "WARNING" "Using fallback IP $ip for host $host (no exact match)"
                        break
                    fi
                done
            fi
        fi
        
        if [ -n "$mac" ] && [ -n "$ip" ]; then
            # Determine appropriate endpoint IP (direct or via gateway)
            local endpoint_ip="$ip"
            if type get_host_gateway &>/dev/null; then
                local gateway=$(get_host_gateway "$ip")
                if [ -n "$gateway" ]; then
                    endpoint_ip="$gateway"
                    log "DEBUG" "Using gateway $endpoint_ip for FDB entry (host: $ip)"
                fi
            fi
            
            # Check if entry already exists with correct destination
            if echo "$current_fdb" | grep -q "$mac.*dst $endpoint_ip"; then
                log "DEBUG" "FDB entry for $host already exists and is correct: MAC=$mac, IP=$endpoint_ip"
            else
                # Remove any existing entry for this MAC
                if echo "$current_fdb" | grep -q "$mac"; then
                    log "INFO" "Updating FDB entry for $host: MAC=$mac, IP=$endpoint_ip"
                    bridge fdb del "$mac" dev flannel.1
                    updated=$((updated + 1))
                else
                    log "INFO" "Adding new FDB entry for $host: MAC=$mac, IP=$endpoint_ip"
                    added=$((added + 1))
                fi
                
                # Add the entry
                if bridge fdb add "$mac" dev flannel.1 dst "$endpoint_ip"; then
                    log "DEBUG" "Successfully added FDB entry: $mac -> $endpoint_ip"
                else 
                    log "ERROR" "Failed to add FDB entry: $mac -> $endpoint_ip"
                fi
            fi
        else 
            if [ -z "$mac" ]; then
                log "WARNING" "Missing MAC address for host $host"
            fi
            if [ -z "$ip" ]; then
                log "WARNING" "Missing IP address for host $host"
            fi
        fi
    done
    
    # Look for entries to remove (MAC addresses not in our known list)
    while read -r entry; do
        if [ -z "$entry" ]; then
            continue
        fi
        
        # Extract MAC address
        local entry_mac=$(echo "$entry" | awk '{print $1}')
        
        # Check if this MAC is in our known list
        local known=false
        for mac in "${host_macs[@]}"; do
            if [ "$mac" = "$entry_mac" ]; then
                known=true
                break
            fi
        done
        
        if ! $known; then
            # MAC not in our known list, remove it
            log "INFO" "Removing unknown FDB entry: $entry"
            bridge fdb del "$entry_mac" dev flannel.1
            removed=$((removed + 1))
        fi
    done <<< "$current_fdb"
    
    log "INFO" "FDB update completed: $added added, $updated updated, $removed removed"
    
    # Backup current FDB entries
    backup_fdb_entries
    
    return 0
}


# ==========================================
# Interface management functions
# ==========================================

# Fix MTU on flannel interface
# Usage: fix_flannel_mtu [interface] [target_mtu]
fix_flannel_mtu() {
    local interface="${1:-flannel.1}"
    local target_mtu="${2:-1370}"
    
    # Check if interface exists
    if ! ip link show "$interface" &>/dev/null; then
        log "WARNING" "Interface $interface does not exist"
        return 1
    fi
    
    # Get current MTU
    local current_mtu=$(ip link show "$interface" | grep -o 'mtu [0-9]*' | cut -d' ' -f2)
    
    if [ "$current_mtu" != "$target_mtu" ]; then
        log "INFO" "Setting $interface MTU to $target_mtu (was $current_mtu)"
        
        if ip link set "$interface" mtu "$target_mtu"; then
            log "INFO" "MTU updated successfully"
            return 0
        else
            log "ERROR" "Failed to set MTU on $interface"
            return 1
        fi
    else
        log "DEBUG" "MTU already set to $target_mtu on $interface"
        return 0
    fi
}

# Export necessary functions and variables
export -f init_fdb_management backup_fdb_entries restore_fdb_from_backup
export -f update_fdb_entries_from_etcd fix_flannel_mtu
export FDB_LAST_UPDATE_TIME FDB_UPDATE_INTERVAL FDB_STATE_DIR FDB_BACKUP_FILE
