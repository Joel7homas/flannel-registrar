#!/bin/bash
# monitoring-core.sh
# Core monitoring functions for flannel-registrar
# Provides health checks, status tracking, and event handling

# Module information
MODULE_NAME="monitoring-core"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "connectivity-core")

# ==========================================
# Global variables for monitoring
# ==========================================

# Intervals and timeouts
MON_CHECK_INTERVAL=${MONITORING_INTERVAL:-300}  # Default 5 minutes between health checks
MON_BACKUP_INTERVAL=${MON_BACKUP_INTERVAL:-300}  # Default 5 minutes between state backups
MON_HISTORY_DAYS=${MONITORING_HISTORY_DAYS:-7}  # Default 7 days of history retention
MON_ALERT_COOLDOWN=${MON_ALERT_COOLDOWN:-600}  # Default 10 minutes between repeated alerts

# State tracking
MON_LAST_CHECK_TIME=0  # Timestamp of last health check
MON_LAST_BACKUP_TIME=0  # Timestamp of last state backup
MON_CURRENT_STATUS="unknown"  # Overall system status: unknown, healthy, degraded, critical

# Directories and files
MON_STATE_DIR="${COMMON_STATE_DIR}/monitoring"  # Base state directory
MON_STATUS_DIR="${MON_STATE_DIR}/status"  # Current status directory
MON_HISTORY_DIR="${MON_STATE_DIR}/history"  # Historical data directory
MON_STATUS_FILE="${MON_STATUS_DIR}/current_status.json"  # Current status file
MON_COMPONENTS_FILE="${MON_STATUS_DIR}/registered_components.txt"  # Registered components

# Component management
declare -A MON_COMPONENT_STATUS  # Status for each component
declare -A MON_COMPONENT_MESSAGES  # Status messages for each component
declare -A MON_COMPONENT_TIMESTAMPS  # Last update timestamps for each component
declare -A MON_STATUS_HANDLERS  # Event handlers for status transitions

# Default component list (can be overridden)
MON_DEFAULT_COMPONENTS="etcd flannel routes fdb docker network"
MON_ENABLED_COMPONENTS=${MONITORING_COMPONENTS:-$MON_DEFAULT_COMPONENTS}

# Status constants
MON_STATUS_HEALTHY="healthy"
MON_STATUS_DEGRADED="degraded"
MON_STATUS_CRITICAL="critical"
MON_STATUS_UNKNOWN="unknown"

# ==========================================
# Module initialization
# ==========================================

# Initialize monitoring system
# Usage: init_monitoring_core
# Returns: 0 on success, 1 on failure
init_monitoring_core() {
    # Check dependencies
    for dep in log etcd_get run_connectivity_tests; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found"
            return 1
        fi
    done

    # Create state directories
    mkdir -p "$MON_STATUS_DIR" "$MON_HISTORY_DIR" || {
        log "ERROR" "Failed to create monitoring state directories"
        return 1
    }

    # Initialize associative arrays
    declare -g -A MON_COMPONENT_STATUS
    declare -g -A MON_COMPONENT_MESSAGES
    declare -g -A MON_COMPONENT_TIMESTAMPS
    declare -g -A MON_STATUS_HANDLERS

    # Register default components
    for component in $MON_ENABLED_COMPONENTS; do
        register_component "$component"
    done

    # Restore state from previous run if available
    restore_monitoring_state

    log "INFO" "Initialized monitoring-core module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Component management functions
# ==========================================

# Register a component for monitoring
# Usage: register_component component_name [initial_status] [message]
# Arguments:
#   component_name - Name of component to register
#   initial_status - Initial status (default: unknown)
#   message - Initial status message (default: "Component registered")
# Returns: 0 on success, 1 on failure
register_component() {
    local component="$1"
    local status="${2:-$MON_STATUS_UNKNOWN}"
    local message="${3:-Component registered}"

    if [ -z "$component" ]; then
        log "ERROR" "No component name specified for registration"
        return 1
    fi

    # Check if valid status
    case "$status" in
        $MON_STATUS_HEALTHY|$MON_STATUS_DEGRADED|$MON_STATUS_CRITICAL|$MON_STATUS_UNKNOWN)
            ;;
        *)
            log "WARNING" "Invalid status: $status, setting to unknown"
            status="$MON_STATUS_UNKNOWN"
            ;;
    esac

    # Set initial component state
    MON_COMPONENT_STATUS["$component"]="$status"
    MON_COMPONENT_MESSAGES["$component"]="$message"
    MON_COMPONENT_TIMESTAMPS["$component"]=$(date +%s)

    # Add to registered components file
    echo "$component" >> "$MON_COMPONENTS_FILE"
    log "INFO" "Registered component for monitoring: $component (initial status: $status)"

    return 0
}

