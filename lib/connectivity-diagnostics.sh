#!/bin/bash
# connectivity-diagnostics.sh
# Diagnostic functions for network connectivity issues
# Part of flannel-registrar's modular network management system

# Module information
MODULE_NAME="connectivity-diagnostics"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "network-lib" "connectivity-core")

# ==========================================
# Global variables for connectivity diagnostics
# ==========================================

# Directories and files
CONN_DIAG_STATE_DIR="${COMMON_STATE_DIR}/connectivity-diagnostics"  # Diagnostics state directory
CONN_DIAG_HISTORY_FILE="${CONN_DIAG_STATE_DIR}/history.dat"  # History file for trend analysis
CONN_DIAG_LOG_DIR="${CONN_DIAG_STATE_DIR}/logs"  # Directory for diagnostic logs

# Configuration values
CONN_DIAG_MAX_SAMPLES=${CONN_DIAG_MAX_SAMPLES:-20}  # Maximum samples to keep for trend analysis
CONN_DIAG_HISTORY_DAYS=${CONN_DIAG_HISTORY_DAYS:-7}  # History retention period in days
CONN_DIAG_VERBOSITY=${CONN_DIAG_VERBOSITY:-normal}  # Verbosity level (minimal, normal, verbose)

# ==========================================
# Module initialization
# ==========================================

# Initialize connectivity diagnostics module
# Usage: init_connectivity_diagnostics
# Returns: 0 on success, 1 on failure
init_connectivity_diagnostics() {
    # Check dependencies
    for dep in log etcd_get execute_connectivity_callback; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found"
            return 1
        fi
    done
    
    # Create state directories
    mkdir -p "$CONN_DIAG_STATE_DIR" "$CONN_DIAG_LOG_DIR" || {
        log "ERROR" "Failed to create connectivity diagnostics directories"
        return 1
    }
    
    # Register diagnostic callbacks with core module
    register_diagnostic_callbacks || {
        log "WARNING" "Failed to register some diagnostic callbacks"
    }
    
    # Purge old diagnostic data
    purge_old_diagnostic_data
    
    log "INFO" "Initialized connectivity-diagnostics module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Utility functions
# ==========================================

# Get formatted timestamp for diagnostic entries
# Usage: get_diagnostic_timestamp
# Returns: Formatted timestamp string
get_diagnostic_timestamp() {
    date +%s
}

# Purge old diagnostic data to maintain history size limits
# Usage: purge_old_diagnostic_data
# Returns: 0 on success, 1 on failure
purge_old_diagnostic_data() {
    # Calculate cutoff date (in seconds since epoch)
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - (CONN_DIAG_HISTORY_DAYS * 86400)))
    
    # Remove old log files
    find "$CONN_DIAG_LOG_DIR" -type f -name "diag_*.log" -mtime +${CONN_DIAG_HISTORY_DAYS} -delete 2>/dev/null
    
    # If history file exists, clean up old entries
    if [ -f "$CONN_DIAG_HISTORY_FILE" ]; then
        local temp_file=$(mktemp)
        
        # Keep only recent entries
        while IFS= read -r line; do
            if [[ "$line" =~ ^time:([0-9]+) ]]; then
                local entry_time="${BASH_REMATCH[1]}"
                if [ "$entry_time" -ge "$cutoff_time" ]; then
                    echo "$line" >> "$temp_file"
                fi
            fi
        done < "$CONN_DIAG_HISTORY_FILE"
        
        # Replace original file with cleaned up version
        mv "$temp_file" "$CONN_DIAG_HISTORY_FILE"
    fi
    
    log "DEBUG" "Purged diagnostic data older than $CONN_DIAG_HISTORY_DAYS days"
    return 0
}

