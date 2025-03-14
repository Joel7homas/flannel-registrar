#!/bin/bash
# recovery-core.sh
# Core recovery orchestration for flannel-registrar self-healing
# Part of the minimalist multi-module recovery system

# Module information
MODULE_NAME="recovery-core"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "network-lib" "recovery-state" "monitoring-core")

# ==========================================
# Global variables for recovery
# ==========================================

# Recovery settings with defaults
RECOVERY_CHECK_INTERVAL=${RECOVERY_CHECK_INTERVAL:-300}  # 5 minutes
RECOVERY_MAX_INTERFACE_ATTEMPTS=${RECOVERY_MAX_INTERFACE_ATTEMPTS:-3}
RECOVERY_MAX_CONTAINER_ATTEMPTS=${RECOVERY_MAX_CONTAINER_ATTEMPTS:-2}
RECOVERY_MAX_SERVICE_ATTEMPTS=${RECOVERY_MAX_SERVICE_ATTEMPTS:-1}

# Recovery level constants - Use the ones exported from recovery-state.sh
# removed duplicate definitions of cooldown constants

# Status tracking
RECOVERY_LAST_CHECK_TIME=0
RECOVERY_CURRENT_LEVEL="$RECOVERY_LEVEL_NONE"

# ==========================================
# Module initialization
# ==========================================

