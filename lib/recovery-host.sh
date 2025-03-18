#!/bin/bash
# recovery-host.sh
# Host status management for flannel-registrar
# Provides registration and monitoring of host status in etcd

# Module information
MODULE_NAME="recovery-host"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "network-lib")

# ==========================================
# Global variables
# ==========================================

# Host status update interval in seconds
HOST_STATUS_UPDATE_INTERVAL=${HOST_STATUS_UPDATE_INTERVAL:-300}

# Host status state directory
HOST_STATUS_STATE_DIR="${COMMON_STATE_DIR}/host_status"

# Host status cache timeout in seconds
HOST_STATUS_CACHE_TIMEOUT=${HOST_STATUS_CACHE_TIMEOUT:-60}

# Cache for host status data (to reduce etcd calls)
declare -A HOST_STATUS_CACHE
declare -A HOST_STATUS_CACHE_TIMESTAMPS

# ==========================================
# Module initialization
# ==========================================

# Initialize recovery-host module
# Usage: init_recovery_host
# Returns: 0 on success, 1 on failure
init_recovery_host() {
    # Check dependencies
    for dep in log etcd_get etcd_put etcd_list_keys get_flannel_mac_address get_primary_ip; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found. Make sure all dependencies are loaded."
            return 1
        fi
    done
    
    # Create state directory if it doesn't exist
    mkdir -p "$HOST_STATUS_STATE_DIR" || {
        log "ERROR" "Failed to create host status state directory: $HOST_STATUS_STATE_DIR"
        return 1
    }
    
    # Initialize cache arrays
    declare -A HOST_STATUS_CACHE
    declare -A HOST_STATUS_CACHE_TIMESTAMPS
    
    # Register host status at startup
    if ! register_host_as_active; then
        log "WARNING" "Failed to register host status during initialization, will retry later"
        # Don't fail initialization due to this - we'll retry later
    fi
    
    # Schedule cleanup of stale entries
    clean_stale_host_status || log "WARNING" "Failed to clean up stale host status entries"
    
    log "INFO" "Initialized recovery-host module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Host status registration functions
# ==========================================

# Register this host as active in etcd
# Usage: register_host_as_active
# Returns: 0 on success, 1 on failure
register_host_as_active() {
    local hostname="${HOST_NAME:-$(hostname)}"
    local data=$(get_host_status_data)
    
    if [ -z "$data" ]; then
        log "ERROR" "Failed to generate host status data"
        return 1
    fi
    
    local key=$(create_host_status_key "$hostname")
    
    log "INFO" "Registering host status for $hostname in etcd"
    
    # Try to write to etcd with retry
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        if etcd_put "$key" "$data"; then
            log "INFO" "Successfully registered host status for $hostname"
            
            # Save registration time
            echo "$(date +%s)" > "$HOST_STATUS_STATE_DIR/last_registration"
            
            # Update cache
            HOST_STATUS_CACHE["$hostname"]="$data"
            HOST_STATUS_CACHE_TIMESTAMPS["$hostname"]=$(date +%s)
            
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        log "WARNING" "Failed to register host status (attempt $retry_count/$max_retries), retrying..."
        sleep 2
    done
    
    log "ERROR" "Failed to register host status after $max_retries attempts"
    return 1
}

# Refresh host status in etcd
# Usage: refresh_host_status
# Returns: 0 on success, 1 on failure
refresh_host_status() {
    local hostname="${HOST_NAME:-$(hostname)}"
    local last_registration=0
    
    # Check if we have a record of last registration time
    if [ -f "$HOST_STATUS_STATE_DIR/last_registration" ]; then
        last_registration=$(cat "$HOST_STATUS_STATE_DIR/last_registration")
    fi
    
    local current_time=$(date +%s)
    local time_since_last=$((current_time - last_registration))
    
    # If we've registered recently, no need to refresh
    if [ $time_since_last -lt $HOST_STATUS_UPDATE_INTERVAL ]; then
        log "DEBUG" "Host status refreshed recently ($time_since_last seconds ago), skipping"
        return 0
    fi
    
    # Generate fresh status data with current timestamp
    local data=$(get_host_status_data)
    
    if [ -z "$data" ]; then
        log "ERROR" "Failed to generate host status data for refresh"
        return 1
    fi
    
    local key=$(create_host_status_key "$hostname")
    
    log "INFO" "Refreshing host status for $hostname in etcd"
    
    if etcd_put "$key" "$data"; then
        log "INFO" "Successfully refreshed host status for $hostname"
        
        # Update registration time
        echo "$(date +%s)" > "$HOST_STATUS_STATE_DIR/last_registration"
        
        # Update cache
        HOST_STATUS_CACHE["$hostname"]="$data"
        HOST_STATUS_CACHE_TIMESTAMPS["$hostname"]=$(date +%s)
        
        return 0
    else
        log "ERROR" "Failed to refresh host status"
        return 1
    fi
}

# Generate host status data for this host
# Usage: data=$(get_host_status_data)
# Returns: JSON host status data
get_host_status_data() {
    local hostname="${HOST_NAME:-$(hostname)}"
    local vtep_mac=$(get_flannel_mac_address)
    local primary_ip=$(get_primary_ip)
    
    if [ -z "$vtep_mac" ]; then
        log "ERROR" "Failed to get VTEP MAC address for host status"
        return 1
    fi
    
    if [ -z "$primary_ip" ]; then
        log "ERROR" "Failed to get primary IP address for host status"
        return 1
    fi
    
    # Create JSON data using flannel's expected format
    echo "{\"PublicIP\":\"$primary_ip\",\"PublicIPv6\":null,\"BackendType\":\"vxlan\",\"BackendData\":{\"VNI\":1,\"VtepMAC\":\"$vtep_mac\"}}"
    return 0
}

# Create etcd key for host status
# Usage: key=$(create_host_status_key "hostname")
# Returns: Etcd key for host status
create_host_status_key() {
    local host="$1"
    
    if [ -z "$host" ]; then
        log "ERROR" "No hostname provided for host status key"
        return 1
    fi
    
    echo "${FLANNEL_CONFIG_PREFIX}/_host_status/$host"
    return 0
}

# ==========================================
# Host status retrieval functions
# ==========================================

# Get status of a remote host from etcd
# Usage: status=$(get_remote_host_status "hostname" [force_refresh])
# Arguments:
#   hostname - Hostname to check
#   force_refresh - If set to "true", bypass cache
# Returns: JSON host status data
get_remote_host_status() {
    local hostname="$1"
    local force_refresh="${2:-false}"
    
    if [ -z "$hostname" ]; then
        log "ERROR" "No hostname provided for status retrieval"
        return 1
    fi
    
    # Check cache first (unless force refresh requested)
    if [ "$force_refresh" != "true" ] && [ -n "${HOST_STATUS_CACHE[$hostname]}" ]; then
        local cache_timestamp=${HOST_STATUS_CACHE_TIMESTAMPS[$hostname]:-0}
        local current_time=$(date +%s)
        
        # If cache is still valid, use it
        if [ $((current_time - cache_timestamp)) -lt $HOST_STATUS_CACHE_TIMEOUT ]; then
            log "DEBUG" "Using cached host status for $hostname"
            echo "${HOST_STATUS_CACHE[$hostname]}"
            return 0
        else
            log "DEBUG" "Cached host status for $hostname expired, refreshing"
        fi
    fi
    
    # Get status from etcd
    local key=$(create_host_status_key "$hostname")
    local status=$(etcd_get "$key")
    
    if [ -z "$status" ]; then
        log "DEBUG" "No status found for host $hostname"
        return 1
    fi
    
    # Update cache
    HOST_STATUS_CACHE["$hostname"]="$status"
    HOST_STATUS_CACHE_TIMESTAMPS["$hostname"]=$(date +%s)
    
    echo "$status"
    return 0
}

# Get all active hosts from etcd
# Usage: hosts=$(get_all_active_hosts [max_age])
# Arguments:
#   max_age - Maximum age in seconds for a host to be considered active (default: 600)
# Returns: List of active host names, one per line
get_all_active_hosts() {
    local max_age="${1:-600}"  # Default 10 minutes
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - max_age))
    local active_hosts=""
    
    # Get all host status keys
    local status_keys=$(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/")
    log "DEBUG" "Checking etcd for host status keys: (${FLANNEL_CONFIG_PREFIX}/_host_status/)"
    log "DEBUG" "Raw status keys: ($status_keys)"
    
    if [ -z "$status_keys" ]; then
        log "WARNING" "No host status entries found in etcd"
        return 1
    fi
    
    log "DEBUG" "Found $(echo "$status_keys" | wc -l) host status entries in etcd"
    
    # Process each key
    for key in $status_keys; do
        if [ -z "$key" ]; then
            continue
        fi
        
        local hostname=$(basename "$key")
        local status=$(etcd_get "$key")
        
        if [ -n "$status" ]; then
            local timestamp=0
            
            # Extract timestamp
            if command -v jq &>/dev/null; then
                timestamp=$(echo "$status" | jq -r '.timestamp // 0')
            else
                timestamp=$(echo "$status" | grep -o '"timestamp":[0-9]*' | cut -d':' -f2 || echo "0")
            fi
            
            # Check if host is still active
            if [ "$timestamp" -ge "$cutoff_time" ]; then
                active_hosts="${active_hosts}${hostname}\n"
                
                # Update cache
                HOST_STATUS_CACHE["$hostname"]="$status"
                HOST_STATUS_CACHE_TIMESTAMPS["$hostname"]=$(date +%s)
            else
                log "DEBUG" "Host $hostname has stale status (timestamp: $timestamp, cutoff: $cutoff_time)"
            fi
        fi
    done
    
    if [ -z "$active_hosts" ]; then
        log "WARNING" "No active hosts found"
        return 1
    fi
    
    echo -e "$active_hosts"
    return 0
}