# Record diagnostic entry to history file
# Usage: record_diagnostic_entry type target result
# Arguments:
#   type - Type of diagnostic (host, subnet, service, container)
#   target - Target of diagnostic (IP, subnet, etc.)
#   result - Result of diagnostic (up, down, etc.)
# Returns: 0 on success, 1 on failure
record_diagnostic_entry() {
    local type="$1"
    local target="$2"
    local result="$3"
    
    # Validate inputs
    if [ -z "$type" ] || [ -z "$target" ] || [ -z "$result" ]; then
        return 1
    fi
    
    # Format entry with timestamp and data
    local timestamp=$(get_diagnostic_timestamp)
    local entry="time:$timestamp\ttype:$type\ttarget:$target\tresult:$result"
    
    # Append to history file
    echo -e "$entry" >> "$CONN_DIAG_HISTORY_FILE"
    
    # Limit file size by keeping only most recent entries
    if [ -f "$CONN_DIAG_HISTORY_FILE" ]; then
        local line_count=$(wc -l < "$CONN_DIAG_HISTORY_FILE")
        if [ "$line_count" -gt "$CONN_DIAG_MAX_SAMPLES" ]; then
            local lines_to_keep=$((CONN_DIAG_MAX_SAMPLES - 10))
            if [ "$lines_to_keep" -lt 10 ]; then
                lines_to_keep=10
            fi
            
            tail -n "$lines_to_keep" "$CONN_DIAG_HISTORY_FILE" > "${CONN_DIAG_HISTORY_FILE}.new"
            mv "${CONN_DIAG_HISTORY_FILE}.new" "$CONN_DIAG_HISTORY_FILE"
        fi
    fi
    
    return 0
}

# ==========================================
# Diagnostic callback registration
# ==========================================

# Register diagnostic callbacks with core module
# Usage: register_diagnostic_callbacks
# Returns: 0 on success, 1 if any registration fails
register_diagnostic_callbacks() {
    local success=true
    
    # Check if register_connectivity_callback function exists
    if ! type register_connectivity_callback &>/dev/null; then
        log "WARNING" "register_connectivity_callback function not found"
        return 1
    fi
    
    # Register pre-test callback
    if ! register_connectivity_callback "pre_test" "pre_test_diagnostics"; then
        log "WARNING" "Failed to register pre_test callback"
        success=false
    fi
    
    # Register post-test callback
    if ! register_connectivity_callback "post_test" "post_test_diagnostics"; then
        log "WARNING" "Failed to register post_test callback"
        success=false
    fi
    
    # Register connectivity failure callback
    if ! register_connectivity_callback "connectivity_failure" "connectivity_failure_diagnostics"; then
        log "WARNING" "Failed to register connectivity_failure callback"
        success=false
    fi
    
    # Register interface issue callback
    if ! register_connectivity_callback "interface_issue" "interface_issue_diagnostics"; then
        log "WARNING" "Failed to register interface_issue callback"
        success=false
    fi
    
    if $success; then
        log "INFO" "Successfully registered all diagnostic callbacks"
        return 0
    else
        log "WARNING" "Some diagnostic callbacks failed to register"
        return 1
    fi
}

# ==========================================
# Diagnostic callback functions
# ==========================================

# Pre-test diagnostic callback
# Usage: pre_test_diagnostics [target]
# Arguments:
#   target - Optional target of the test (host, subnet, etc.)
# Returns: 0 on success, 1 on failure
pre_test_diagnostics() {
    local target="$1"
    local test_type="unknown"
    
    # Determine test type based on target format
    if [ -z "$target" ]; then
        test_type="comprehensive"
    elif [[ "$target" == *"/"* ]]; then
        test_type="subnet"
    elif [[ "$target" == *":"* ]]; then
        test_type="service"
    else
        test_type="host"
    fi
    
    # Create diagnostic log entry
    local timestamp=$(get_diagnostic_timestamp)
    local diag="time:$timestamp\tevent:pre_test\ttype:$test_type"
    
    if [ -n "$target" ]; then
        diag+="\ttarget:$target"
    fi
    
    # Add baseline network stats if this is a comprehensive test
    if [ "$test_type" = "comprehensive" ]; then
        # Check flannel interface stats
        if ip -s link show flannel.1 &>/dev/null; then
            local stats=$(ip -s link show flannel.1)
            local rx_bytes=$(echo "$stats" | grep -A2 RX | tail -1 | awk '{print $1}')
            local tx_bytes=$(echo "$stats" | grep -A2 TX | tail -1 | awk '{print $1}')
            diag+="\trx_bytes:$rx_bytes\ttx_bytes:$tx_bytes"
        fi
    fi
    
    # Log the diagnostic data
    log "DEBUG" "Pre-test diagnostics: $diag"
    echo -e "$diag" >> "$CONN_DIAG_LOG_DIR/diag_$(date +%Y%m%d).log"
    
    return 0
}

