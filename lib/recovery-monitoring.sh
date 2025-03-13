#!/bin/bash
# recovery-monitoring.sh
# Integration between monitoring and recovery subsystems for flannel-registrar
# Part of the minimalist multi-module recovery system

# Module information
MODULE_NAME="recovery-monitoring"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "monitoring-core" "recovery-state" "recovery-core" "recovery-actions")

# ==========================================
# Global variables for recovery monitoring
# ==========================================

# Component status cache
declare -A COMPONENT_STATUS_CACHE
declare -A COMPONENT_CACHE_TIMESTAMPS

# Cache validity period in seconds
COMPONENT_CACHE_VALIDITY=${COMPONENT_CACHE_VALIDITY:-30}

# Component type patterns
NETWORK_COMPONENT_PATTERN="^network\."
SYSTEM_COMPONENT_PATTERN="^system\."
CONTAINER_COMPONENT_PATTERN="\.container$"
INTERFACE_COMPONENT_PATTERN="\.interface$"
SERVICE_COMPONENT_PATTERN="\.service$"

# Component dependencies mapping
declare -A COMPONENT_DEPENDENCIES
# Default dependency mappings
COMPONENT_DEPENDENCIES["network.interface"]="network.routes network.connectivity"
COMPONENT_DEPENDENCIES["system.docker"]="system.container"

# ==========================================
# Module initialization
# ==========================================

# Initialize recovery monitoring module
# Usage: init_recovery_monitoring
# Returns: 0 on success, 1 on failure
init_recovery_monitoring() {
    # Check dependencies
    for dep in "${MODULE_DEPENDENCIES[@]}"; do
        # Convert module name (with dash) to init function name (with underscore)
        local init_func="init_${dep//-/_}"
        if ! type "$init_func" &>/dev/null; then
            echo "ERROR: Required dependency '$dep' is not loaded. Make sure all dependencies are initialized."
            return 1
        fi
    done

    # Initialize component dependency mapping
    # Additional dependency mappings can be added here in future versions

    # Initialize caches
    declare -A COMPONENT_STATUS_CACHE
    declare -A COMPONENT_CACHE_TIMESTAMPS

    log "INFO" "Initialized recovery-monitoring module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Component mapping functions
# ==========================================

# Map component status to appropriate recovery action
# Usage: map_component_to_recovery component
# Arguments:
#   component - Component name (e.g., "network.interface")
# Returns: Recommended recovery action or "none" if no action needed
map_component_to_recovery() {
    local component="$1"
    local recovery_action="none"
    
    # Get component status, message, and details
    local component_status=$(get_cached_component_status "$component")
    if [ -z "$component_status" ]; then
        log "WARNING" "Cannot get status for component $component"
        return 0
    fi
    
    # Extract status values
    local status=$(echo "$component_status" | cut -d':' -f1)
    local message=$(echo "$component_status" | cut -d':' -f3-)

    # Parse message for actionable details
    local parsed_details=$(parse_component_message "$component" "$message")
    
    # If component is healthy, no action needed
    if [ "$status" = "$MONITORING_STATUS_HEALTHY" ]; then
        echo "none"
        return 0
    fi
    
    # Map component type to recovery action based on pattern matching
    if [[ "$component" =~ $NETWORK_COMPONENT_PATTERN ]]; then
        # Network component recovery mapping
        if [[ "$component" =~ $INTERFACE_COMPONENT_PATTERN ]]; then
            recovery_action="interface"
        elif echo "$parsed_details" | grep -q "route"; then
            recovery_action="interface"
        elif echo "$parsed_details" | grep -q "connectivity"; then
            # Check if it's a container connectivity issue
            if echo "$parsed_details" | grep -q "container"; then
                recovery_action="container"
            else
                recovery_action="interface"
            fi
        else
            # Default for network issues is interface cycling
            recovery_action="interface"
        fi
    elif [[ "$component" =~ $SYSTEM_COMPONENT_PATTERN ]]; then
        # System component recovery mapping
        if [[ "$component" =~ $CONTAINER_COMPONENT_PATTERN ]] || echo "$parsed_details" | grep -q "container"; then
            recovery_action="container"
        elif [[ "$component" =~ $SERVICE_COMPONENT_PATTERN ]] || echo "$parsed_details" | grep -q "service"; then
            recovery_action="service"
        elif echo "$parsed_details" | grep -q "docker"; then
            # Docker issues usually require container or service restart
            if [ "$status" = "$MONITORING_STATUS_CRITICAL" ]; then
                recovery_action="service"
            else
                recovery_action="container"
            fi
        else
            # Default for system issues depends on severity
            if [ "$status" = "$MONITORING_STATUS_CRITICAL" ]; then
                recovery_action="container"
            else
                recovery_action="interface"
            fi
        fi
    else
        # Unknown component type, use basic mapping based on severity
        if [ "$status" = "$MONITORING_STATUS_CRITICAL" ]; then
            recovery_action="container"
        else
            recovery_action="interface"
        fi
    fi
    
    # Map recovery action string to recovery level constants
    case "$recovery_action" in
        "interface")
            echo "$RECOVERY_LEVEL_INTERFACE"
            ;;
        "container")
            echo "$RECOVERY_LEVEL_CONTAINER"
            ;;
        "service")
            echo "$RECOVERY_LEVEL_SERVICE"
            ;;
        *)
            echo "$RECOVERY_LEVEL_NONE"
            ;;
    esac
    
    return 0
}