# Initialize recovery core module
# Usage: init_recovery_core
# Returns: 0 on success, 1 on failure
init_recovery_core() {
    # Check dependencies more thoroughly
    local missing_dependencies=false
    
    # Required functions from dependencies
    local required_functions=(
        "log" 
        "get_all_component_statuses" 
        "get_component_status"
        "get_system_status"
        "save_recovery_attempt"
        "update_cooldown_timestamp"
        "is_in_cooldown"
        "get_recovery_attempts"
        "get_recovery_history"
    )
    
    # Check each required function
    for func in "${required_functions[@]}"; do
        if ! type "$func" &>/dev/null; then
            echo "ERROR: Required function '$func' not found. Make sure all dependencies are loaded."
            missing_dependencies=true
        fi
    done
    
    # Check recovery level constants from recovery-state.sh
    if [ -z "$RECOVERY_LEVEL_INTERFACE" ] || [ -z "$RECOVERY_LEVEL_CONTAINER" ] || \
       [ -z "$RECOVERY_LEVEL_SERVICE" ] || [ -z "$RECOVERY_LEVEL_NONE" ]; then
        echo "ERROR: Required recovery level constants not defined in recovery-state.sh"
        missing_dependencies=true
    fi
    
    if $missing_dependencies; then
        return 1
    fi

    # Set initial recovery level
    RECOVERY_CURRENT_LEVEL="$RECOVERY_LEVEL_NONE"
    RECOVERY_LAST_CHECK_TIME=0

    log "INFO" "Initialized recovery-core module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Recovery orchestration functions
# ==========================================

# Orchestrate the full recovery process
# Usage: run_recovery_sequence
# Returns: 0 if recovery succeeded, 1 if recovery failed or not needed
run_recovery_sequence() {
    local current_time=$(get_recovery_timestamp)
    
    # Check if it's time to run a recovery check
    if [ $((current_time - RECOVERY_LAST_CHECK_TIME)) -lt $RECOVERY_CHECK_INTERVAL ]; then
        log "DEBUG" "Skipping recovery check - last check was $(($current_time - RECOVERY_LAST_CHECK_TIME)) seconds ago"
        return 1
    fi
    
    RECOVERY_LAST_CHECK_TIME=$current_time
    log "INFO" "Starting recovery sequence"
    
    # Check if recovery is needed
    if ! check_recovery_needed; then
        log "INFO" "Recovery not needed - all systems operational"
        return 1
    fi
    
    # Get components that need recovery
    local components=$(get_critical_components)
    if [ -z "$components" ]; then
        log "INFO" "No critical components found, checking degraded components"
        components=$(get_degraded_components)
        
        if [ -z "$components" ]; then
            log "INFO" "No degraded components found, recovery not needed"
            return 1
        fi
    fi
    
    log "INFO" "Components needing recovery: $components"
    local recovery_success=false
    
    # Start with interface level recovery
    RECOVERY_CURRENT_LEVEL="$RECOVERY_LEVEL_INTERFACE"
    
    # Try recovery at each level until successful or max level reached
    while [ "$RECOVERY_CURRENT_LEVEL" != "$RECOVERY_LEVEL_NONE" ]; do
        log "INFO" "Attempting recovery at level: $RECOVERY_CURRENT_LEVEL"
        
        # Check if recovery at this level is allowed (cooldown and attempts)
        if ! is_recovery_allowed "general" "$RECOVERY_CURRENT_LEVEL"; then
            log "WARNING" "Recovery at level $RECOVERY_CURRENT_LEVEL not allowed (cooldown or max attempts)"
            RECOVERY_CURRENT_LEVEL=$(increase_recovery_level "$RECOVERY_CURRENT_LEVEL")
            continue
        fi
        
        # Check recent recovery history to inform decisions
        local recent_failures=$(get_recovery_history "general" 5 | grep -c "failure" || echo "0")
        if [ "$recent_failures" -gt 3 ]; then
            log "WARNING" "Multiple recent recovery failures detected ($recent_failures), consider manual intervention"
        fi
        
        # Perform recovery based on current level
        case "$RECOVERY_CURRENT_LEVEL" in
            "$RECOVERY_LEVEL_INTERFACE")
                log "INFO" "Attempting interface recovery"
                if cycle_flannel_interface; then
                    log "INFO" "Interface cycling completed"
                else
                    log "WARNING" "Interface cycling failed"
                fi
                ;;
                
            "$RECOVERY_LEVEL_CONTAINER")
                log "INFO" "Attempting container-level recovery"
                if restart_flannel_container; then
                    log "INFO" "Container restart completed"
                else
                    log "WARNING" "Container restart failed"
                fi
                ;;
                
            "$RECOVERY_LEVEL_SERVICE")
                log "INFO" "Attempting service-level recovery"
                if restart_docker_service; then
                    log "INFO" "Service restart completed"
                else
                    log "WARNING" "Service restart failed"
                fi
                ;;
                
            *)
                log "ERROR" "Unknown recovery level: $RECOVERY_CURRENT_LEVEL"
                return 1
                ;;
        esac
        
        # Record the recovery attempt with proper error handling
        if ! save_recovery_attempt "general" "recovery_${RECOVERY_CURRENT_LEVEL}" "attempted" \
            "Recovery attempted at ${RECOVERY_CURRENT_LEVEL} level"; then
            log "WARNING" "Failed to save recovery attempt state, continuing anyway"
        fi
        
        # Wait a bit before checking if recovery was successful
        log "INFO" "Waiting 15 seconds before verifying recovery success"
        sleep 15
        
        # Check if recovery was successful
        if verify_recovery_success "$components"; then
            log "INFO" "Recovery successful at level $RECOVERY_CURRENT_LEVEL"
            recovery_success=true
            
            if ! save_recovery_attempt "general" "recovery_${RECOVERY_CURRENT_LEVEL}" "success" \
                "Recovery succeeded at ${RECOVERY_CURRENT_LEVEL} level"; then
                log "WARNING" "Failed to save recovery success state, continuing anyway"
            fi
            
            reset_recovery_state
            break
        else
            log "WARNING" "Recovery at level $RECOVERY_CURRENT_LEVEL did not resolve issues"
            
            if ! save_recovery_attempt "general" "recovery_${RECOVERY_CURRENT_LEVEL}" "failure" \
                "Recovery failed at ${RECOVERY_CURRENT_LEVEL} level"; then
                log "WARNING" "Failed to save recovery failure state, continuing anyway"
            fi
            
            # Try next recovery level
            RECOVERY_CURRENT_LEVEL=$(increase_recovery_level "$RECOVERY_CURRENT_LEVEL")
        fi
    done
    
    if $recovery_success; then
        return 0
    else
        log "ERROR" "Recovery failed at all levels"
        return 1
    fi
}