# Update status of a component
# Usage: update_component_status component status [message]
# Arguments:
#   component - Component name
#   status - Status (healthy, degraded, critical)
#   message - Optional status message
# Returns: 0 on success, 1 on failure
update_component_status() {
    local component="$1"
    local status="$2"
    local message="$3"
    local current_time=$(date +%s)

    # Basic validation
    if [ -z "$component" ] || [ -z "$status" ]; then
        log "ERROR" "Component and status are required"
        return 1
    fi

    # Check if component is registered
    if [ -z "${MON_COMPONENT_STATUS[$component]}" ]; then
        register_component "$component" "$status" "$message"
    fi

    # Check if valid status
    case "$status" in
        $MON_STATUS_HEALTHY|$MON_STATUS_DEGRADED|$MON_STATUS_CRITICAL)
            ;;
        *)
            log "WARNING" "Invalid status: $status"
            return 1
            ;;
    esac

    # Get previous status for event handling
    local prev_status="${MON_COMPONENT_STATUS[$component]}"
    
    # Update component state
    MON_COMPONENT_STATUS["$component"]="$status"
    MON_COMPONENT_TIMESTAMPS["$component"]="$current_time"
    
    if [ -n "$message" ]; then
        MON_COMPONENT_MESSAGES["$component"]="$message"
    fi

    # Log the status change
    if [ "$prev_status" != "$status" ]; then
        log "INFO" "Component $component status changed: $prev_status -> $status"
        
        # Add to history file with timestamp
        local date_today=$(date +%Y-%m-%d)
        local history_file="${MON_HISTORY_DIR}/${date_today}.log"
        local message="${MON_COMPONENT_MESSAGES[$component]}"
        echo -e "$current_time\t$component\t$status\t$message" >> "$history_file"
        
        # Trigger event handlers if status got worse or recovered
        if [[ "$prev_status" == "$MON_STATUS_HEALTHY" && "$status" != "$MON_STATUS_HEALTHY" ]]; then
            execute_status_handler "degraded" "$component" "$message"
        elif [[ "$prev_status" != "$MON_STATUS_HEALTHY" && "$status" == "$MON_STATUS_HEALTHY" ]]; then
            execute_status_handler "recovery" "$component" "$message"
        elif [[ "$status" == "$MON_STATUS_CRITICAL" ]]; then
            execute_status_handler "critical" "$component" "$message"
        fi
    }

    # Update overall system status
    update_system_status

    # Backup state periodically
    if [ $((current_time - MON_LAST_BACKUP_TIME)) -gt $MON_BACKUP_INTERVAL ]; then
        backup_monitoring_state
    fi

    return 0
}

# Update overall system status based on component statuses
# Usage: update_system_status
# Returns: 0 on success, 1 on failure
update_system_status() {
    local has_critical=false
    local has_degraded=false
    local has_unknown=false
    local all_healthy=true
    local prev_status="$MON_CURRENT_STATUS"

    # Check each component status
    for component in "${!MON_COMPONENT_STATUS[@]}"; do
        local status="${MON_COMPONENT_STATUS[$component]}"
        
        case "$status" in
            $MON_STATUS_CRITICAL)
                has_critical=true
                all_healthy=false
                ;;
            $MON_STATUS_DEGRADED)
                has_degraded=true
                all_healthy=false
                ;;
            $MON_STATUS_UNKNOWN)
                has_unknown=true
                all_healthy=false
                ;;
            $MON_STATUS_HEALTHY)
                # Already healthy by default
                ;;
            *)
                has_unknown=true
                all_healthy=false
                ;;
        esac
    done

    # Determine overall status
    if $has_critical; then
        MON_CURRENT_STATUS="$MON_STATUS_CRITICAL"
    elif $has_degraded; then
        MON_CURRENT_STATUS="$MON_STATUS_DEGRADED"
    elif $all_healthy; then
        MON_CURRENT_STATUS="$MON_STATUS_HEALTHY"
    elif $has_unknown; then
        MON_CURRENT_STATUS="$MON_STATUS_UNKNOWN"
    else
        MON_CURRENT_STATUS="$MON_STATUS_HEALTHY"
    fi

    # Log status change
    if [ "$prev_status" != "$MON_CURRENT_STATUS" ]; then
        log "INFO" "System status changed: $prev_status -> $MON_CURRENT_STATUS"
        
        # Trigger appropriate system-level event handler
        if [ "$MON_CURRENT_STATUS" == "$MON_STATUS_CRITICAL" ]; then
            execute_status_handler "system_critical" "system" "System status is critical"
        elif [ "$MON_CURRENT_STATUS" == "$MON_STATUS_DEGRADED" ]; then
            execute_status_handler "system_degraded" "system" "System status is degraded"
        elif [ "$MON_CURRENT_STATUS" == "$MON_STATUS_HEALTHY" ] && [ "$prev_status" != "$MON_STATUS_HEALTHY" ]; then
            execute_status_handler "system_recovery" "system" "System status recovered"
        fi
    }

    return 0
}