# Get cached component status or fetch if cache is invalid
# Usage: get_cached_component_status component [force_refresh]
# Arguments:
#   component - Component name
#   force_refresh - Optional flag to force cache refresh (any value)
# Returns: Component status string
get_cached_component_status() {
    local component="$1"
    local force_refresh="${2:-}"
    local current_time=$(date +%s)
    
    # Check if we need to refresh the cache
    local refresh_needed=true
    
    if [ -z "$force_refresh" ] && [ -n "${COMPONENT_CACHE_TIMESTAMPS[$component]}" ]; then
        local timestamp=${COMPONENT_CACHE_TIMESTAMPS[$component]}
        local age=$((current_time - timestamp))
        
        if [ $age -lt $COMPONENT_CACHE_VALIDITY ]; then
            refresh_needed=false
        fi
    fi
    
    # Refresh cache if needed
    if $refresh_needed; then
        local status=$(get_component_status "$component")
        COMPONENT_STATUS_CACHE["$component"]="$status"
        COMPONENT_CACHE_TIMESTAMPS["$component"]="$current_time"
    fi
    
    # Return cached status
    echo "${COMPONENT_STATUS_CACHE[$component]}"
    return 0
}

# Parse monitoring message for recovery-relevant details
# Usage: parse_component_message component message
# Arguments:
#   component - Component name
#   message - Status message from monitoring
# Returns: Extracted details relevant to recovery
parse_component_message() {
    local component="$1"
    local message="$2"
    local details=""
    
    # Skip empty messages
    if [ -z "$message" ]; then
        echo "unknown"
        return 0
    fi
    
    # Extract keywords and patterns based on component type
    if [[ "$component" =~ $NETWORK_COMPONENT_PATTERN ]]; then
        # Extract network-related details
        if echo "$message" | grep -q -i "interface"; then
            details+="interface "
        fi
        if echo "$message" | grep -q -i "route"; then
            details+="route "
        fi
        if echo "$message" | grep -q -i "connectivity"; then
            details+="connectivity "
        fi
        if echo "$message" | grep -q -i "vxlan"; then
            details+="vxlan "
        fi
        if echo "$message" | grep -q -i "container"; then
            details+="container "
        fi
    elif [[ "$component" =~ $SYSTEM_COMPONENT_PATTERN ]]; then
        # Extract system-related details
        if echo "$message" | grep -q -i "container"; then
            details+="container "
        fi
        if echo "$message" | grep -q -i "service"; then
            details+="service "
        fi
        if echo "$message" | grep -q -i "docker"; then
            details+="docker "
        fi
        if echo "$message" | grep -q -i "memory"; then
            details+="memory "
        fi
        if echo "$message" | grep -q -i "cpu"; then
            details+="cpu "
        fi
        if echo "$message" | grep -q -i "disk"; then
            details+="disk "
        fi
    fi
    
    # Extract severity indicators
    if echo "$message" | grep -q -i "failed\|failure\|error"; then
        details+="error "
    fi
    if echo "$message" | grep -q -i "missing"; then
        details+="missing "
    fi
    if echo "$message" | grep -q -i "timeout"; then
        details+="timeout "
    fi
    
    # If no specific details found, return general category
    if [ -z "$details" ]; then
        if [[ "$component" =~ $NETWORK_COMPONENT_PATTERN ]]; then
            details="network "
        elif [[ "$component" =~ $SYSTEM_COMPONENT_PATTERN ]]; then
            details="system "
        else
            details="unknown "
        fi
    fi
    
    # Return trimmed details
    echo "${details%% }"
    return 0
}