# Determine if recovery is needed based on monitoring status
# Usage: check_recovery_needed
# Returns: 0 if recovery is needed, 1 if not
check_recovery_needed() {
    # Get system status from monitoring
    local system_status=$(get_system_status)
    
    if [ "$system_status" = "$MONITORING_STATUS_CRITICAL" ]; then
        log "WARNING" "System status is CRITICAL - recovery needed"
        return 0
    elif [ "$system_status" = "$MONITORING_STATUS_DEGRADED" ]; then
        log "WARNING" "System status is DEGRADED - recovery may be needed"
        
        # For degraded status, check if specific components need recovery
        local network_issues=$(echo "$(get_critical_components) $(get_degraded_components)" | \
                             grep -E "network\.|system\.")
        
        if [ -n "$network_issues" ]; then
            log "WARNING" "Network or system issues detected: $network_issues"
            return 0
        else
            log "INFO" "No network or system issues detected in degraded state"
            return 1
        fi
    else
        log "INFO" "System status is $system_status - recovery not needed"
        return 1
    fi
}

# Check if recovery is allowed based on history and cooldowns
# Usage: is_recovery_allowed component level
# Arguments:
#   component - Component to recover (or "general")
#   level - Recovery level (interface, container, service)
# Returns: 0 if allowed, 1 if not allowed
is_recovery_allowed() {
    local component="$1"
    local level="$2"
    local action="recovery_${level}"
    
    # Check if we're in cooldown period
    if is_in_cooldown "$action"; then
        log "WARNING" "Recovery action $action is in cooldown period"
        return 1
    fi
    
    # Check if we've exceeded maximum attempts
    local max_attempts=3  # Default
    
    case "$level" in
        "$RECOVERY_LEVEL_INTERFACE")
            max_attempts=$RECOVERY_MAX_INTERFACE_ATTEMPTS
            ;;
        "$RECOVERY_LEVEL_CONTAINER")
            max_attempts=$RECOVERY_MAX_CONTAINER_ATTEMPTS
            ;;
        "$RECOVERY_LEVEL_SERVICE")
            max_attempts=$RECOVERY_MAX_SERVICE_ATTEMPTS
            ;;
    esac
    
    # Get attempt count in the past 24 hours
    local attempts=$(get_recovery_attempts "$component" "$action" 86400)
    
    if [ "$attempts" -ge "$max_attempts" ]; then
        log "WARNING" "Maximum recovery attempts ($max_attempts) for $action reached in the past 24 hours"
        return 1
    fi
    
    return 0
}

# Progress to a more disruptive recovery level
# Usage: increase_recovery_level current_level
# Arguments:
#   current_level - Current recovery level
# Returns: New recovery level or "none" if max level reached
increase_recovery_level() {
    local current_level="$1"
    
    case "$current_level" in
        "$RECOVERY_LEVEL_INTERFACE")
            echo "$RECOVERY_LEVEL_CONTAINER"
            ;;
        "$RECOVERY_LEVEL_CONTAINER")
            echo "$RECOVERY_LEVEL_SERVICE"
            ;;
        "$RECOVERY_LEVEL_SERVICE")
            echo "$RECOVERY_LEVEL_NONE"  # No higher level available
            ;;
        *)
            log "ERROR" "Unknown recovery level: $current_level"
            echo "$RECOVERY_LEVEL_NONE"
            ;;
    esac
}

# Reset recovery state after successful recovery
# Usage: reset_recovery_state
# Returns: 0 on success, 1 on failure
reset_recovery_state() {
    # Reset current level
    RECOVERY_CURRENT_LEVEL="$RECOVERY_LEVEL_NONE"
    
    log "INFO" "Reset recovery state after successful recovery"
    return 0
}

# ==========================================
# Recovery action functions
# ==========================================

