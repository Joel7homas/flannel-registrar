#!/bin/bash
# monitoring-core.sh
# Core status tracking functions for flannel-registrar monitoring
# Minimalist implementation focusing solely on component status tracking

# Module information
MODULE_NAME="monitoring-core"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib")

# ==========================================
# Global variables for monitoring
# ==========================================

# State directories and files
MONITORING_STATE_DIR="${COMMON_STATE_DIR}/monitoring"
MONITORING_STATUS_FILE="${MONITORING_STATE_DIR}/status.dat"
MONITORING_TEMP_DIR="${MONITORING_STATE_DIR}/temp"

# Status values
MONITORING_STATUS_HEALTHY="healthy"
MONITORING_STATUS_DEGRADED="degraded" 
MONITORING_STATUS_CRITICAL="critical"
MONITORING_STATUS_UNKNOWN="unknown"

# ==========================================
# Module initialization
# ==========================================

# Initialize monitoring core
# Usage: init_monitoring_core
# Returns: 0 on success, 1 on failure
init_monitoring_core() {
    # Check dependencies
    if ! type log &>/dev/null; then
        echo "ERROR: Required function 'log' not found"
        return 1
    fi

    # Create state directories
    mkdir -p "$MONITORING_STATE_DIR" "$MONITORING_TEMP_DIR" || {
        log "ERROR" "Failed to create monitoring state directories"
        return 1
    }

    # Create empty status file if it doesn't exist
    if [ ! -f "$MONITORING_STATUS_FILE" ]; then
        touch "$MONITORING_STATUS_FILE" || {
            log "ERROR" "Failed to create monitoring status file"
            return 1
        }
    fi

    log "INFO" "Initialized monitoring-core module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Status management functions
# ==========================================

# Update a component's status
# Usage: update_component_status component status [message]
# Arguments:
#   component - Component name (no colons)
#   status - Status (healthy, degraded, critical, unknown)
#   message - Optional status message
# Returns: 0 on success, 1 on failure
update_component_status() {
    local component="$1"
    local status="$2"
    local message="${3:-}"
    local timestamp=$(get_status_timestamp)
    
    # Basic validation
    if [ -z "$component" ] || [[ "$component" == *:* ]]; then
        log "ERROR" "Invalid component name (must not contain colons): $component"
        return 1
    fi
    
    case "$status" in
        "$MONITORING_STATUS_HEALTHY"|"$MONITORING_STATUS_DEGRADED"|"$MONITORING_STATUS_CRITICAL"|"$MONITORING_STATUS_UNKNOWN")
            ;;
        *)
            log "ERROR" "Invalid status value: $status"
            return 1
            ;;
    esac
    
    # Check if status has changed
    if has_status_changed "$component" "$status"; then
        process_status_transition "$component" "$status" "$message"
    fi
    
    # Create component status line
    local status_line="${component}:${status}:${timestamp}:${message}"
    
    # Update status file (remove old entry if exists, then append new one)
    local temp_file="${MONITORING_TEMP_DIR}/status.tmp.$$"
    grep -v "^${component}:" "$MONITORING_STATUS_FILE" > "$temp_file" 2>/dev/null || true
    echo "$status_line" >> "$temp_file"
    
    # Atomically replace the status file
    if ! mv "$temp_file" "$MONITORING_STATUS_FILE"; then
        log "ERROR" "Failed to update status file for component $component"
        rm -f "$temp_file"
        return 1
    fi
    
    log "DEBUG" "Updated status for $component: $status"
    return 0
}

# Get current status of a component
# Usage: get_component_status component
# Arguments:
#   component - Component name
# Returns: Status string (status:timestamp:message) or empty if not found
get_component_status() {
    local component="$1"
    
    if [ -z "$component" ]; then
        log "ERROR" "Component name required"
        return 1
    fi
    
    # Read component status from file
    if [ -f "$MONITORING_STATUS_FILE" ]; then
        local status_line=$(grep "^${component}:" "$MONITORING_STATUS_FILE")
        if [ -n "$status_line" ]; then
            # Return just the status part (without component name)
            echo "${status_line#${component}:}"
            return 0
        fi
    fi
    
    # Return empty if component not found
    echo "${MONITORING_STATUS_UNKNOWN}:$(get_status_timestamp):"
    return 0
}

# Get all component statuses
# Usage: get_all_component_statuses
# Returns: List of component statuses in format "component:status:timestamp:message"
get_all_component_statuses() {
    # Check if status file exists
    if [ ! -f "$MONITORING_STATUS_FILE" ]; then
        log "WARNING" "Status file does not exist"
        return 0
    fi
    
    # Return all status entries
    cat "$MONITORING_STATUS_FILE"
    return 0
}

# Get overall system status summary
# Usage: get_system_status
# Returns: Overall status (healthy, degraded, critical, or unknown)
get_system_status() {
    local overall_status="$MONITORING_STATUS_HEALTHY"
    
    # If status file doesn't exist or is empty, return unknown
    if [ ! -f "$MONITORING_STATUS_FILE" ] || [ ! -s "$MONITORING_STATUS_FILE" ]; then
        echo "$MONITORING_STATUS_UNKNOWN"
        return 0
    fi
    
    # Check each component status
    while IFS=: read -r component status timestamp message; do
        # Skip empty lines
        [ -z "$component" ] && continue
        
        # If any component is critical, system is critical
        if [ "$status" = "$MONITORING_STATUS_CRITICAL" ]; then
            overall_status="$MONITORING_STATUS_CRITICAL"
            break
        fi
        
        # If any component is degraded and system isn't critical, system is degraded
        if [ "$status" = "$MONITORING_STATUS_DEGRADED" ] && \
           [ "$overall_status" != "$MONITORING_STATUS_CRITICAL" ]; then
            overall_status="$MONITORING_STATUS_DEGRADED"
        fi
    done < "$MONITORING_STATUS_FILE"
    
    echo "$overall_status"
    return 0
}