# ==========================================
# Component status functions
# ==========================================

# Get list of components in critical state with details
# Usage: get_critical_components
# Returns: List of critical components with details
get_critical_components() {
    local critical_components=""
    
    # Get all component statuses
    local component_statuses=$(get_all_component_statuses)
    if [ -z "$component_statuses" ]; then
        log "WARNING" "No component statuses found"
        return 0
    fi
    
    # Extract critical components
    while IFS=: read -r component status timestamp message; do
        [ -z "$component" ] && continue
        
        if [ "$status" = "$MONITORING_STATUS_CRITICAL" ]; then
            # Add to cache to avoid future lookups
            COMPONENT_STATUS_CACHE["$component"]="$status:$timestamp:$message"
            COMPONENT_CACHE_TIMESTAMPS["$component"]=$(date +%s)
            
            # Add to result list with details
            local details=$(parse_component_message "$component" "$message")
            critical_components+="$component[$details] "
        fi
    done <<< "$component_statuses"
    
    # Return trimmed list
    echo "${critical_components%% }"
    return 0
}

# Get list of components in degraded state with details
# Usage: get_degraded_components
# Returns: List of degraded components with details
get_degraded_components() {
    local degraded_components=""
    
    # Get all component statuses
    local component_statuses=$(get_all_component_statuses)
    if [ -z "$component_statuses" ]; then
        log "WARNING" "No component statuses found"
        return 0
    fi
    
    # Extract degraded components
    while IFS=: read -r component status timestamp message; do
        [ -z "$component" ] && continue
        
        if [ "$status" = "$MONITORING_STATUS_DEGRADED" ]; then
            # Add to cache to avoid future lookups
            COMPONENT_STATUS_CACHE["$component"]="$status:$timestamp:$message"
            COMPONENT_CACHE_TIMESTAMPS["$component"]=$(date +%s)
            
            # Add to result list with details
            local details=$(parse_component_message "$component" "$message")
            degraded_components+="$component[$details] "
        fi
    done <<< "$component_statuses"
    
    # Return trimmed list
    echo "${degraded_components%% }"
    return 0
}

# ==========================================
# Recovery priority and execution functions
# ==========================================

