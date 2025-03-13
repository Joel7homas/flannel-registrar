#!/bin/bash
# connectivity-core.sh
# Core functions for network connectivity testing and monitoring
# Part of flannel-registrar's modular network management system

# Module information
MODULE_NAME="connectivity-core"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "network-lib")

# ==========================================
# Global variables for connectivity testing
# ==========================================

# Test intervals and timeouts
CONN_TEST_INTERVAL=${CONN_TEST_INTERVAL:-300}  # Default 5 minutes between full tests
CONN_RETRY_COUNT=${CONN_RETRY_COUNT:-3}        # Number of retries before declaring failure
CONN_RETRY_DELAY=${CONN_RETRY_DELAY:-2}        # Seconds between retries
CONN_TEST_TIMEOUT=${CONN_TEST_TIMEOUT:-3}      # Seconds before timeout on ping/curl tests

# State tracking
CONN_LAST_TEST_TIME=0                          # Timestamp of last full test
CONN_LAST_BACKUP_TIME=0                        # Timestamp of last backup

# Directories and files
CONN_STATE_DIR="${COMMON_STATE_DIR}/connectivity"  # State directory
CONN_STATUS_FILE="${CONN_STATE_DIR}/connectivity_status.dat"  # Status file
CONN_BACKUP_FILE="${CONN_STATE_DIR}/conn_backup.json"  # Backup file

# Status tracking
declare -A CONN_HOST_STATUS                    # Associative array for host status
declare -A CONN_CALLBACKS                      # Associative array for callbacks

# Status codes
CONN_STATUS_UNKNOWN=0
CONN_STATUS_UP=1
CONN_STATUS_DOWN=2
CONN_STATUS_DEGRADED=3

# ==========================================
# Module initialization
# ==========================================