# Post-test diagnostic callback
# Usage: post_test_diagnostics [subnets_tested] [connectivity_issues]
# Arguments:
#   subnets_tested - Number of subnets tested
#   connectivity_issues - Number of connectivity issues found
# Returns: 0 on success, 1 on failure
post_test_diagnostics() {
    local subnets_tested="$1"
    local connectivity_issues="$2"
    
    # Create diagnostic log entry
    local timestamp=$(get_diagnostic_timestamp)
    local diag="time:$timestamp\tevent:post_test"
    
    if [ -n "$subnets_tested" ]; then
        diag+="\tsubnets_tested:$subnets_tested"
    fi
    
    if [ -n "$connectivity_issues" ]; then
        diag+="\tconnectivity_issues:$connectivity_issues"
    fi
    
    # Check flannel interface stats
    if ip -s link show flannel.1 &>/dev/null; then
        local stats=$(ip -s link show flannel.1)
        local rx_bytes=$(echo "$stats" | grep -A2 RX | tail -1 | awk '{print $1}')
        local tx_bytes=$(echo "$stats" | grep -A2 TX | tail -1 | awk '{print $1}')
        diag+="\trx_bytes:$rx_bytes\ttx_bytes:$tx_bytes"
    fi
    
    # Calculate success rate
    if [ -n "$subnets_tested" ] && [ -n "$connectivity_issues" ] && [ "$subnets_tested" -gt 0 ]; then
        local success_rate=$(( 100 * (subnets_tested - connectivity_issues) / subnets_tested ))
        diag+="\tsuccess_rate:$success_rate"
        
        # Record success rate in history
        record_diagnostic_entry "test" "comprehensive" "$success_rate"
    fi
    
    # Log the diagnostic data
    log "DEBUG" "Post-test diagnostics: $diag"
    echo -e "$diag" >> "$CONN_DIAG_LOG_DIR/diag_$(date +%Y%m%d).log"
    
    return 0
}