# Check if host status registration exists and is valid
# Usage: check_host_status_registration "hostname" [max_age]
# Arguments:
#   hostname - Hostname to check
#   max_age - Maximum age in seconds for registration to be considered valid (default: 600)
# Returns: 0 if registration exists and is valid, 1 otherwise
check_host_status_registration() {
    local hostname="$1"
    local max_age="${2:-600}"  # Default 10 minutes
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - max_age))
    
    if [ -z "$hostname" ]; then
        hostname="${HOST_NAME:-$(hostname)}"
    fi
    
    # Get status data
    local status=$(get_remote_host_status "$hostname" true)  # Force refresh
    
    if [ -z "$status" ]; then
        log "DEBUG" "No status registration found for $hostname"
        return 1
    fi
    
    # Extract and check timestamp
    local timestamp=0
    
    if command -v jq &>/dev/null; then
        timestamp=$(echo "$status" | jq -r '.timestamp // 0')
    else
        timestamp=$(echo "$status" | grep -o '"timestamp":[0-9]*' | cut -d':' -f2 || echo "0")
    fi
    
    if [ "$timestamp" -ge "$cutoff_time" ]; then
        log "DEBUG" "Valid host status registration found for $hostname (age: $((current_time - timestamp))s)"
        return 0
    else
        log "DEBUG" "Stale host status registration found for $hostname (age: $((current_time - timestamp))s)"
        return 1
    fi
}