# Determine priority of recovery actions
# Usage: evaluate_recovery_priority "component1 component2 ..."
# Arguments:
#   components - Space-separated list of components that need recovery
# Returns: Prioritized list of components for recovery
evaluate_recovery_priority() {
    local components="$1"
    local prioritized_list=""
    local network_components=""
    local system_components=""
    local unknown_components=""
    
    # Skip if no components
    if [ -z "$components" ]; then
        return 0
    fi
    
    # Separate components by type
    for component in $components; do
        # Strip details if present
        local component_name="${component%%[*}"
        if [ "$component_name" = "$component" ]; then
            component_name="$component"  # No details present
        fi
        
        if [[ "$component_name" =~ $NETWORK_COMPONENT_PATTERN ]]; then
            network_components+="$component "
        elif [[ "$component_name" =~ $SYSTEM_COMPONENT_PATTERN ]]; then
            system_components+="$component "
        else
            unknown_components+="$component "
        fi
    done
    
    # Build prioritized list: system components first, then network, then unknown
    # This order ensures core system components are recovered before network
    prioritized_list="${system_components}${network_components}${unknown_components}"
    
    # Further prioritize basic vs. dependent components within each type
    local result=""
    local processed_components=""
    
    # Helper function to check if component is in the processed list
    is_processed() {
        local target="$1"
        for proc in $processed_components; do
            if [ "${proc%%[*}" = "$target" ]; then
                return 0
            fi
        done
        return 1
    }
    
    # Process each component and handle dependencies
    for component in $prioritized_list; do
        # Strip details if present
        local component_name="${component%%[*}"
        if [ "$component_name" = "$component" ]; then
            component_name="$component"  # No details present
        fi
        
        # Skip if already processed
        if is_processed "$component_name"; then
            continue
        fi
        
        # Add to result
        result+="$component "
        processed_components+="$component_name "
        
        # Check if this component has dependencies
        if [ -n "${COMPONENT_DEPENDENCIES[$component_name]}" ]; then
            log "DEBUG" "Component $component_name has dependencies: ${COMPONENT_DEPENDENCIES[$component_name]}"
            
            # Skip dependencies that are already in the processed list
            for dep in ${COMPONENT_DEPENDENCIES[$component_name]}; do
                if ! is_processed "$dep"; then
                    # Check if dependency is in the original list
                    local found=false
                    for orig in $prioritized_list; do
                        if [ "${orig%%[*}" = "$dep" ]; then
                            found=true
                            break
                        fi
                    done
                    
                    # If dependency is in original list but not processed yet, 
                    # add it right after the current component
                    if $found; then
                        result+="$dep "
                        processed_components+="$dep "
                    fi
                fi
            done
        fi
    done
    
    # Return trimmed result
    echo "${result%% }"
    return 0
}

# Check if monitoring status has improved after recovery
# Usage: check_recovery_success component recovery_level
# Arguments:
#   component - Component that was recovered
#   recovery_level - Recovery level that was used
# Returns: 0 if successful, 1 if failed
check_recovery_success() {
    local component="$1"
    local recovery_level="$2"
    local retry_attempts=3
    local wait_time=15
    
    # Set wait time based on recovery level
    case "$recovery_level" in
        "$RECOVERY_LEVEL_INTERFACE")
            wait_time=10
            ;;
        "$RECOVERY_LEVEL_CONTAINER")
            wait_time=20
            ;;
        "$RECOVERY_LEVEL_SERVICE")
            wait_time=30
            ;;
    esac
    
    log "INFO" "Verifying recovery success for $component (level: $recovery_level)"
    
    # Check component status with increasing wait times
    for ((attempt=1; attempt<=retry_attempts; attempt++)); do
        # Force refresh of component status
        local status_line=$(get_cached_component_status "$component" "force")
        local status=$(echo "$status_line" | cut -d':' -f1)
        
        # For interface-level recovery, consider degraded as success
        if [ "$recovery_level" = "$RECOVERY_LEVEL_INTERFACE" ]; then
            if [ "$status" = "$MONITORING_STATUS_HEALTHY" ] || [ "$status" = "$MONITORING_STATUS_DEGRADED" ]; then
                log "INFO" "Recovery successful for $component: status is $status"
                
                # Check dependencies
                check_dependencies "$component"
                
                return 0
            fi
        else
            # For other recovery levels, only healthy is considered success
            if [ "$status" = "$MONITORING_STATUS_HEALTHY" ]; then
                log "INFO" "Recovery successful for $component: status is healthy"
                
                # Check dependencies
                check_dependencies "$component"
                
                return 0
            fi
        fi
        
        # If not successful yet, wait and try again
        if [ $attempt -lt $retry_attempts ]; then
            log "INFO" "Component $component still has status $status, waiting $(($wait_time + 5 * $attempt)) seconds before next check"
            sleep $(($wait_time + 5 * $attempt))
        fi
    done
    
    log "WARNING" "Recovery verification failed for $component"
    return 1
}