# Connectivity failure diagnostic callback
# Usage: connectivity_failure_diagnostics target [port]
# Arguments:
#   target - Target that failed connectivity test (host, subnet)
#   port - Optional port for service connectivity failure
# Returns: 0 on success, 1 on failure
connectivity_failure_diagnostics() {
    local target="$1"
    local port="$2"
    
    # Determine failure type
    local failure_type="unknown"
    if [ -z "$target" ]; then
        log "WARNING" "No target specified for connectivity failure diagnostics"
        return 1
    elif [[ "$target" == *"/"* ]]; then
        failure_type="subnet"
    elif [ -n "$port" ]; then
        failure_type="service"
        target="${target}:${port}"
    else
        failure_type="host"
    fi
    
    # Create diagnostic log entry
    local timestamp=$(get_diagnostic_timestamp)
    local diag="time:$timestamp\tevent:connectivity_failure\ttype:$failure_type\ttarget:$target"
    
    # Record failure in history
    record_diagnostic_entry "$failure_type" "$target" "down"
    
    # Try to get more diagnostic information
    if [ "$CONN_DIAG_VERBOSITY" != "minimal" ]; then
        # Basic route information
        if [ "$failure_type" = "subnet" ] || [ "$failure_type" = "host" ]; then
            local route_info=$(ip route get "$target" 2>/dev/null || echo "no_route")
            diag+="\troute:$route_info"
        fi
        
        # Basic traceroute if available (with reasonable timeout)
        if command -v traceroute &>/dev/null; then
            local trace_target="$target"
            if [ "$failure_type" = "subnet" ]; then
                # For subnets, use the first usable IP
                if type get_first_ip_in_subnet &>/dev/null; then
                    trace_target=$(get_first_ip_in_subnet "$target")
                fi
            fi
            
            # Run traceroute with short timeout
            if [ -n "$trace_target" ]; then
                # Only include this for normal or verbose verbosity
                if [ "$CONN_DIAG_VERBOSITY" = "verbose" ]; then
                    local trace=$(traceroute -n -w 1 -m 5 "$trace_target" 2>&1 | 
                                  grep -v "traceroute to" | 
                                  tr '\n' '|' | 
                                  sed 's/\s\+/ /g')
                    diag+="\ttraceroute:$trace"
                fi
            fi
        fi
    fi
    
    # Log the diagnostic data
    log "DEBUG" "Connectivity failure diagnostics: $diag"
    echo -e "$diag" >> "$CONN_DIAG_LOG_DIR/diag_$(date +%Y%m%d).log"
    
    return 0
}

# Interface issue diagnostic callback
# Usage: interface_issue_diagnostics interface issue_type
# Arguments:
#   interface - Interface with detected issues
#   issue_type - Type of issue (missing, one_way_rx, one_way_tx)
# Returns: 0 on success, 1 on failure
interface_issue_diagnostics() {
    local interface="$1"
    local issue_type="$2"
    
    if [ -z "$interface" ]; then
        log "WARNING" "No interface specified for interface issue diagnostics"
        return 1
    fi
    
    # Create diagnostic log entry
    local timestamp=$(get_diagnostic_timestamp)
    local diag="time:$timestamp\tevent:interface_issue\tinterface:$interface"
    
    if [ -n "$issue_type" ]; then
        diag+="\tissue_type:$issue_type"
    fi
    
    # Record issue in history
    record_diagnostic_entry "interface" "$interface" "$issue_type"
    
    # Get interface details if it exists
    if [ "$issue_type" != "missing" ] && ip link show "$interface" &>/dev/null; then
        # Get statistics
        local stats=$(ip -s link show "$interface")
        local rx_packets=$(echo "$stats" | grep -A1 RX | tail -1 | awk '{print $1}')
        local tx_packets=$(echo "$stats" | grep -A1 TX | tail -1 | awk '{print $1}')
        local rx_bytes=$(echo "$stats" | grep -A2 RX | tail -1 | awk '{print $1}')
        local tx_bytes=$(echo "$stats" | grep -A2 TX | tail -1 | awk '{print $1}')
        local state=$(echo "$stats" | grep -o "state [^ ]*" | cut -d ' ' -f2)
        
        diag+="\tstate:$state\trx_packets:$rx_packets\ttx_packets:$tx_packets"
        diag+="\trx_bytes:$rx_bytes\ttx_bytes:$tx_bytes"
        
        # For one-way issues, check for dropped/error packets
        if [[ "$issue_type" == "one_way"* ]]; then
            local rx_dropped=$(echo "$stats" | grep -A3 RX | tail -1 | awk '{print $1}')
            local tx_dropped=$(echo "$stats" | grep -A3 TX | tail -1 | awk '{print $1}')
            local rx_errors=$(echo "$stats" | grep -A2 RX | tail -1 | awk '{print $2}')
            local tx_errors=$(echo "$stats" | grep -A2 TX | tail -1 | awk '{print $2}')
            
            diag+="\trx_dropped:$rx_dropped\ttx_dropped:$tx_dropped"
            diag+="\trx_errors:$rx_errors\ttx_errors:$tx_errors"
        fi
    fi
    
    # Log the diagnostic data
    log "DEBUG" "Interface issue diagnostics: $diag"
    echo -e "$diag" >> "$CONN_DIAG_LOG_DIR/diag_$(date +%Y%m%d).log"
    
    return 0
}