# Low-level recovery action to cycle the flannel interface
# Usage: cycle_flannel_interface [interface_name]
# Arguments:
#   interface_name - Optional interface name (default: flannel.1)
# Returns: 0 on success, 1 on failure
cycle_flannel_interface() {
    local interface="${1:-flannel.1}"
    
    # Check if interface exists
    if ! ip link show "$interface" &>/dev/null; then
        log "ERROR" "Interface $interface does not exist"
        return 1
    fi
    
    log "INFO" "Cycling interface $interface"
    
    # Remember the current MTU
    local current_mtu=$(ip link show "$interface" | grep -o 'mtu [0-9]*' | cut -d' ' -f2 || echo "1370")
    
    # Bring the interface down
    if ! ip link set "$interface" down; then
        log "ERROR" "Failed to bring interface $interface down"
        return 1
    fi
    
    # Short pause to ensure things settle
    sleep 2
    
    # Bring the interface back up
    if ! ip link set "$interface" up; then
        log "ERROR" "Failed to bring interface $interface up"
        return 1
    fi
    
    # Restore MTU if needed
    if [ "$current_mtu" != "1370" ]; then
        log "INFO" "Restoring MTU to $current_mtu"
        ip link set "$interface" mtu "$current_mtu"
    fi
    
    # Update cooldown timestamp for interface-level recovery with error handling
    if ! update_cooldown_timestamp "recovery_${RECOVERY_LEVEL_INTERFACE}"; then
        log "WARNING" "Failed to update cooldown timestamp for interface recovery"
    fi
    
    log "INFO" "Successfully cycled interface $interface"
    return 0
}

# Restart flannel container placeholder
# This will be replaced by implementation in recovery-actions.sh
# Usage: restart_flannel_container
# Returns: 0 on success, 1 on failure
restart_flannel_container() {
    log "INFO" "Would restart flannel container here"
    
    # Placeholder for actual implementation
    # In the future, this will delegate to recovery-actions.sh
    
    # Simulate success for testing with error handling
    if ! update_cooldown_timestamp "recovery_${RECOVERY_LEVEL_CONTAINER}"; then
        log "WARNING" "Failed to update cooldown timestamp for container recovery"
    fi
    
    return 0
}

# Restart Docker service placeholder
# This will be delegated to host-level services
# Usage: restart_docker_service
# Returns: 0 on success, 1 on failure
restart_docker_service() {
    log "WARNING" "Docker service restart requested - this action must be delegated to host-level services"
    
    # Check if we're in a container
    if [ -f "/.dockerenv" ]; then
        log "ERROR" "Cannot restart Docker service from within a container"
        return 1
    fi
    
    # Placeholder for actual implementation or delegation
    log "INFO" "This function would delegate to host-level services in production"
    
    # Simulate success for testing with error handling
    if ! update_cooldown_timestamp "recovery_${RECOVERY_LEVEL_SERVICE}"; then
        log "WARNING" "Failed to update cooldown timestamp for service recovery"
    fi
    
    # Return success for simulation purposes
    return 0
}

# ==========================================
# Recovery verification functions
# ==========================================