# Check dependencies of a component after recovery
# Usage: check_dependencies component
# Arguments:
#   component - Component that was recovered
# Returns: Nothing
check_dependencies() {
    local component="$1"
    
    # Check if this component has dependencies
    if [ -n "${COMPONENT_DEPENDENCIES[$component]}" ]; then
        log "INFO" "Checking dependencies for $component: ${COMPONENT_DEPENDENCIES[$component]}"
        
        for dep in ${COMPONENT_DEPENDENCIES[$component]}; do
            # Force refresh of dependency status
            local status_line=$(get_cached_component_status "$dep" "force")
            local status=$(echo "$status_line" | cut -d':' -f1)
            
            log "INFO" "Dependency $dep status: $status"
        done
    fi
}

# ==========================================
# Issue detection functions
# ==========================================

# Detect specific network-related issues
# Usage: detect_network_issues
# Returns: List of network issues detected
detect_network_issues() {
    local network_issues=""
    
    # Get all component statuses
    local component_statuses=$(get_all_component_statuses)
    
    # Extract network components with issues
    while IFS=: read -r component status timestamp message; do
        [ -z "$component" ] && continue
        
        if [[ "$component" =~ $NETWORK_COMPONENT_PATTERN ]] && 
           [ "$status" != "$MONITORING_STATUS_HEALTHY" ]; then
            # Add to cache
            COMPONENT_STATUS_CACHE["$component"]="$status:$timestamp:$message"
            COMPONENT_CACHE_TIMESTAMPS["$component"]=$(date +%s)
            
            # Parse message for details
            local details=$(parse_component_message "$component" "$message")
            
            # Add to issues list
            network_issues+="$component[$details:$status] "
        fi
    done <<< "$component_statuses"
    
    # Return trimmed list
    echo "${network_issues%% }"
    return 0
}

# Detect specific system-related issues
# Usage: detect_system_issues
# Returns: List of system issues detected
detect_system_issues() {
    local system_issues=""
    
    # Get all component statuses
    local component_statuses=$(get_all_component_statuses)
    
    # Extract system components with issues
    while IFS=: read -r component status timestamp message; do
        [ -z "$component" ] && continue
        
        if [[ "$component" =~ $SYSTEM_COMPONENT_PATTERN ]] && 
           [ "$status" != "$MONITORING_STATUS_HEALTHY" ]; then
            # Add to cache
            COMPONENT_STATUS_CACHE["$component"]="$status:$timestamp:$message"
            COMPONENT_CACHE_TIMESTAMPS["$component"]=$(date +%s)
            
            # Parse message for details
            local details=$(parse_component_message "$component" "$message")
            
            # Add to issues list
            system_issues+="$component[$details:$status] "
        fi
    done <<< "$component_statuses"
    
    # Return trimmed list
    echo "${system_issues%% }"
    return 0
}

# ==========================================
# Component recovery execution
# ==========================================