# ==========================================
# Health check functions
# ==========================================

# Run health check with configurable components
# Usage: run_health_check [components]
# Arguments:
#   components - Optional space-separated list of components to check
#               (default: all)
# Returns: 0 if healthy, 1 if issues detected
run_health_check() {
    local components="${1:-$MON_ENABLED_COMPONENTS}"
    local current_time=$(date +%s)
    local issues_detected=false

    # Only run full check every MON_CHECK_INTERVAL
    if [ $((current_time - MON_LAST_CHECK_TIME)) -lt $MON_CHECK_INTERVAL ]; then
        log "DEBUG" "Skipping health check, last check was $(($current_time - MON_LAST_CHECK_TIME)) seconds ago"
        return 0
    fi

    log "INFO" "Running health check for components: $components"
    MON_LAST_CHECK_TIME=$current_time

    # Run checks for each component
    for component in $components; do
        case "$component" in
            "etcd")
                check_etcd_health || issues_detected=true
                ;;
            "flannel")
                check_flannel_health || issues_detected=true
                ;;
            "routes")
                check_routes_health || issues_detected=true
                ;;
            "fdb")
                check_fdb_health || issues_detected=true
                ;;
            "docker")
                check_docker_health || issues_detected=true
                ;;
            "network")
                check_network_health || issues_detected=true
                ;;
            *)
                log "WARNING" "Unknown component: $component"
                update_component_status "$component" "$MON_STATUS_UNKNOWN" "Unknown component"
                ;;
        esac
    done

    # Backup state after every health check
    backup_monitoring_state

    if $issues_detected; then
        log "WARNING" "Health check completed with issues"
        return 1
    else
        log "INFO" "Health check completed successfully"
        return 0
    fi
}

# Check etcd health
# Usage: check_etcd_health
# Returns: 0 if healthy, 1 if issues detected
check_etcd_health() {
    log "DEBUG" "Checking etcd health"

    # Check etcd connection
    if ! etcd_get "${FLANNEL_PREFIX}/config" &>/dev/null; then
        update_component_status "etcd" "$MON_STATUS_CRITICAL" "Cannot connect to etcd"
        return 1
    fi

    # Check if we can list keys
    if ! etcd_list_keys "${FLANNEL_PREFIX}/subnets/" &>/dev/null; then
        update_component_status "etcd" "$MON_STATUS_DEGRADED" "Can connect to etcd but cannot list keys"
        return 1
    fi

    # Check if we can read subnet data
    local subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    if [ -z "$subnet_keys" ]; then
        update_component_status "etcd" "$MON_STATUS_DEGRADED" "No subnet entries found in etcd"
        return 1
    fi

    # All checks passed
    update_component_status "etcd" "$MON_STATUS_HEALTHY" "Etcd is functioning properly"
    return 0
}