# Check if a host is currently active
# Usage: is_host_active "hostname" [max_age]
# Arguments:
#   hostname - Hostname to check
#   max_age - Maximum age in seconds for a host to be considered active (default: 600)
# Returns: 0 if host is active, 1 otherwise
is_host_active() {
    local hostname="$1"
    local max_age="${2:-600}"  # Default 10 minutes
    
    if [ -z "$hostname" ]; then
        log "ERROR" "No hostname provided for is_host_active"
        return 1
    fi
    
    # Just delegate to check_host_status_registration
    check_host_status_registration "$hostname" "$max_age"
}

# Clean up stale host status entries
# Usage: clean_stale_host_status [max_age]
# Arguments:
#   max_age - Maximum age in seconds before an entry is considered stale (default: 1800)
# Returns: 0 on success, 1 on failure
clean_stale_host_status() {
    local max_age="${1:-1800}"  # Default 30 minutes
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - max_age))
    local cleaned=0
    
    # Get all host status keys
    local status_keys=$(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/")
    
    if [ -z "$status_keys" ]; then
        log "DEBUG" "No host status entries found to clean up"
        return 0
    fi
    
    # Process each key
    for key in $status_keys; do
        if [ -z "$key" ]; then
            continue
        fi
        
        local hostname=$(basename "$key")
        
        # Don't clean up our own entry
        if [ "$hostname" = "${HOST_NAME:-$(hostname)}" ]; then
            log "DEBUG" "Skipping our own host status entry for cleanup"
            continue
        fi
        
        local status=$(etcd_get "$key")
        
        if [ -n "$status" ]; then
            local timestamp=0
            
            # Extract timestamp
            if command -v jq &>/dev/null; then
                timestamp=$(echo "$status" | jq -r '.timestamp // 0')
            else
                timestamp=$(echo "$status" | grep -o '"timestamp":[0-9]*' | cut -d':' -f2 || echo "0")
            fi
            
            # Check if entry is stale
            if [ "$timestamp" -lt "$cutoff_time" ]; then
                log "INFO" "Cleaning up stale host status for $hostname (age: $((current_time - timestamp))s)"
                
                if etcd_delete "$key"; then
                    cleaned=$((cleaned + 1))
                    
                    # Remove from cache
                    unset HOST_STATUS_CACHE["$hostname"]
                    unset HOST_STATUS_CACHE_TIMESTAMPS["$hostname"]
                else
                    log "WARNING" "Failed to delete stale host status entry for $hostname"
                fi
            fi
        fi
    done
    
    log "INFO" "Cleaned up $cleaned stale host status entries"
    return 0
}

# Export necessary functions and variables
export -f init_recovery_host
export -f register_host_as_active
export -f refresh_host_status
export -f get_host_status_data
export -f create_host_status_key
export -f get_remote_host_status
export -f get_all_active_hosts
export -f check_host_status_registration
export -f is_host_active
export -f clean_stale_host_status

export HOST_STATUS_UPDATE_INTERVAL
export HOST_STATUS_STATE_DIR
export HOST_STATUS_CACHE_TIMEOUT