# Run recovery for a specific component
# Usage: run_component_recovery component
# Arguments:
#   component - Component to recover
# Returns: 0 if recovery was successful, 1 if failed
run_component_recovery() {
    local component="$1"
    local recovery_success=false
    
    # Log the recovery attempt
    log "INFO" "Starting component-specific recovery for $component"
    
    # Record the recovery attempt
    if ! save_recovery_attempt "$component" "recovery_start" "attempted" \
        "Component-specific recovery started"; then
        log "WARNING" "Failed to save recovery attempt state, continuing anyway"
    fi
    
    # Determine appropriate recovery level
    local recovery_level=$(map_component_to_recovery "$component")
    
    # If no recovery needed, return success
    if [ "$recovery_level" = "$RECOVERY_LEVEL_NONE" ]; then
        log "INFO" "No recovery needed for $component"
        return 0
    fi
    
    log "INFO" "Mapped component $component to recovery level $recovery_level"
    
    # Execute recovery based on level
    case "$recovery_level" in
        "$RECOVERY_LEVEL_INTERFACE")
            log "INFO" "Executing interface-level recovery for $component"
            
            # For network interface components, use cycle_flannel_interface
            if [[ "$component" =~ "network.interface" ]]; then
                if cycle_flannel_interface; then
                    log "INFO" "Interface cycling completed for $component"
                else
                    log "WARNING" "Interface cycling failed for $component"
                fi
            else
                # For other components, use the generic interface-level recovery
                if cycle_flannel_interface; then
                    log "INFO" "Interface cycling completed for $component"
                else
                    log "WARNING" "Interface cycling failed for $component"
                fi
            fi
            ;;
            
        "$RECOVERY_LEVEL_CONTAINER")
            log "INFO" "Executing container-level recovery for $component"
            
            # For container components, use restart_flannel_container
            if restart_flannel_container; then
                log "INFO" "Container restart completed for $component"
            else
                log "WARNING" "Container restart failed for $component"
            fi
            ;;
            
        "$RECOVERY_LEVEL_SERVICE")
            log "INFO" "Executing service-level recovery for $component"
            
            # For service components, use restart_docker_service
            if restart_docker_service; then
                log "INFO" "Service restart completed for $component"
            else
                log "WARNING" "Service restart failed for $component"
            fi
            ;;
            
        *)
            log "ERROR" "Unknown recovery level: $recovery_level"
            return 1
            ;;
    esac
    
    # Wait for recovery to take effect
    log "INFO" "Waiting for recovery to take effect for $component"
    sleep 15
    
    # Check if recovery was successful
    if check_recovery_success "$component" "$recovery_level"; then
        log "INFO" "Recovery successful for $component"
        recovery_success=true
        
        # Record successful recovery
        if ! save_recovery_attempt "$component" "recovery_${recovery_level}" "success" \
            "Recovery succeeded at ${recovery_level} level"; then
            log "WARNING" "Failed to save recovery success state, continuing anyway"
        fi
    else
        log "WARNING" "Recovery at level $recovery_level did not resolve issues for $component"
        
        # Record failed recovery
        if ! save_recovery_attempt "$component" "recovery_${recovery_level}" "failure" \
            "Recovery failed at ${recovery_level} level"; then
            log "WARNING" "Failed to save recovery failure state, continuing anyway"
        fi
        
        # Try next level if available
        local next_level=$(increase_recovery_level "$recovery_level")
        
        if [ "$next_level" != "$RECOVERY_LEVEL_NONE" ]; then
            log "INFO" "Escalating to next recovery level: $next_level for $component"
            
            # Execute recovery at next level (recursive call)
            # First update the component mapping to reflect the escalation
            COMPONENT_RECOVERY_LEVEL["$component"]="$next_level"
            
            # Then run recovery at the new level
            if run_component_recovery "$component"; then
                recovery_success=true
            fi
        else
            log "ERROR" "Recovery failed at all levels for $component"
        fi
    fi
    
    if $recovery_success; then
        return 0
    else
        return 1
    fi
}

# Export necessary functions and variables
export -f init_recovery_monitoring
export -f map_component_to_recovery
export -f get_critical_components
export -f get_degraded_components
export -f evaluate_recovery_priority
export -f parse_component_message
export -f check_recovery_success
export -f detect_network_issues
export -f detect_system_issues
export -f run_component_recovery
export -f get_cached_component_status
export -f check_dependencies

export COMPONENT_CACHE_VALIDITY
export NETWORK_COMPONENT_PATTERN
export SYSTEM_COMPONENT_PATTERN
export CONTAINER_COMPONENT_PATTERN
export INTERFACE_COMPONENT_PATTERN
export SERVICE_COMPONENT_PATTERN
export -A COMPONENT_DEPENDENCIES