# Check flannel interface health
# Usage: check_flannel_health
# Returns: 0 if healthy, 1 if issues detected
check_flannel_health() {
    log "DEBUG" "Checking flannel interface health"

    # Check if interface exists
    if ! ip link show flannel.1 &>/dev/null; then
        update_component_status "flannel" "$MON_STATUS_CRITICAL" "flannel.1 interface missing"
        return 1
    fi

    # Check interface state
    local link_state=$(ip link show flannel.1 | grep -o 'state [^ ]*' | cut -d' ' -f2)
    if [ "$link_state" != "UNKNOWN" ]; then
        update_component_status "flannel" "$MON_STATUS_DEGRADED" "flannel.1 interface in wrong state: $link_state"
        return 1
    fi

    # Check MTU
    local mtu=$(ip link show flannel.1 | grep -o 'mtu [0-9]*' | cut -d' ' -f2)
    if [ "$mtu" != "1370" ]; then
        update_component_status "flannel" "$MON_STATUS_DEGRADED" "flannel.1 interface has incorrect MTU: $mtu"
        return 1
    fi

    # Check traffic flow
    local stats=$(ip -s link show flannel.1)
    local rx_bytes=$(echo "$stats" | grep -A2 RX | tail -1 | awk '{print $1}')
    local tx_bytes=$(echo "$stats" | grep -A2 TX | tail -1 | awk '{print $1}')

    if [ $rx_bytes -eq 0 ] && [ $tx_bytes -eq 0 ]; then
        update_component_status "flannel" "$MON_STATUS_DEGRADED" "No traffic on flannel.1 interface"
        return 1
    fi

    # Check one-way communication signs
    if [ $rx_bytes -gt 1000000 ] && [ $tx_bytes -lt 1000 ]; then
        update_component_status "flannel" "$MON_STATUS_DEGRADED" "One-way traffic detected (receiving only)"
        return 1
    elif [ $tx_bytes -gt 1000000 ] && [ $rx_bytes -lt 1000 ]; then
        update_component_status "flannel" "$MON_STATUS_DEGRADED" "One-way traffic detected (sending only)"
        return 1
    fi

    # All checks passed
    update_component_status "flannel" "$MON_STATUS_HEALTHY" "Flannel interface is functioning properly"
    return 0
}

# Check routes health
# Usage: check_routes_health
# Returns: 0 if healthy, 1 if issues detected
check_routes_health() {
    log "DEBUG" "Checking routes health"

    # Get all subnet entries with their PublicIPs
    local subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    if [ -z "$subnet_keys" ]; then
        log "WARNING" "No subnet entries found in etcd, cannot check routes"
        update_component_status "routes" "$MON_STATUS_UNKNOWN" "No subnet data available"
        return 1
    fi

    local missing_routes=0
    local total_routes=0

    for key in $subnet_keys; do
        local subnet_id=$(basename "$key")
        local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
        local subnet_data=$(etcd_get "$key")

        if [ -n "$subnet_data" ]; then
            local public_ip=""

            if command -v jq &>/dev/null; then
                public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
            else
                public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
            fi

            # Skip any subnet with localhost IP or our own IP
            if [ "$public_ip" = "127.0.0.1" ] || [ "$public_ip" = "$FLANNELD_PUBLIC_IP" ]; then
                continue
            fi

            total_routes=$((total_routes + 1))

            if ! ip route show | grep -q "$cidr_subnet"; then
                missing_routes=$((missing_routes + 1))
                log "WARNING" "Missing route to subnet $cidr_subnet"
            fi
        fi
    done

    if [ $total_routes -eq 0 ]; then
        update_component_status "routes" "$MON_STATUS_UNKNOWN" "No remote routes to check"
        return 1
    fi

    if [ $missing_routes -gt 0 ]; then
        if [ $missing_routes -eq $total_routes ]; then
            update_component_status "routes" "$MON_STATUS_CRITICAL" "All $total_routes routes are missing"
        else
            update_component_status "routes" "$MON_STATUS_DEGRADED" "$missing_routes of $total_routes routes are missing"
        fi
        return 1
    fi

    # All checks passed
    update_component_status "routes" "$MON_STATUS_HEALTHY" "All $total_routes routes are configured properly"
    return 0
}

