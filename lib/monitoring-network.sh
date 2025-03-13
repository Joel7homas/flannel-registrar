#!/bin/bash
# monitoring-network.sh
# Network-specific health checks for flannel-registrar monitoring
# Part of the minimalist multi-module monitoring system

# Module information
MODULE_NAME="monitoring-network"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "network-lib" "monitoring-core")

# Import status constants if not exported from monitoring-core.sh
if [ -z "$MONITORING_STATUS_HEALTHY" ]; then
    MONITORING_STATUS_HEALTHY="healthy"
    MONITORING_STATUS_DEGRADED="degraded" 
    MONITORING_STATUS_CRITICAL="critical"
    MONITORING_STATUS_UNKNOWN="unknown"
fi

# Initialize network monitoring
# Usage: init_monitoring_network
# Returns: 0 on success, 1 on failure
init_monitoring_network() {
    # Check dependencies
    for dep in log update_component_status get_component_status; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found"
            return 1
        fi
    done

    # Set default initial status for network components
    update_component_status "network.interface" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "network.routes" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "network.etcd" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "network.fdb" "$MONITORING_STATUS_UNKNOWN" "Not checked yet" 
    update_component_status "network.traffic" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "network.docker" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "network.connectivity" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"

    log "INFO" "Initialized monitoring-network module (v${MODULE_VERSION})"
    return 0
}