# Initialize connectivity module
# Usage: init_connectivity
# Returns: 0 on success, 1 on failure
init_connectivity() {
    # Check dependencies
    for dep in log etcd_get is_valid_ip; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found"
            return 1
        fi
    done
    
    # Create state directory
    mkdir -p "$CONN_STATE_DIR" || {
        log "ERROR" "Failed to create connectivity state directory"
        return 1
    }
    
    # Initialize associative arrays
    declare -A CONN_HOST_STATUS
    declare -g -A CONN_CALLBACKS
    
    # Restore from backup if available
    if [ -f "$CONN_STATUS_FILE" ]; then
        log "INFO" "Restoring connectivity status from file"
        restore_connectivity_status
    fi
    
    log "INFO" "Initialized connectivity-core module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Utility functions
# ==========================================

# Get first usable IP in a subnet
# Usage: get_first_ip_in_subnet subnet
# Arguments:
#   subnet - CIDR subnet
# Returns: First usable IP address or empty string on failure
get_first_ip_in_subnet() {
    local subnet="$1"
    
    if [ -z "$subnet" ] || ! is_valid_cidr "$subnet"; then
        log "WARNING" "Invalid subnet format: $subnet"
        return 1
    fi
    
    # Extract subnet base
    local subnet_base=$(echo "$subnet" | cut -d'/' -f1)
    
    # For standard flannel networks, use the first host address
    local first_ip="${subnet_base%.*}.$((${subnet_base##*.} + 1))"
    
    echo "$first_ip"
    return 0
}

# Execute a registered callback if it exists
# Usage: execute_connectivity_callback trigger_point [arguments]
# Arguments:
#   trigger_point - The callback trigger point
#   arguments - Additional arguments to pass to callback
# Returns: 0 on success, 1 on failure or if callback doesn't exist
execute_connectivity_callback() {
    local trigger_point="$1"
    shift
    
    if [ -z "$trigger_point" ]; then
        log "ERROR" "No trigger point specified for callback"
        return 1
    fi
    
    # Initialize array if not already done
    declare -A CONN_CALLBACKS
    
    # Check if callback exists for this trigger point
    if [ -n "${CONN_CALLBACKS[$trigger_point]}" ]; then
        local callback_function="${CONN_CALLBACKS[$trigger_point]}"
        
        # Execute the callback with any additional arguments
        if type "$callback_function" &>/dev/null; then
            log "DEBUG" "Executing callback for $trigger_point: $callback_function"
            "$callback_function" "$@"
            return $?
        else
            log "WARNING" "Callback function $callback_function not found"
            return 1
        fi
    fi
    
    # No callback registered for this trigger point
    return 1
}

# ==========================================
# Core connectivity testing functions
# ==========================================

# Test basic connectivity to a remote host
# Usage: test_host_connectivity host_ip [timeout] [retry]
# Arguments:
#   host_ip - IP address to test
#   timeout - Seconds before timeout (default: CONN_TEST_TIMEOUT)
#   retry - Number of retry attempts (default: CONN_RETRY_COUNT)
# Returns: 0 if reachable, 1 if not
test_host_connectivity() {
    local host_ip="$1"
    local timeout="${2:-$CONN_TEST_TIMEOUT}"
    local retry="${3:-$CONN_RETRY_COUNT}"
    
    # Initialize status array if needed
    declare -A CONN_HOST_STATUS
    
    # Basic validation
    if [ -z "$host_ip" ] || ! is_valid_ip "$host_ip"; then
        log "WARNING" "Invalid IP address: $host_ip"
        CONN_HOST_STATUS["$host_ip"]="invalid"
        return 1
    fi
    
    log "DEBUG" "Testing connectivity to host $host_ip"
    execute_connectivity_callback "pre_test" "$host_ip"
    
    # Try to ping the host with retries
    local success=false
    for ((i=1; i<=retry; i++)); do
        if ping -c 1 -W "$timeout" "$host_ip" &>/dev/null; then
            success=true
            break
        fi
        sleep "$CONN_RETRY_DELAY"
    done
    
    # Update status and return result
    if $success; then
        CONN_HOST_STATUS["$host_ip"]="up"
        log "DEBUG" "Host $host_ip is reachable"
        return 0
    else
        CONN_HOST_STATUS["$host_ip"]="down"
        log "WARNING" "Host $host_ip is unreachable"
        execute_connectivity_callback "connectivity_failure" "$host_ip"
        return 1
    fi
}

# Test flannel VXLAN connectivity to a remote subnet
# Usage: test_flannel_connectivity subnet [test_ip] [timeout] [retry]
# Arguments:
#   subnet - CIDR subnet to test
#   test_ip - IP address to test (default: first usable IP in subnet)
#   timeout - Seconds before timeout (default: CONN_TEST_TIMEOUT)
#   retry - Number of retry attempts (default: CONN_RETRY_COUNT)
# Returns: 0 if reachable, 1 if not
test_flannel_connectivity() {
    local subnet="$1"
    local test_ip="$2"
    local timeout="${3:-$CONN_TEST_TIMEOUT}"
    local retry="${4:-$CONN_RETRY_COUNT}"
    
    # Initialize status array if needed
    declare -A CONN_HOST_STATUS
    
    # Validate subnet
    if [ -z "$subnet" ] || ! is_valid_cidr "$subnet"; then
        log "WARNING" "Invalid subnet format: $subnet"
        CONN_HOST_STATUS["$subnet"]="invalid"
        return 1
    fi
    
    # If no test IP provided, use the first usable IP in the subnet
    if [ -z "$test_ip" ]; then
        test_ip=$(get_first_ip_in_subnet "$subnet")
        if [ -z "$test_ip" ]; then
            log "WARNING" "Could not determine test IP for subnet $subnet"
            CONN_HOST_STATUS["$subnet"]="invalid"
            return 1
        fi
    fi
    
    log "DEBUG" "Testing flannel connectivity to $subnet (using $test_ip)"
    execute_connectivity_callback "pre_test" "$subnet"
    
    # Test connectivity using ping with retries
    local success=false
    for ((i=1; i<=retry; i++)); do
        if ping -c 1 -W "$timeout" "$test_ip" &>/dev/null; then
            success=true
            break
        fi
        sleep "$CONN_RETRY_DELAY"
    done
    
    # Update status and return result
    if $success; then
        CONN_HOST_STATUS["$subnet"]="up"
        log "DEBUG" "Subnet $subnet is reachable (pinged $test_ip)"
        return 0
    else
        CONN_HOST_STATUS["$subnet"]="down"
        log "WARNING" "Subnet $subnet is unreachable (tried $test_ip)"
        execute_connectivity_callback "connectivity_failure" "$subnet"
        return 1
    fi
}

# Test TCP connectivity to a service on a remote host
# Usage: test_service_connectivity host_ip port [timeout] [retry]
# Arguments:
#   host_ip - IP address of host
#   port - TCP port to test
#   timeout - Seconds before timeout (default: CONN_TEST_TIMEOUT)
#   retry - Number of retry attempts (default: CONN_RETRY_COUNT)
# Returns: 0 if reachable, 1 if not
test_service_connectivity() {
    local host_ip="$1"
    local port="$2"
    local timeout="${3:-$CONN_TEST_TIMEOUT}"
    local retry="${4:-$CONN_RETRY_COUNT}"
    
    # Initialize status array if needed
    declare -A CONN_HOST_STATUS
    
    # Basic validation
    if [ -z "$host_ip" ] || ! is_valid_ip "$host_ip" ]; then
        log "WARNING" "Invalid IP address: $host_ip"
        return 1
    fi
    
    if [ -z "$port" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log "WARNING" "Invalid port number: $port"
        return 1
    fi
    
    local status_key="${host_ip}:${port}"
    log "DEBUG" "Testing service connectivity to $status_key"
    execute_connectivity_callback "pre_test" "$host_ip" "$port"
    
    # Test TCP connectivity with retries using bash's /dev/tcp
    local success=false
    for ((i=1; i<=retry; i++)); do
        if timeout "$timeout" bash -c "echo > /dev/tcp/$host_ip/$port" 2>/dev/null; then
            success=true
            break
        fi
        sleep "$CONN_RETRY_DELAY"
    done
    
    # Update status and return result
    if $success; then
        CONN_HOST_STATUS["$status_key"]="up"
        log "DEBUG" "Service $status_key is reachable"
        return 0
    else
        CONN_HOST_STATUS["$status_key"]="down"
        log "WARNING" "Service $status_key is unreachable"
        execute_connectivity_callback "connectivity_failure" "$host_ip" "$port"
        return 1
    fi
}

# Check if flannel interfaces have active traffic
# Usage: check_interface_traffic [interface]
# Arguments:
#   interface - Interface name to check (default: flannel.1)
# Returns: 0 if traffic is balanced, 1 if issues detected
check_interface_traffic() {
    local interface="${1:-flannel.1}"
    
    # Check if interface exists
    if ! ip link show "$interface" &>/dev/null; then
        log "WARNING" "Interface $interface does not exist"
        execute_connectivity_callback "interface_issue" "$interface" "missing"
        return 1
    fi
    
    # Get current rx/tx packet counts
    local stats=$(ip -s link show "$interface")
    local rx_packets=$(echo "$stats" | grep -A1 RX | tail -1 | awk '{print $1}')
    local tx_packets=$(echo "$stats" | grep -A1 TX | tail -1 | awk '{print $1}')
    
    # Store current counts and time for rate calculation
    local current_time=$(date +%s)
    local traffic_file="${CONN_STATE_DIR}/traffic_${interface//\//_}.dat"
    
    # Load previous values if available
    local prev_time=0
    local prev_rx=0
    local prev_tx=0
    
    if [ -f "$traffic_file" ]; then
        source "$traffic_file" 2>/dev/null
    fi
    
    # Calculate packets per second
    local rx_pps=0
    local tx_pps=0
    local time_diff=$((current_time - prev_time))
    
    if [ $time_diff -gt 0 ]; then
        rx_pps=$(( (rx_packets - prev_rx) / time_diff ))
        tx_pps=$(( (tx_packets - prev_tx) / time_diff ))
    fi
    
    # Save current values for next check
    echo "prev_time=$current_time" > "$traffic_file"
    echo "prev_rx=$rx_packets" >> "$traffic_file"
    echo "prev_tx=$tx_packets" >> "$traffic_file"
    
    # Check for one-way communication issues (significant traffic imbalance)
    if [ $rx_pps -gt 5 ] && [ $tx_pps -lt 1 ]; then
        log "WARNING" "One-way traffic on $interface: RX=$rx_pps pps, TX=$tx_pps pps"
        execute_connectivity_callback "interface_issue" "$interface" "one_way_rx"
        return 1
    fi
    
    if [ $tx_pps -gt 5 ] && [ $rx_pps -lt 1 ]; then
        log "WARNING" "One-way traffic on $interface: RX=$rx_pps pps, TX=$tx_pps pps"
        execute_connectivity_callback "interface_issue" "$interface" "one_way_tx"
        return 1
    fi
    
    log "DEBUG" "Interface $interface traffic: RX=$rx_pps pps, TX=$tx_pps pps"
    return 0
}

# Test basic container connectivity 
# Usage: test_basic_container_connectivity network subnet
# Arguments:
#   network - Docker network name
#   subnet - Target subnet to test
# Returns: 0 if connection works, 1 if issues detected
test_basic_container_connectivity() {
    local network="$1"
    local subnet="$2"
    
    # Basic validation
    if [ -z "$network" ]; then
        log "WARNING" "No network specified for container connectivity test"
        return 1
    fi
    
    if [ -z "$subnet" ] || ! is_valid_cidr "$subnet"; then
        log "WARNING" "Invalid subnet format: $subnet"
        return 1
    fi
    
    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        log "WARNING" "Docker command not available"
        return 1
    fi
    
    # Check if network exists
    if ! docker network ls --format '{{.Name}}' | grep -q "^$network$"; then
        log "WARNING" "Docker network $network does not exist"
        return 1
    fi
    
    # Get the first usable IP in the subnet for testing
    local test_ip=$(get_first_ip_in_subnet "$subnet")
    if [ -z "$test_ip" ]; then
        log "WARNING" "Could not determine test IP for subnet $subnet"
        return 1
    fi
    
    # Find a container on the specified network, or create a temporary one
    local test_container=$(docker ps --filter network="$network" --format "{{.Names}}" | head -1)
    local cleanup_container=false
    
    if [ -z "$test_container" ]; then
        test_container="flannel-connectivity-test-$$"
        if ! docker run --rm -d --name "$test_container" --network "$network" alpine:latest sleep 30 >/dev/null; then
            log "ERROR" "Failed to create test container on network $network"
            return 1
        fi
        cleanup_container=true
    fi
    
    # Test connectivity from container to subnet
    log "DEBUG" "Testing connectivity from $test_container to $test_ip"
    local result=$(docker exec "$test_container" ping -c 1 -W 3 "$test_ip" 2>&1)
    local exit_code=$?
    
    # Clean up if we created a temporary container
    if $cleanup_container; then
        docker rm -f "$test_container" >/dev/null 2>&1
    fi
    
    if [ $exit_code -eq 0 ]; then
        log "DEBUG" "Container connectivity test passed: $network to $subnet"
        return 0
    else
        log "WARNING" "Container connectivity test failed: $network to $subnet"
        return 1
    fi
}

# ==========================================
# Comprehensive testing and state management
# ==========================================

# Run comprehensive connectivity tests to all known hosts/subnets
# Usage: run_connectivity_tests
# Returns: 0 if all critical connections work, 1 if issues detected
run_connectivity_tests() {
    local current_time=$(date +%s)
    
    # Only run full test every CONN_TEST_INTERVAL seconds
    if [ $((current_time - CONN_LAST_TEST_TIME)) -lt $CONN_TEST_INTERVAL ]; then
        return 0
    fi
    
    log "INFO" "Running comprehensive connectivity tests"
    CONN_LAST_TEST_TIME=$current_time
    execute_connectivity_callback "pre_test" || true
    local has_failures=false
    
    # Test flannel interface condition
    check_interface_traffic "flannel.1" || has_failures=true
    
    # Get all subnet entries with their PublicIPs from etcd
    local subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    if [ -z "$subnet_keys" ]; then
        log "WARNING" "No subnet entries found in etcd"
        return 1
    fi
    
    # Test connectivity to each flannel subnet
    local connectivity_issues=0
    local subnets_tested=0
    
    for key in $subnet_keys; do
        # Extract subnet
        local subnet_id=$(basename "$key")
        local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
        
        # Get the host IP for this subnet
        local subnet_data=$(etcd_get "$key")
        local public_ip=""
        
        if [ -n "$subnet_data" ]; then
            if command -v jq &>/dev/null; then
                public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
            else
                public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
            fi
        fi
        
        # Skip our own subnet
        if ip route show | grep -q "$cidr_subnet.*dev flannel.1"; then
            continue
        fi
        
        # Skip subnets with localhost IP
        if [ "$public_ip" = "127.0.0.1" ]; then
            continue
        fi
        
        subnets_tested=$((subnets_tested + 1))
        
        # First test connectivity to the host itself
        if ! test_host_connectivity "$public_ip"; then
            log "WARNING" "Cannot reach host $public_ip"
            connectivity_issues=$((connectivity_issues + 1))
            continue
        fi
        
        # Then test flannel subnet connectivity
        if ! test_flannel_connectivity "$cidr_subnet"; then
            log "WARNING" "Cannot reach flannel subnet $cidr_subnet"
            connectivity_issues=$((connectivity_issues + 1))
        fi
    done
    
    # Test container connectivity for essential services
    for network in "caddy-public-net" "caddy_net"; do
        # Skip if this network doesn't exist locally
        if ! docker network ls --format '{{.Name}}' | grep -q "^$network$"; then
            continue
        fi
        
        for key in $subnet_keys; do
            # Skip our own subnet
            local subnet_id=$(basename "$key")
            local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
            
            if ip route show | grep -q "$cidr_subnet.*dev flannel.1"; then
                continue
            fi
            
            if ! test_basic_container_connectivity "$network" "$cidr_subnet"; then
                has_failures=true
            fi
        done
    done
    
    execute_connectivity_callback "post_test" $subnets_tested $connectivity_issues || true
    
    # Backup connectivity status
    backup_connectivity_status
    
    if $has_failures || [ $connectivity_issues -gt 0 ]; then
        log "WARNING" "Connectivity tests completed with some failures"
        return 1
    else
        log "INFO" "All connectivity tests passed successfully"
        return 0
    fi
}

# ==========================================
# Status backup and restore functions
# ==========================================

# Backup connectivity status to persistent storage
# Usage: backup_connectivity_status
# Returns: 0 on success, 1 on failure
backup_connectivity_status() {
    local current_time=$(date +%s)
    CONN_LAST_BACKUP_TIME=$current_time
    
    # Create JSON representation of connectivity status
    local json="{"
    local first=true
    
    # Add basic metadata
    json+="\"timestamp\":$current_time,"
    json+="\"host\":\"$(hostname)\","
    
    # Add test information
    json+="\"last_test\":$CONN_LAST_TEST_TIME,"
    
    # Add host status entries
    json+="\"hosts\":{"
    
    local host_entry_added=false
    for host in "${!CONN_HOST_STATUS[@]}"; do
        if [ -n "$host" ]; then
            if $host_entry_added; then
                json+=","
            fi
            json+="\"$host\":\"${CONN_HOST_STATUS[$host]}\""
            host_entry_added=true
        fi
    done
    
    json+="}}"
    
    # Save to file
    echo "$json" > "$CONN_BACKUP_FILE"
    log "DEBUG" "Backed up connectivity status to $CONN_BACKUP_FILE"
    
    # Save raw status data in simple format for easy parsing
    for host in "${!CONN_HOST_STATUS[@]}"; do
        echo "$host=${CONN_HOST_STATUS[$host]}" >> "$CONN_STATUS_FILE.new"
    done
    
    mv "$CONN_STATUS_FILE.new" "$CONN_STATUS_FILE" 2>/dev/null
    
    return 0
}

# Restore connectivity status from backup
# Usage: restore_connectivity_status
# Returns: 0 on success, 1 on failure
restore_connectivity_status() {
    # Initialize status array
    declare -A CONN_HOST_STATUS
    
    # First try to restore from status file (simpler format)
    if [ -f "$CONN_STATUS_FILE" ]; then
        log "DEBUG" "Restoring connectivity status from $CONN_STATUS_FILE"
        
        while IFS='=' read -r host status; do
            if [ -n "$host" ] && [ -n "$status" ]; then
                CONN_HOST_STATUS["$host"]="$status"
            fi
        done < "$CONN_STATUS_FILE"
        
        log "INFO" "Restored status for ${#CONN_HOST_STATUS[@]} hosts"
        return 0
    fi
    
    # Fall back to JSON backup if status file not available
    if [ -f "$CONN_BACKUP_FILE" ]; then
        log "DEBUG" "Restoring connectivity status from $CONN_BACKUP_FILE"
        
        # Parse JSON with jq if available
        if command -v jq &>/dev/null; then
            local hosts_json=$(jq -r '.hosts' "$CONN_BACKUP_FILE")
            
            # Extract keys and values
            for host in $(jq -r '.hosts | keys[]' "$CONN_BACKUP_FILE"); do
                local status=$(jq -r ".hosts[\"$host\"]" "$CONN_BACKUP_FILE")
                CONN_HOST_STATUS["$host"]="$status"
            done
            
            # Also restore timestamps
            CONN_LAST_TEST_TIME=$(jq -r '.last_test // 0' "$CONN_BACKUP_FILE")
            CONN_LAST_BACKUP_TIME=$(jq -r '.timestamp // 0' "$CONN_BACKUP_FILE")
            
        else
            # Fall back to grep for basic parsing
            log "DEBUG" "jq not available, using basic parsing"
            
            # Extract status entries with grep (this is a simplified approach)
            local hosts_section=$(grep -o '"hosts":{[^}]*}' "$CONN_BACKUP_FILE")
            
            # Extract key-value pairs
            while read -r entry; do
                if [[ "$entry" =~ \"([^\"]+)\":\"([^\"]+)\" ]]; then
                    local host="${BASH_REMATCH[1]}"
                    local status="${BASH_REMATCH[2]}"
                    CONN_HOST_STATUS["$host"]="$status"
                fi
            done < <(echo "$hosts_section" | grep -o '"[^"]*":"[^"]*"')
            
            # Extract timestamps with grep
            if grep -q '"last_test":[0-9]*' "$CONN_BACKUP_FILE"; then
                CONN_LAST_TEST_TIME=$(grep -o '"last_test":[0-9]*' "$CONN_BACKUP_FILE" | cut -d':' -f2)
            fi
            
            if grep -q '"timestamp":[0-9]*' "$CONN_BACKUP_FILE"; then
                CONN_LAST_BACKUP_TIME=$(grep -o '"timestamp":[0-9]*' "$CONN_BACKUP_FILE" | cut -d':' -f2)
            fi
        fi
        
        log "INFO" "Restored status for ${#CONN_HOST_STATUS[@]} hosts from backup"
        return 0
    fi
    
    log "WARNING" "No connectivity status backup found"
    return 1
}

# ==========================================
# Callback registration and management
# ==========================================

# Register a callback function for connectivity events
# Usage: register_connectivity_callback trigger_point callback_function
# Arguments:
#   trigger_point - When to call (pre_test, post_test, connectivity_failure, interface_issue)
#   callback_function - Function name to call
# Notes:
#   - Callback failures are logged but do not affect operational flow
#   - Callbacks should return 0 on success, non-zero on failure
#   - Callbacks should not modify system state directly
# Returns: 0 on success, 1 on failure
register_connectivity_callback() {
    local trigger_point="$1"
    local callback_function="$2"
    
    if [ -z "$trigger_point" ] || [ -z "$callback_function" ]; then
        log "ERROR" "Missing parameters for callback registration"
        return 1
    fi
    
    # Validate trigger point
    case "$trigger_point" in
        pre_test|post_test|connectivity_failure|interface_issue)
            ;;
        *)
            log "ERROR" "Invalid trigger point: $trigger_point"
            log "ERROR" "Valid options: pre_test, post_test, connectivity_failure, interface_issue"
            return 1
            ;;
    esac
    
    # Verify callback function exists
    if ! type "$callback_function" &>/dev/null; then
        log "ERROR" "Callback function $callback_function does not exist"
        return 1
    fi
    
    # Initialize array if not already done
    declare -A CONN_CALLBACKS
    
    # Register the callback
    CONN_CALLBACKS["$trigger_point"]="$callback_function"
    log "INFO" "Registered callback for $trigger_point: $callback_function"
    
    return 0
}

# Export necessary functions and variables
export -f init_connectivity
export -f test_host_connectivity
export -f test_flannel_connectivity
export -f test_service_connectivity
export -f check_interface_traffic
export -f test_basic_container_connectivity
export -f run_connectivity_tests
export -f register_connectivity_callback
export -f backup_connectivity_status
export -f restore_connectivity_status
export -f get_first_ip_in_subnet
export -f execute_connectivity_callback

export CONN_TEST_INTERVAL CONN_RETRY_COUNT CONN_RETRY_DELAY CONN_TEST_TIMEOUT
export CONN_LAST_TEST_TIME CONN_LAST_BACKUP_TIME
export CONN_STATE_DIR CONN_STATUS_FILE CONN_BACKUP_FILE
export CONN_STATUS_UNKNOWN CONN_STATUS_UP CONN_STATUS_DOWN CONN_STATUS_DEGRADED