# Check FDB health
# Usage: check_fdb_health
# Returns: 0 if healthy, 1 if issues detected
check_fdb_health() {
    log "DEBUG" "Checking FDB health"

    # Check if bridge command is available
    if ! command -v bridge &>/dev/null; then
        update_component_status "fdb" "$MON_STATUS_UNKNOWN" "bridge command not available"
        return 1
    fi

    # Get FDB entries
    local fdb_entries=$(bridge fdb show dev flannel.1 2>/dev/null)
    if [ -z "$fdb_entries" ]; then
        update_component_status "fdb" "$MON_STATUS_CRITICAL" "No FDB entries found for flannel.1"
        return 1
    fi

    # Get all expected VTEP MACs from etcd
    local status_keys=$(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/")
    local expected_macs=0
    local found_macs=0

    for key in $status_keys; do
        local host=$(basename "$key")
        local status_data=$(etcd_get "$key")

        if [ -n "$status_data" ]; then
            local vtep_mac=""

            if command -v jq &>/dev/null; then
                vtep_mac=$(echo "$status_data" | jq -r '.vtep_mac')
            else
                vtep_mac=$(echo "$status_data" | grep -o '"vtep_mac":"[^"]*"' | cut -d'"' -f4)
            fi

            if [ -n "$vtep_mac" ] && [ "$vtep_mac" != "unknown" ] && [ "$vtep_mac" != "null" ]; then
                expected_macs=$((expected_macs + 1))
                
                if echo "$fdb_entries" | grep -q "$vtep_mac"; then
                    found_macs=$((found_macs + 1))
                else
                    log "WARNING" "Missing FDB entry for MAC $vtep_mac (host: $host)"
                fi
            fi
        fi
    done

    if [ $expected_macs -eq 0 ]; then
        update_component_status "fdb" "$MON_STATUS_UNKNOWN" "No VTEP MACs found in etcd"
        return 1
    fi

    if [ $found_macs -lt $expected_macs ]; then
        if [ $found_macs -eq 0 ]; then
            update_component_status "fdb" "$MON_STATUS_CRITICAL" "No expected VTEP MACs found in FDB"
        else
            update_component_status "fdb" "$MON_STATUS_DEGRADED" "Found $found_macs of $expected_macs expected VTEP MACs in FDB"
        fi
        return 1
    fi

    # All checks passed
    update_component_status "fdb" "$MON_STATUS_HEALTHY" "All $expected_macs expected VTEP MACs found in FDB"
    return 0
}

# Check Docker health
# Usage: check_docker_health
# Returns: 0 if healthy, 1 if issues detected
check_docker_health() {
    log "DEBUG" "Checking Docker health"

    # Check if Docker command is available
    if ! command -v docker &>/dev/null; then
        update_component_status "docker" "$MON_STATUS_UNKNOWN" "Docker command not available"
        return 1
    fi

    # Check if Docker is running
    if ! docker info &>/dev/null; then
        update_component_status "docker" "$MON_STATUS_CRITICAL" "Docker service is not running"
        return 1
    fi

    # Check if flannel container is running
    local flannel_name="${FLANNEL_CONTAINER_NAME:-flannel}"
    if ! docker ps --filter name="$flannel_name" | grep -q "$flannel_name"; then
        update_component_status "docker" "$MON_STATUS_CRITICAL" "Flannel container is not running"
        return 1
    fi

    # All checks passed
    update_component_status "docker" "$MON_STATUS_HEALTHY" "Docker is running properly"
    return 0
}

# Check network connectivity health
# Usage: check_network_health
# Returns: 0 if healthy, 1 if issues detected
check_network_health() {
    log "DEBUG" "Checking network connectivity health"

    # Use connectivity test module if available
    if type run_connectivity_tests &>/dev/null; then
        if ! run_connectivity_tests; then
            update_component_status "network" "$MON_STATUS_DEGRADED" "Connectivity tests detected issues"
            return 1
        fi
    else
        # Fallback to basic connectivity check
        local subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
        local unreachable=0
        local total=0

        for key in $subnet_keys; do
            local subnet_data=$(etcd_get "$key")
            if [ -n "$subnet_data" ]; then
                local public_ip=""
                
                if command -v jq &>/dev/null; then
                    public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
                else
                    public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
                fi

                # Skip localhost and our own IP
                if [ "$public_ip" = "127.0.0.1" ] || [ "$public_ip" = "$FLANNELD_PUBLIC_IP" ]; then
                    continue
                fi

                total=$((total + 1))
                if ! ping -c 1 -W 2 "$public_ip" &>/dev/null; then
                    unreachable=$((unreachable + 1))
                fi
            fi
        done

        if [ $total -eq 0 ]; then
            update_component_status "network" "$MON_STATUS_UNKNOWN" "No hosts to check for connectivity"
            return 1
        fi

        if [ $unreachable -gt 0 ]; then
            if [ $unreachable -eq $total ]; then
                update_component_status "network" "$MON_STATUS_CRITICAL" "All $total hosts are unreachable"
            else
                update_component_status "network" "$MON_STATUS_DEGRADED" "$unreachable of $total hosts are unreachable"
            fi
            return 1
        fi
    fi

    # All checks passed
    update_component_status "network" "$MON_STATUS_HEALTHY" "Network connectivity is functioning properly"
    return 0
}

# ==========================================
# Event handler functions
# ==========================================

# Register a health status change handler
# Usage: register_health_handler event_type handler_function
# Arguments:
#   event_type - Event type (degraded, critical, recovery)
#   handler_function - Function to call when event occurs
# Returns: 0 on success, 1 on failure
register_health_handler() {
    local event_type="$1"
    local handler_function="$2"

    if [ -z "$event_type" ] || [ -z "$handler_function" ]; then
        log "ERROR" "Event type and handler function are required"
        return 1
    fi

    # Validate event type
    case "$event_type" in
        degraded|critical|recovery|system_degraded|system_critical|system_recovery)
            ;;
        *)
            log "ERROR" "Invalid event type: $event_type"
            log "ERROR" "Valid types: degraded, critical, recovery, system_degraded, system_critical, system_recovery"
            return 1
            ;;
    esac

    # Validate handler function
    if ! type "$handler_function" &>/dev/null; then
        log "ERROR" "Handler function $handler_function does not exist"
        return 1
    fi

    # Register handler
    MON_STATUS_HANDLERS["$event_type"]="$handler_function"
    log "INFO" "Registered handler for $event_type events: $handler_function"

    return 0
}