# Check if flannel interfaces exist and are up
# Usage: check_interface_health
# Returns: 0 if healthy, 1 if issues detected
check_interface_health() {
    local interface="flannel.1"
    local status="$MONITORING_STATUS_HEALTHY"
    local message="Flannel interface is up and healthy"
    
    # Check if interface exists
    if ! ip link show "$interface" &>/dev/null; then
        update_component_status "network.interface" "$MONITORING_STATUS_CRITICAL" \
            "Flannel interface $interface does not exist"
        return 1
    fi
    
    # Check interface state
    local state=$(ip link show "$interface" | grep -o "state [^ ]*" | cut -d' ' -f2)
    if [ "$state" != "UNKNOWN" ]; then
        status="$MONITORING_STATUS_DEGRADED"
        message="Flannel interface state is $state, should be UNKNOWN"
    fi
    
    # Update component status
    update_component_status "network.interface" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Verify routes to flannel subnets exist
# Usage: check_route_health
# Returns: 0 if healthy, 1 if issues detected
check_route_health() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="All flannel routes are configured correctly"
    local missing_routes=0
    local total_routes=0
    
    # Get all subnet entries from etcd
    local subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    if [ -z "$subnet_keys" ]; then
        update_component_status "network.routes" "$MONITORING_STATUS_CRITICAL" \
            "No subnet entries found in etcd"
        return 1
    fi
    
    # Check routes for each subnet
    for key in $subnet_keys; do
        local subnet_id=$(basename "$key")
        local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
        
        # Skip our own subnet
        if ip route show | grep -q "$cidr_subnet.*dev flannel.1"; then
            continue
        fi
        
        total_routes=$((total_routes + 1))
        if ! ip route show | grep -q "$cidr_subnet"; then
            missing_routes=$((missing_routes + 1))
        fi
    done
    
    # Determine status based on missing routes
    if [ $missing_routes -gt 0 ]; then
        if [ $missing_routes -eq $total_routes ]; then
            status="$MONITORING_STATUS_CRITICAL"
        else
            status="$MONITORING_STATUS_DEGRADED"
        fi
        message="Missing $missing_routes out of $total_routes flannel routes"
    fi
    
    update_component_status "network.routes" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Verify etcd is reachable
# Usage: check_etcd_connectivity
# Returns: 0 if healthy, 1 if issues detected
check_etcd_connectivity() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="ETCD is reachable and responding"
    local retry_count=2
    
    # Try to access etcd
    local attempt=0
    local success=false
    
    while [ $attempt -lt $retry_count ] && ! $success; do
        if curl -s -m 3 "${ETCD_ENDPOINT}/health" | grep -q "true"; then
            success=true
        else
            attempt=$((attempt + 1))
            sleep 1
        fi
    done
    
    if ! $success; then
        status="$MONITORING_STATUS_CRITICAL"
        message="Cannot connect to etcd after $retry_count attempts"
    else
        # Check if we can access flannel data
        if ! etcd_get "${FLANNEL_PREFIX}/config" &>/dev/null; then
            status="$MONITORING_STATUS_DEGRADED"
            message="ETCD is reachable but flannel data not accessible"
        fi
    fi
    
    update_component_status "network.etcd" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Verify FDB entries exist and are valid
# Usage: check_fdb_entries
# Returns: 0 if healthy, 1 if issues detected
check_fdb_entries() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="FDB entries are correctly configured"
    
    # Check if bridge command is available
    if ! command -v bridge &>/dev/null; then
        update_component_status "network.fdb" "$MONITORING_STATUS_UNKNOWN" \
            "Bridge command not available"
        return 1
    fi
    
    # Get FDB entries for flannel interface
    local fdb_entries=$(bridge fdb show dev flannel.1 2>/dev/null | grep -v '^$' | wc -l)
    if [ $fdb_entries -eq 0 ]; then
        update_component_status "network.fdb" "$MONITORING_STATUS_CRITICAL" \
            "No FDB entries found for flannel.1"
        return 1
    fi
    
    # Get subnet count from etcd
    local subnet_count=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/" | wc -l)
    
    # Compare FDB entries count with subnet count (should be roughly equal)
    if [ $fdb_entries -lt $((subnet_count / 2)) ]; then
        status="$MONITORING_STATUS_DEGRADED"
        message="Only $fdb_entries FDB entries for $subnet_count subnets"
    fi
    
    update_component_status "network.fdb" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Check for active traffic on interfaces
# Usage: check_network_traffic
# Returns: 0 if healthy, 1 if issues detected
check_network_traffic() {
    local interface="flannel.1"
    local status="$MONITORING_STATUS_HEALTHY"
    local message="Normal traffic flow on flannel interface"
    
    # Check if interface exists
    if ! ip link show "$interface" &>/dev/null; then
        update_component_status "network.traffic" "$MONITORING_STATUS_UNKNOWN" \
            "Flannel interface $interface does not exist"
        return 1
    fi
    
    # Get interface statistics
    local stats=$(ip -s link show "$interface")
    local rx_bytes=$(echo "$stats" | grep -A2 RX | tail -1 | awk '{print $1}')
    local tx_bytes=$(echo "$stats" | grep -A2 TX | tail -1 | awk '{print $1}')
    
    # Check for one-way communication issues
    if [ $rx_bytes -gt 10000 ] && [ $tx_bytes -lt 1000 ]; then
        status="$MONITORING_STATUS_DEGRADED"
        message="Possible one-way traffic issue (receiving only)"
    elif [ $tx_bytes -gt 10000 ] && [ $rx_bytes -lt 1000 ]; then
        status="$MONITORING_STATUS_DEGRADED"
        message="Possible one-way traffic issue (sending only)"
    elif [ $rx_bytes -eq 0 ] && [ $tx_bytes -eq 0 ]; then
        status="$MONITORING_STATUS_DEGRADED"
        message="No traffic on flannel interface"
    fi
    
    update_component_status "network.traffic" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Verify Docker networks are properly configured
# Usage: verify_docker_networks
# Returns: 0 if healthy, 1 if issues detected
verify_docker_networks() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="Docker networks are properly configured"
    
    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        update_component_status "network.docker" "$MONITORING_STATUS_UNKNOWN" \
            "Docker command not available"
        return 1
    fi
    
    # Check Docker service
    if ! docker info &>/dev/null; then
        update_component_status "network.docker" "$MONITORING_STATUS_CRITICAL" \
            "Docker service not running or not accessible"
        return 1
    fi
    
    # Get Docker networks
    local networks=$(docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none' | wc -l)
    if [ $networks -eq 0 ]; then
        status="$MONITORING_STATUS_DEGRADED"
        message="No custom Docker networks found"
    fi
    
    update_component_status "network.docker" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Verify connectivity to a sample of subnets
# Usage: check_subnet_connectivity
# Returns: 0 if healthy, 1 if issues detected
check_subnet_connectivity() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="All tested subnets are reachable"
    local max_subnets=3
    local problems=0
    local tested=0
    local problem_subnets=""
    
    # Get all subnet entries from etcd
    local subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    if [ -z "$subnet_keys" ]; then
        update_component_status "network.connectivity" "$MONITORING_STATUS_UNKNOWN" \
            "No subnet entries found in etcd"
        return 1
    fi
    
    # First check for previously problematic subnets
    local prev_status=$(get_component_status "network.connectivity")
    local prev_fields=()
    IFS=':' read -ra prev_fields <<< "$prev_status"
    local prev_message="${prev_fields[2]:-}"

    # If prev_message is empty, use the entire status (fallback)
    if [ -z "$prev_message" ] && [ -n "$prev_status" ]; then
        prev_message="$prev_status"
    fi

    # Test connectivity to each subnet (limited to max_subnets)
    for key in $subnet_keys; do
        # Stop after testing max_subnets
        if [ $tested -ge $max_subnets ]; then
            break
        fi
        
        local subnet_id=$(basename "$key")
        local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
        
        # Skip our own subnet
        if ip route show | grep -q "$cidr_subnet.*dev flannel.1"; then
            continue
        fi
        
        # Prioritize previously problematic subnets
        if [ "$prev_message" != "Not checked yet" ] && \
           [[ "$prev_message" == *"$cidr_subnet"* ]]; then
            continue
        fi
        
        # Get the first usable IP in the subnet
        local subnet_base=$(echo "$cidr_subnet" | cut -d'/' -f1)
        local test_ip="${subnet_base%.*}.$((${subnet_base##*.} + 1))"
        tested=$((tested + 1))
        
        # Test connectivity with basic retry
        local attempt=0
        local retry_count=2
        local success=false
        
        while [ $attempt -lt $retry_count ] && ! $success; do
            if ping -c 1 -W 2 "$test_ip" &>/dev/null; then
                success=true
            else
                attempt=$((attempt + 1))
                sleep 1
            fi
        done
        
        if ! $success; then
            problems=$((problems + 1))
            if [ -z "$problem_subnets" ]; then
                problem_subnets="$cidr_subnet"
            else
                problem_subnets="$problem_subnets, $cidr_subnet"
            fi
        fi
    done
    
    # Determine status based on connectivity problems
    if [ $problems -gt 0 ]; then
        if [ $problems -eq $tested ]; then
            status="$MONITORING_STATUS_CRITICAL"
        else
            status="$MONITORING_STATUS_DEGRADED"
        fi
        message="$problems of $tested tested subnets unreachable: $problem_subnets"
    fi
    
    update_component_status "network.connectivity" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Run all network health checks and update status
# Usage: run_network_health_check
# Returns: 0 if all healthy, 1 if issues detected
run_network_health_check() {
    log "INFO" "Running network health checks"
    local issues=0
    
    # Run all individual checks
    check_interface_health || issues=$((issues + 1))
    check_etcd_connectivity || issues=$((issues + 1))
    check_route_health || issues=$((issues + 1))
    check_fdb_entries || issues=$((issues + 1))
    check_network_traffic || issues=$((issues + 1))
    verify_docker_networks || issues=$((issues + 1))
    check_subnet_connectivity || issues=$((issues + 1))
    
    # Log summary
    log "INFO" "Network health checks completed with $issues issues detected"
    
    return $([ $issues -eq 0 ] && echo 0 || echo 1)
}

# Get basic diagnostic information for troubleshooting
# Usage: get_network_diagnostics
# Returns: Tab-delimited diagnostic information
get_network_diagnostics() {
    local diag="time:$(date +%s)\thost:$(hostname)\n"
    
    # Interface status
    if ip link show flannel.1 &>/dev/null; then
        local state=$(ip link show flannel.1 | grep -o "state [^ ]*" | cut -d' ' -f2)
        local mtu=$(ip link show flannel.1 | grep -o "mtu [0-9]*" | cut -d' ' -f2)
        diag+="interface:flannel.1\tstate:$state\tmtu:$mtu\n"
        
        # Interface stats
        local stats=$(ip -s link show flannel.1)
        local rx_bytes=$(echo "$stats" | grep -A2 RX | tail -1 | awk '{print $1}')
        local tx_bytes=$(echo "$stats" | grep -A2 TX | tail -1 | awk '{print $1}')
        diag+="rx_bytes:$rx_bytes\ttx_bytes:$tx_bytes\n"
    else
        diag+="interface:missing\n"
    fi
    
    # Route count
    local route_count=$(ip route show | grep -c -E '10\.[0-9]+\.')
    diag+="route_count:$route_count\n"
    
    # FDB entries count
    local fdb_count=$(bridge fdb show dev flannel.1 2>/dev/null | grep -v '^$' | wc -l || echo "0")
    diag+="fdb_count:$fdb_count\n"
    
    # Component status summary
    diag+="status_interface:$(get_component_status "network.interface" | cut -d':' -f1)\n"
    diag+="status_routes:$(get_component_status "network.routes" | cut -d':' -f1)\n"
    diag+="status_etcd:$(get_component_status "network.etcd" | cut -d':' -f1)\n"
    diag+="status_fdb:$(get_component_status "network.fdb" | cut -d':' -f1)\n"
    diag+="status_traffic:$(get_component_status "network.traffic" | cut -d':' -f1)\n"
    diag+="status_docker:$(get_component_status "network.docker" | cut -d':' -f1)\n"
    diag+="status_connectivity:$(get_component_status "network.connectivity" | cut -d':' -f1)\n"
    
    echo -e "$diag"
    return 0
}

# Export necessary functions
export -f init_monitoring_network
export -f check_interface_health
export -f check_route_health
export -f check_etcd_connectivity
export -f check_fdb_entries
export -f check_network_traffic
export -f verify_docker_networks
export -f check_subnet_connectivity
export -f run_network_health_check
export -f get_network_diagnostics