# ==========================================
# Detailed diagnostic functions
# ==========================================

# Generate detailed connectivity diagnostics
# Usage: get_connectivity_diagnostics [host_or_subnet]
# Arguments:
#   host_or_subnet - Optional target to diagnose
# Returns: Tab-delimited diagnostic data on success, error message on failure
get_connectivity_diagnostics() {
    local target="$1"
    local diag="time:$(get_diagnostic_timestamp)\thost:$(hostname)\n"
    
    # If no specific target, provide general diagnostics
    if [ -z "$target" ]; then
        diag+="type:general\n"
        
        # Check flannel interface
        if ip link show flannel.1 &>/dev/null; then
            local stats=$(ip -s link show flannel.1)
            local state=$(echo "$stats" | grep -o "state [^ ]*" | cut -d ' ' -f2)
            local rx_packets=$(echo "$stats" | grep -A1 RX | tail -1 | awk '{print $1}')
            local tx_packets=$(echo "$stats" | grep -A1 TX | tail -1 | awk '{print $1}')
            
            diag+="flannel_state:$state\trx_packets:$rx_packets\ttx_packets:$tx_packets\n"
        else
            diag+="error:missing_interface\tdetail:flannel.1 not found\n"
        fi
        
        # Check routes to flannel subnets
        local flannel_routes=$(ip route show | grep -E '10\.[0-9]+\.' | wc -l)
        diag+="flannel_routes:$flannel_routes\n"
        
        # Check latest test results
        local latest_diag=$(find "$CONN_DIAG_LOG_DIR" -name "diag_*.log" | sort | tail -1)
        if [ -n "$latest_diag" ]; then
            local last_test=$(grep "event:post_test" "$latest_diag" | tail -1)
            if [ -n "$last_test" ]; then
                if [[ "$last_test" =~ success_rate:([0-9]+) ]]; then
                    diag+="last_success_rate:${BASH_REMATCH[1]}\n"
                fi
                
                if [[ "$last_test" =~ subnets_tested:([0-9]+) ]]; then
                    diag+="last_subnets_tested:${BASH_REMATCH[1]}\n"
                fi
                
                if [[ "$last_test" =~ connectivity_issues:([0-9]+) ]]; then
                    diag+="last_connectivity_issues:${BASH_REMATCH[1]}\n"
                fi
            fi
        fi
    else
        # Target-specific diagnostics
        if [[ "$target" == *"/"* ]]; then
            diag+="type:subnet\ttarget:$target\n"
            
            # Check route to subnet
            local route=$(ip route get $(get_first_ip_in_subnet "$target") 2>/dev/null || echo "no route")
            diag+="route:$route\n"
            
            # Get subnet information from etcd
            local subnet_key="${FLANNEL_PREFIX}/subnets/$(echo "$target" | sed 's/\//-/g')"
            local subnet_data=$(etcd_get "$subnet_key")
            
            if [ -n "$subnet_data" ]; then
                local public_ip=""
                local hostname=""
                
                if command -v jq &>/dev/null; then
                    public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
                    hostname=$(echo "$subnet_data" | jq -r '.hostname // "unknown"')
                else
                    public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
                    hostname=$(echo "$subnet_data" | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
                fi
                
                diag+="public_ip:$public_ip\thostname:$hostname\n"
                
                # Check gateway if defined
                if type get_host_gateway &>/dev/null; then
                    local gateway=$(get_host_gateway "$public_ip")
                    if [ -n "$gateway" ] && [ "$gateway" != "$public_ip" ]; then
                        diag+="gateway:$gateway\n"
                        
                        # Check gateway connectivity
                        if ping -c 1 -W 2 "$gateway" &>/dev/null; then
                            diag+="gateway_connectivity:up\n"
                        else
                            diag+="gateway_connectivity:down\n"
                        fi
                    fi
                fi
            fi
            
            # Check connectivity history
            local history=$(grep "type:subnet.*target:$target" "$CONN_DIAG_HISTORY_FILE" | tail -5)
            if [ -n "$history" ]; then
                diag+="connectivity_history:\n"
                while IFS= read -r line; do
                    diag+="history_entry:$line\n"
                done <<< "$history"
            fi
        else
            # Host diagnostics
            diag+="type:host\ttarget:$target\n"
            
            # Check route to host
            local route=$(ip route get "$target" 2>/dev/null || echo "no route")
            diag+="route:$route\n"
            
            # Ping test
            if ping -c 1 -W 2 "$target" &>/dev/null; then
                diag+="ping:success\n"
            else
                diag+="ping:failed\n"
            fi
            
            # Check connectivity history
            local history=$(grep "type:host.*target:$target" "$CONN_DIAG_HISTORY_FILE" | tail -5)
            if [ -n "$history" ]; then
                diag+="connectivity_history:\n"
                while IFS= read -r line; do
                    diag+="history_entry:$line\n"
                done <<< "$history"
            fi
        fi
    fi
    
    echo -e "$diag"
    return 0
}

# Detect one-way communication issues
# Usage: detect_one_way_communication subnet1 subnet2
# Arguments:
#   subnet1 - First subnet to test
#   subnet2 - Second subnet to test
# Returns: 0 if bidirectional, 1 if one-way or no connectivity
detect_one_way_communication() {
    local subnet1="$1"
    local subnet2="$2"
    
    log "INFO" "Testing bidirectional connectivity between $subnet1 and $subnet2"
    
    # Get test IPs (first usable IP in each subnet)
    local test_ip1=$(get_first_ip_in_subnet "$subnet1")
    if [ -z "$test_ip1" ]; then
        log "ERROR" "Could not determine test IP for $subnet1"
        return 1
    fi
    
    local test_ip2=$(get_first_ip_in_subnet "$subnet2")
    if [ -z "$test_ip2" ]; then
        log "ERROR" "Could not determine test IP for $subnet2"
        return 1
    fi
    
    # Find a container to use for each network
    local network1=$(find_container_network "$subnet1")
    local network2=$(find_container_network "$subnet2")
    
    if [ -z "$network1" ] || [ -z "$network2" ]; then
        log "ERROR" "Could not find container networks for both subnets"
        return 1
    fi
    
    # Test bidirectional connectivity
    local result=$(test_container_connectivity "$network1" "$subnet2" "$test_ip2")
    local success1to2=$(echo "$result" | grep -q "connectivity:up" && echo "true" || echo "false")
    
    local result=$(test_container_connectivity "$network2" "$subnet1" "$test_ip1")
    local success2to1=$(echo "$result" | grep -q "connectivity:up" && echo "true" || echo "false")
    
    # Create diagnostic record
    local timestamp=$(get_diagnostic_timestamp)
    local diag="time:$timestamp\ttest:bidirectional"
    diag+="\tsubnet1:$subnet1\tsubnet2:$subnet2"
    diag+="\t1to2:$success1to2\t2to1:$success2to1"
    
    # Log the diagnostic data
    log "DEBUG" "Bidirectional test: $diag"
    echo -e "$diag" >> "$CONN_DIAG_LOG_DIR/diag_$(date +%Y%m%d).log"
    
    # Analyze results
    if [ "$success1to2" = "true" ] && [ "$success2to1" = "true" ]; then
        log "INFO" "Bidirectional connectivity confirmed"
        return 0
    elif [ "$success1to2" = "true" ] && [ "$success2to1" = "false" ]; then
        log "WARNING" "One-way communication: $subnet1 → $subnet2 works, return path fails"
        return 1
    elif [ "$success1to2" = "false" ] && [ "$success2to1" = "true" ]; then
        log "WARNING" "One-way communication: $subnet2 → $subnet1 works, return path fails"
        return 1
    else
        log "WARNING" "No connectivity in either direction"
        return 1
    fi
}

# Find a container network for a subnet
# Usage: find_container_network subnet
# Arguments:
#   subnet - Subnet to find a network for
# Returns: Docker network name or empty string if not found
find_container_network() {
    local subnet="$1"
    
    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        return 1
    fi
    
    # Try to find a network that contains containers
    for network in $(docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none'); do
        if docker ps --filter network="$network" --format "{{.Names}}" | grep -q .; then
            echo "$network"
            return 0
        fi
    done
    
    # If no network with containers found, return any custom network
    for network in $(docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none'); do
        echo "$network"
        return 0
    done
    
    # No suitable network found
    return 1
}

# Test connectivity between containers
# Usage: test_container_connectivity network subnet test_ip
# Arguments:
#   network - Docker network name
#   subnet - Subnet being tested
#   test_ip - IP to test connectivity to
# Returns: Tab-delimited diagnostic data
test_container_connectivity() {
    local network="$1"
    local subnet="$2"
    local test_ip="$3"
    
    # Validate inputs
    if [ -z "$network" ] || [ -z "$subnet" ] || [ -z "$test_ip" ]; then
        log "ERROR" "Missing parameters for container connectivity test"
        echo "error:missing_parameters"
        return 1
    fi
    
    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        log "ERROR" "Docker not available"
        echo "error:docker_not_available"
        return 1
    fi
    
    # Find a container, or create a temporary one
    local container=$(docker ps --filter network="$network" --format "{{.Names}}" | head -1)
    local clean_up=false
    
    if [ -z "$container" ]; then
        container="flannel-diag-test-$$"
        if ! docker run --rm -d --name "$container" --network "$network" alpine:latest sleep 30 >/dev/null; then
            log "ERROR" "Failed to create temporary container"
            echo "error:container_creation_failed"
            return 1
        fi
        clean_up=true
    fi
    
    # Test connectivity
    local timestamp=$(get_diagnostic_timestamp)
    local diag="time:$timestamp\tnetwork:$network\tsubnet:$subnet\ttest_ip:$test_ip"
    
    # Use ping with short timeout
    local result=$(docker exec "$container" ping -c 1 -W 3 "$test_ip" 2>&1)
    local exit_code=$?
    
    # Add round-trip time if successful
    if [ $exit_code -eq 0 ]; then
        diag+="\tconnectivity:up"
        local rtt=$(echo "$result" | grep "time=" | sed -e 's/.*time=\([0-9.]*\).*/\1/')
        if [ -n "$rtt" ]; then
            diag+="\trtt:$rtt"
        fi
    else
        diag+="\tconnectivity:down"
    fi
    
    # Clean up if needed
    if $clean_up; then
        docker rm -f "$container" >/dev/null 2>&1
    fi
    
    # Record the diagnostic entry
    echo -e "$diag" >> "$CONN_DIAG_LOG_DIR/diag_$(date +%Y%m%d).log"
    
    # Return the diagnostic data
    echo -e "$diag"
    return $exit_code
}

# Export necessary functions and variables
export -f init_connectivity_diagnostics
export -f get_connectivity_diagnostics
export -f detect_one_way_communication
export -f test_container_connectivity
export -f find_container_network
export -f get_diagnostic_timestamp
export -f purge_old_diagnostic_data
export -f record_diagnostic_entry
export -f register_diagnostic_callbacks
export -f pre_test_diagnostics
export -f post_test_diagnostics
export -f connectivity_failure_diagnostics
export -f interface_issue_diagnostics

export CONN_DIAG_STATE_DIR CONN_DIAG_HISTORY_FILE CONN_DIAG_LOG_DIR
export CONN_DIAG_MAX_SAMPLES CONN_DIAG_HISTORY_DAYS CONN_DIAG_VERBOSITY