# Execute a registered status handler
# Usage: execute_status_handler event_type component message
# Arguments:
#   event_type - Event type (degraded, critical, recovery)
#   component - Component that triggered the event
#   message - Event message
# Returns: 0 on success, 1 if no handler or execution fails
execute_status_handler() {
    local event_type="$1"
    local component="$2"
    local message="$3"

    if [ -z "$event_type" ] || [ -z "$component" ]; then
        log "ERROR" "Event type and component are required"
        return 1
    fi

    # Check if we have a handler
    if [ -z "${MON_STATUS_HANDLERS[$event_type]}" ]; then
        log "DEBUG" "No handler registered for $event_type events"
        return 1
    fi

    # Execute handler
    local handler="${MON_STATUS_HANDLERS[$event_type]}"
    if type "$handler" &>/dev/null; then
        log "DEBUG" "Executing handler for $event_type event: $handler"
        "$handler" "$component" "$message"
        return $?
    else
        log "WARNING" "Handler function $handler not found"
        return 1
    fi
}

# ==========================================
# State management functions
# ==========================================

# Get current health status
# Usage: get_health_status [format]
# Arguments:
#   format - Output format (text, json, key-value) (default: key-value)
# Returns: Health status in requested format
get_health_status() {
    local format="${1:-key-value}"
    local output=""

    # Determine output format
    case "$format" in
        "text")
            output="System Status: $MON_CURRENT_STATUS\n\n"
            output+="Component Status:\n"
            for component in "${!MON_COMPONENT_STATUS[@]}"; do
                local status="${MON_COMPONENT_STATUS[$component]}"
                local message="${MON_COMPONENT_MESSAGES[$component]}"
                local timestamp="${MON_COMPONENT_TIMESTAMPS[$component]}"
                local time_str=$(date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S")
                output+="- $component: $status ($time_str)\n  $message\n"
            done
            ;;
        
        "json")
            output='{"status":"'"$MON_CURRENT_STATUS"'","timestamp":'"$(date +%s)"',"components":{'
            local first=true
            for component in "${!MON_COMPONENT_STATUS[@]}"; do
                if ! $first; then output+=","; else first=false; fi
                local status="${MON_COMPONENT_STATUS[$component]}"
                local message="${MON_COMPONENT_MESSAGES[$component]}"
                local timestamp="${MON_COMPONENT_TIMESTAMPS[$component]}"
                output+='"'"$component"'":{"status":"'"$status"'","message":"'"$message"'","timestamp":'"$timestamp"'}'
            done
            output+="}}"
            ;;
        
        "key-value")
            output="status:$MON_CURRENT_STATUS\n"
            output+="timestamp:$(date +%s)\n"
            for component in "${!MON_COMPONENT_STATUS[@]}"; do
                local status="${MON_COMPONENT_STATUS[$component]}"
                local message="${MON_COMPONENT_MESSAGES[$component]}"
                local timestamp="${MON_COMPONENT_TIMESTAMPS[$component]}"
                output+="component:$component\tstatus:$status\ttimestamp:$timestamp\tmessage:$message\n"
            done
            ;;
        
        *)
            log "WARNING" "Unknown format: $format, using key-value"
            get_health_status "key-value"
            return $?
            ;;
    esac

    echo -e "$output"
    return 0
}

# Backup monitoring state to persistent storage
# Usage: backup_monitoring_state
# Returns: 0 on success, 1 on failure
backup_monitoring_state() {
    local current_time=$(date +%s)
    MON_LAST_BACKUP_TIME=$current_time

    # Ensure state directories exist
    mkdir -p "$MON_STATUS_DIR" "$MON_