# Check if recovery action was successful
# Usage: verify_recovery_success "component1 component2 ..."
# Arguments:
#   components - Space-separated list of components that needed recovery
# Returns: 0 if successful, 1 if failed
verify_recovery_success() {
    local components="$1"
    local success=true
    local retry_attempts=3
    local wait_time=15
    
    # Check recovery history for insights
    local recent_history=$(get_recovery_history "general" 3)
    local recent_success_count=$(echo "$recent_history" | grep -c "success" || echo "0")
    
    if [ "$recent_success_count" -gt 0 ]; then
        log "INFO" "Recent successful recoveries detected, increasing confidence"
    fi
    
    # If no components specified, check system status
    if [ -z "$components" ]; then
        log "INFO" "No specific components to verify, checking overall system status"
        
        for ((attempt=1; attempt<=retry_attempts; attempt++)); do
            local system_status=$(get_system_status)
            
            if [ "$system_status" = "$MONITORING_STATUS_HEALTHY" ]; then
                log "INFO" "System status is healthy after recovery"
                return 0
            elif [ "$system_status" = "$MONITORING_STATUS_DEGRADED" ] && \
                 [ "$RECOVERY_CURRENT_LEVEL" = "$RECOVERY_LEVEL_INTERFACE" ]; then
                # For interface-level recovery, consider degraded status as success
                log "INFO" "System status improved to degraded after interface-level recovery"
                return 0
            fi
            
            log "INFO" "System status is still $system_status, waiting before retry (attempt $attempt/$retry_attempts)"
            sleep $wait_time
            wait_time=$((wait_time + 5))  # Increase wait time for next attempt
        done
        
        log "WARNING" "System status did not improve after recovery"
        return 1
    fi
    
    # Check each component
    for ((attempt=1; attempt<=retry_attempts; attempt++)); do
        success=true
        
        for component in $components; do
            local status_line=$(get_component_status "$component")
            local status=$(echo "$status_line" | cut -d':' -f1)
            
            # For interface-level recovery, consider degraded as success
            if [ "$RECOVERY_CURRENT_LEVEL" = "$RECOVERY_LEVEL_INTERFACE" ]; then
                if [ "$status" = "$MONITORING_STATUS_CRITICAL" ]; then
                    log "WARNING" "Component $component is still critical after recovery"
                    success=false
                    break
                fi
            else
                # For other recovery levels, only healthy is considered success
                if [ "$status" != "$MONITORING_STATUS_HEALTHY" ]; then
                    log "WARNING" "Component $component is still $status after recovery"
                    success=false
                    break
                fi
            fi
        done
        
        if $success; then
            log "INFO" "Recovery verification successful - components have improved status"
            return 0
        fi
        
        log "INFO" "Recovery not yet successful, waiting before retry (attempt $attempt/$retry_attempts)"
        sleep $wait_time
        wait_time=$((wait_time + 5))  # Increase wait time for next attempt
    done
    
    # Get last recovery timestamp for additional information
    local last_timestamp=$(get_last_recovery_timestamp "general" || echo "0")
    if [ "$last_timestamp" -gt 0 ]; then
        local time_since=$(($(date +%s) - last_timestamp))
        log "INFO" "Last successful recovery was $time_since seconds ago"
    fi
    
    log "WARNING" "Recovery verification failed - components still have issues"
    return 1
}

# ==========================================
# Utility functions
# ==========================================

# Get formatted timestamp for recovery operations
# Usage: get_recovery_timestamp
# Returns: Current timestamp as Unix epoch
get_recovery_timestamp() {
    date +%s
}

# Get list of components in critical state
# Usage: get_critical_components
# Returns: Space-separated list of critical components
get_critical_components() {
    local critical_components=""
    
    # Get all component statuses
    local component_statuses=$(get_all_component_statuses)
    
    # Extract critical components
    while IFS=: read -r component status timestamp message; do
        [ -z "$component" ] && continue
        
        if [ "$status" = "$MONITORING_STATUS_CRITICAL" ]; then
            critical_components="$critical_components $component"
        fi
    done <<< "$component_statuses"
    
    echo "$critical_components"
}

# Get list of components in degraded state
# Usage: get_degraded_components
# Returns: Space-separated list of degraded components
get_degraded_components() {
    local degraded_components=""
    
    # Get all component statuses
    local component_statuses=$(get_all_component_statuses)
    
    # Extract degraded components
    while IFS=: read -r component status timestamp message; do
        [ -z "$component" ] && continue
        
        if [ "$status" = "$MONITORING_STATUS_DEGRADED" ]; then
            degraded_components="$degraded_components $component"
        fi
    done <<< "$component_statuses"
    
    echo "$degraded_components"
}

# Export necessary functions and variables
export -f init_recovery_core
export -f run_recovery_sequence
export -f check_recovery_needed
export -f is_recovery_allowed
export -f cycle_flannel_interface
export -f verify_recovery_success
export -f increase_recovery_level
export -f reset_recovery_state
export -f get_recovery_timestamp
export -f restart_flannel_container
export -f restart_docker_service
export -f get_critical_components
export -f get_degraded_components

export RECOVERY_CHECK_INTERVAL
export RECOVERY_MAX_INTERFACE_ATTEMPTS
export RECOVERY_MAX_CONTAINER_ATTEMPTS
export RECOVERY_MAX_SERVICE_ATTEMPTS
export RECOVERY_CURRENT_LEVEL