# Manage status file operations (read/write)
# Usage: manage_status_file operation source_or_dest_file
# Arguments:
#   operation - "read" or "write"
#   source_or_dest_file - Source file (for write) or destination file (for read)
# Returns: 0 on success, 1 on failure
manage_status_file() {
    local operation="$1"
    local file_path="$2"
    
    if [ -z "$operation" ] || [ -z "$file_path" ]; then
        log "ERROR" "Operation and file path required"
        return 1
    fi
    
    case "$operation" in
        "read")
            if [ ! -f "$MONITORING_STATUS_FILE" ]; then
                log "WARNING" "Status file does not exist"
                touch "$file_path"
                return 0
            fi
            
            if ! cp "$MONITORING_STATUS_FILE" "$file_path"; then
                log "ERROR" "Failed to copy status file to $file_path"
                return 1
            fi
            ;;
        "write")
            if [ ! -f "$file_path" ]; then
                log "ERROR" "Source file does not exist: $file_path"
                return 1
            fi
            
            local temp_file="${MONITORING_TEMP_DIR}/status.tmp.$$"
            
            # Copy source file to temp file
            if ! cp "$file_path" "$temp_file"; then
                log "ERROR" "Failed to copy status from $file_path"
                return 1
            fi
            
            # Atomically replace the status file
            if ! mv "$temp_file" "$MONITORING_STATUS_FILE"; then
                log "ERROR" "Failed to update status file"
                rm -f "$temp_file"
                return 1
            fi
            
            log "DEBUG" "Updated status file from $file_path"
            ;;
        *)
            log "ERROR" "Invalid operation: $operation (must be 'read' or 'write')"
            return 1
            ;;
    esac
    
    return 0
}

# Check if component status has changed
# Usage: has_status_changed component new_status
# Arguments:
#   component - Component name
#   new_status - New status to compare with current
# Returns: 0 if changed, 1 if unchanged
has_status_changed() {
    local component="$1"
    local new_status="$2"
    
    # Get current status
    local current_status_line=$(get_component_status "$component")
    if [ -z "$current_status_line" ]; then
        # No current status, so it has changed
        return 0
    fi
    
    # Extract just the status part (before the first colon)
    local current_status=$(echo "$current_status_line" | cut -d':' -f1)
    
    # Compare current and new status
    if [ "$current_status" = "$new_status" ]; then
        return 1  # Unchanged
    else
        return 0  # Changed
    fi
}

# Process status transition
# Usage: process_status_transition component new_status [message]
# Arguments:
#   component - Component name
#   new_status - New status value
#   message - Optional message
# Returns: 0 on success, 1 on failure
process_status_transition() {
    local component="$1"
    local new_status="$2"
    local message="${3:-}"
    
    # Get current status
    local current_status_line=$(get_component_status "$component")
    local current_status=$(echo "$current_status_line" | cut -d':' -f1)
    
    # Determine log level based on new status
    local log_level="INFO"
    case "$new_status" in
        "$MONITORING_STATUS_DEGRADED")
            log_level="WARNING"
            ;;
        "$MONITORING_STATUS_CRITICAL")
            log_level="ERROR"
            ;;
    esac
    
    # Log the transition
    if [ -z "$message" ]; then
        log "$log_level" "Component $component status changed: $current_status → $new_status"
    else
        log "$log_level" "Component $component status changed: $current_status → $new_status ($message)"
    fi
    
    return 0
}

# ==========================================
# Utility functions
# ==========================================

# Get formatted timestamp for status entries
# Usage: get_status_timestamp
# Returns: Current timestamp as Unix epoch
get_status_timestamp() {
    date +%s
}

# Check if status data is outdated
# Usage: is_status_stale component max_age_seconds
# Arguments:
#   component - Component name
#   max_age_seconds - Maximum acceptable age in seconds
# Returns: 0 if stale, 1 if current
is_status_stale() {
    local component="$1"
    local max_age="$2"
    
    if [ -z "$component" ] || [ -z "$max_age" ]; then
        return 1
    fi
    
    # Get component status line
    local status_line=$(get_component_status "$component")
    if [ -z "$status_line" ]; then
        return 0  # No status = stale
    fi
    
    # Extract timestamp
    local timestamp=$(echo "$status_line" | cut -d':' -f2)
    if [ -z "$timestamp" ] || ! [[ "$timestamp" =~ ^[0-9]+$ ]]; then
        return 0  # Invalid timestamp = stale
    fi
    
    # Calculate age
    local current_time=$(get_status_timestamp)
    local age=$((current_time - timestamp))
    
    # Check if age exceeds maximum
    if [ $age -gt $max_age ]; then
        return 0  # Stale
    else
        return 1  # Current
    fi
}

# Export necessary functions and variables
export -f init_monitoring_core
export -f update_component_status
export -f get_component_status
export -f get_all_component_statuses
export -f get_system_status
export -f manage_status_file
export -f has_status_changed
export -f process_status_transition
export -f get_status_timestamp
export -f is_status_stale

export MONITORING_STATE_DIR
export MONITORING_STATUS_FILE
export MONITORING_TEMP_DIR
export MONITORING_STATUS_HEALTHY
export MONITORING_STATUS_DEGRADED
export MONITORING_STATUS_CRITICAL
export MONITORING_STATUS_UNKNOWN

