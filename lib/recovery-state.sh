#!/bin/bash
# recovery-state.sh
# State persistence and history tracking for flannel-registrar recovery
# Part of the minimalist multi-module recovery system

# Module information
MODULE_NAME="recovery-state"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common")

# ==========================================
# Global variables for recovery state
# ==========================================

# State directories and files
RECOVERY_STATE_DIR="${COMMON_STATE_DIR}/recovery"
RECOVERY_HISTORY_FILE="${RECOVERY_STATE_DIR}/recovery_history.log"
RECOVERY_ATTEMPTS_FILE="${RECOVERY_STATE_DIR}/recovery_attempts.dat"
RECOVERY_STATE_FILE="${RECOVERY_STATE_DIR}/recovery_state.json"

# Recovery level constants
RECOVERY_LEVEL_INTERFACE="interface"
RECOVERY_LEVEL_CONTAINER="container"
RECOVERY_LEVEL_SERVICE="service"
RECOVERY_LEVEL_NONE="none"  # Added missing recovery level constant

# Configurable cooldown periods (in seconds)
RECOVERY_INTERFACE_COOLDOWN=${RECOVERY_INTERFACE_COOLDOWN:-0}      # No cooldown for interface level
RECOVERY_CONTAINER_COOLDOWN=${RECOVERY_CONTAINER_COOLDOWN:-900}    # 15 minutes for container level
RECOVERY_SERVICE_COOLDOWN=${RECOVERY_SERVICE_COOLDOWN:-43200}      # 12 hours for service level

# Default history retention period (30 days in seconds)
RECOVERY_HISTORY_RETENTION=${RECOVERY_HISTORY_RETENTION:-2592000}

# Global associative arrays for state tracking
declare -A RECOVERY_ATTEMPTS
declare -A RECOVERY_COOLDOWNS
declare -A RECOVERY_LAST_SUCCESS

# ==========================================
# Module initialization
# ==========================================

# Initialize recovery state module
# Usage: init_recovery_state
# Returns: 0 on success, 1 on failure
init_recovery_state() {
    # Check dependencies
    if ! type log &>/dev/null; then
        echo "ERROR: Required function 'log' not found"
        return 1
    fi

    # Create state directories
    mkdir -p "$RECOVERY_STATE_DIR" || {
        log "ERROR" "Failed to create recovery state directory: $RECOVERY_STATE_DIR"
        return 1
    }

    # Initialize state files if they don't exist
    touch "$RECOVERY_HISTORY_FILE" 2>/dev/null || {
        log "WARNING" "Failed to create recovery history file, will retry later"
    }

    touch "$RECOVERY_ATTEMPTS_FILE" 2>/dev/null || {
        log "WARNING" "Failed to create recovery attempts file, will retry later"
    }

    if [ ! -f "$RECOVERY_STATE_FILE" ]; then
        # Create empty state file with minimal structure
        echo "{\"cooldowns\":{},\"last_success\":{}}" > "$RECOVERY_STATE_FILE" 2>/dev/null || {
            log "WARNING" "Failed to create recovery state file, will retry later"
        }
    fi

    # Initialize associative arrays
    declare -A RECOVERY_ATTEMPTS
    declare -A RECOVERY_COOLDOWNS
    declare -A RECOVERY_LAST_SUCCESS

    # Load recovery state from disk
    load_recovery_state

    # Prune old history entries
    prune_old_history

    log "INFO" "Initialized recovery-state module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Recovery attempt tracking functions
# ==========================================

# Record a recovery attempt
# Usage: save_recovery_attempt component action result [message]
# Arguments:
#   component - Component name (e.g., "network.interface")
#   action - Recovery action performed (e.g., "cycle_interface")
#   result - Result of the recovery attempt ("success" or "failure")
#   message - Optional message with details
# Returns: 0 on success, 1 on failure
save_recovery_attempt() {
    local component="$1"
    local action="$2"
    local result="$3"
    local message="${4:-}"
    local timestamp=$(date +%s)
    
    # Validate inputs
    if [ -z "$component" ] || [ -z "$action" ] || [ -z "$result" ]; then
        log "ERROR" "Missing required parameters for save_recovery_attempt"
        return 1
    fi
    
    # Create entry key for attempt tracking
    local attempt_key="${component}:${action}"
    
    # Update attempt count
    local current_count=0
    if [ -n "${RECOVERY_ATTEMPTS[$attempt_key]}" ]; then
        current_count=${RECOVERY_ATTEMPTS[$attempt_key]}
    fi
    RECOVERY_ATTEMPTS[$attempt_key]=$((current_count + 1))
    
    # If successful, update last success timestamp
    if [ "$result" = "success" ]; then
        RECOVERY_LAST_SUCCESS[$component]=$timestamp
    fi
    
    # Create history entry
    local history_entry="${timestamp}:${component}:${action}:${result}:${message}"
    
    # Append to history file
    echo "$history_entry" >> "$RECOVERY_HISTORY_FILE" || {
        log "ERROR" "Failed to write to recovery history file: $RECOVERY_HISTORY_FILE"
        return 1
    }
    
    # Update attempts file
    echo "${attempt_key}=${RECOVERY_ATTEMPTS[$attempt_key]}" >> "$RECOVERY_ATTEMPTS_FILE.new" || {
        log "ERROR" "Failed to update recovery attempts file: $RECOVERY_ATTEMPTS_FILE.new"
        return 1
    }
    
    # Save state to disk
    save_recovery_state || {
        log "WARNING" "Failed to save recovery state after recording attempt"
        return 1
    }
    
    log "INFO" "Recorded recovery attempt: $component, $action, $result"
    return 0
}

# Get count and history of recovery attempts
# Usage: get_recovery_attempts component action [timeframe]
# Arguments:
#   component - Component name (e.g., "network.interface")
#   action - Recovery action (e.g., "cycle_interface")
#   timeframe - Optional timeframe in seconds (default: 86400 - 24 hours)
# Returns: Number of attempts in the specified timeframe
get_recovery_attempts() {
    local component="$1"
    local action="$2"
    local timeframe="${3:-86400}"  # Default to 24 hours
    local attempt_key="${component}:${action}"
    local current_time=$(date +%s)
    local count=0
    
    # Validate inputs
    if [ -z "$component" ] || [ -z "$action" ]; then
        log "ERROR" "Missing required parameters for get_recovery_attempts: component=$component, action=$action"
        return 0
    fi
    
    # First check the in-memory count
    if [ -n "${RECOVERY_ATTEMPTS[$attempt_key]}" ]; then
        count=${RECOVERY_ATTEMPTS[$attempt_key]}
    fi
    
    # If timeframe is 0, return the total count
    if [ "$timeframe" -eq 0 ]; then
        echo "$count"
        return 0
    fi
    
    # Otherwise, count attempts within the timeframe from history
    local cutoff_time=$((current_time - timeframe))
    local recent_count=0
    
    # Read the history file and count recent attempts
    if [ -f "$RECOVERY_HISTORY_FILE" ]; then
        while IFS=: read -r timestamp comp act result msg; do
            # Skip invalid entries
            [ -z "$timestamp" ] && continue
            
            # Check if entry matches component and action
            if [ "$comp" = "$component" ] && [ "$act" = "$action" ]; then
                # Check if it's within the timeframe
                if [ "$timestamp" -ge "$cutoff_time" ]; then
                    recent_count=$((recent_count + 1))
                fi
            fi
        done < "$RECOVERY_HISTORY_FILE"
    fi
    
    # Return the recent count
    echo "$recent_count"
    return 0
}

# Update cooldown timestamp for a specific action
# Usage: update_cooldown_timestamp action
# Arguments:
#   action - Recovery action (e.g., "restart_container")
# Returns: 0 on success, 1 on failure
update_cooldown_timestamp() {
    local action="$1"
    local timestamp=$(date +%s)
    
    # Validate input
    if [ -z "$action" ]; then
        log "ERROR" "Missing required parameter for update_cooldown_timestamp: action not specified"
        return 1
    fi
    
    # Update cooldown timestamp
    RECOVERY_COOLDOWNS["$action"]=$timestamp
    
    # Save state to disk
    save_recovery_state || {
        log "WARNING" "Failed to save recovery state after updating cooldown for $action"
        return 1
    }
    
    log "DEBUG" "Updated cooldown timestamp for $action: $timestamp"
    return 0
}

# Check if an action is in cooldown period
# Usage: is_in_cooldown action
# Arguments:
#   action - Recovery action (e.g., "restart_container")
# Returns: 0 if in cooldown, 1 if not in cooldown
is_in_cooldown() {
    local action="$1"
    local current_time=$(date +%s)
    local cooldown_period=0
    local last_action_time=0
    
    # Validate input
    if [ -z "$action" ]; then
        log "ERROR" "Missing required parameter for is_in_cooldown: action not specified"
        return 1  # Not in cooldown (safety default)
    fi
    
    # Determine cooldown period based on action type
    case "$action" in
        *interface*)
            cooldown_period=$RECOVERY_INTERFACE_COOLDOWN
            ;;
        *container*)
            cooldown_period=$RECOVERY_CONTAINER_COOLDOWN
            ;;
        *service*)
            cooldown_period=$RECOVERY_SERVICE_COOLDOWN
            ;;
        *)
            # Default to container cooldown for unknown actions
            cooldown_period=$RECOVERY_CONTAINER_COOLDOWN
            ;;
    esac
    
    # If cooldown period is 0, never in cooldown
    if [ "$cooldown_period" -eq 0 ]; then
        return 1  # Not in cooldown
    fi
    
    # Get last action time
    if [ -n "${RECOVERY_COOLDOWNS[$action]}" ]; then
        last_action_time=${RECOVERY_COOLDOWNS[$action]}
    else
        return 1  # Not in cooldown (no previous action)
    fi
    
    # Check if we're still in cooldown period
    local time_elapsed=$((current_time - last_action_time))
    if [ "$time_elapsed" -lt "$cooldown_period" ]; then
        log "DEBUG" "Action $action is in cooldown: $time_elapsed/$cooldown_period seconds elapsed"
        return 0  # In cooldown
    else
        return 1  # Not in cooldown
    fi
}

# ==========================================
# History management functions
# ==========================================

# Remove old history entries
# Usage: prune_old_history [max_age]
# Arguments:
#   max_age - Maximum age in seconds (default: RECOVERY_HISTORY_RETENTION)
# Returns: 0 on success, 1 on failure
prune_old_history() {
    local max_age="${1:-$RECOVERY_HISTORY_RETENTION}"
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - max_age))
    local temp_file="${RECOVERY_STATE_DIR}/history.tmp.$$"
    
    # Check if history file exists
    if [ ! -f "$RECOVERY_HISTORY_FILE" ]; then
        return 0  # Nothing to prune
    fi
    
    # Filter out old entries
    while IFS=: read -r timestamp rest; do
        # Skip invalid entries
        [ -z "$timestamp" ] && continue
        
        # Keep only entries newer than cutoff time
        if [ "$timestamp" -ge "$cutoff_time" ]; then
            echo "$timestamp:$rest" >> "$temp_file"
        fi
    done < "$RECOVERY_HISTORY_FILE"
    
    # Check if temp file was created
    if [ -f "$temp_file" ]; then
        # Replace history file with filtered version
        mv "$temp_file" "$RECOVERY_HISTORY_FILE" || {
            log "ERROR" "Failed to update history file during pruning: mv $temp_file $RECOVERY_HISTORY_FILE"
            rm -f "$temp_file"
            return 1
        }
    else
        # If no entries remain, create empty file
        > "$RECOVERY_HISTORY_FILE"
    fi
    
    log "DEBUG" "Pruned recovery history entries older than $max_age seconds"
    return 0
}

# Get recovery history
# Usage: get_recovery_history [component] [limit]
# Arguments:
#   component - Optional component filter
#   limit - Optional limit of entries to return (default: 20)
# Returns: Recovery history entries (one per line)
get_recovery_history() {
    local component="$1"
    local limit="${2:-20}"
    
    # Check if history file exists
    if [ ! -f "$RECOVERY_HISTORY_FILE" ]; then
        echo "No recovery history available"
        return 0
    fi
    
    # Apply component filter if specified
    if [ -n "$component" ]; then
        # Filter by component and apply limit
        grep ":${component}:" "$RECOVERY_HISTORY_FILE" | sort -r | head -n "$limit"
    else
        # Just apply limit
        sort -r "$RECOVERY_HISTORY_FILE" | head -n "$limit"
    fi
    
    return 0
}

# ==========================================
# State persistence functions
# ==========================================

# Save recovery state to disk
# Usage: save_recovery_state
# Returns: 0 on success, 1 on failure
save_recovery_state() {
    local temp_file="${RECOVERY_STATE_DIR}/state.tmp.$$"
    
    # Create JSON-like structure for state
    echo "{" > "$temp_file"
    
    # Add cooldowns section
    echo "  \"cooldowns\": {" >> "$temp_file"
    local first_cooldown=true
    for action in "${!RECOVERY_COOLDOWNS[@]}"; do
        if ! $first_cooldown; then
            echo "," >> "$temp_file"
        fi
        echo -n "    \"$action\": ${RECOVERY_COOLDOWNS[$action]}" >> "$temp_file"
        first_cooldown=false
    done
    echo "" >> "$temp_file"
    echo "  }," >> "$temp_file"
    
    # Add last success section
    echo "  \"last_success\": {" >> "$temp_file"
    local first_success=true
    for component in "${!RECOVERY_LAST_SUCCESS[@]}"; do
        if ! $first_success; then
            echo "," >> "$temp_file"
        fi
        echo -n "    \"$component\": ${RECOVERY_LAST_SUCCESS[$component]}" >> "$temp_file"
        first_success=false
    done
    echo "" >> "$temp_file"
    echo "  }" >> "$temp_file"
    
    # Close JSON structure
    echo "}" >> "$temp_file"
    
    # Atomically replace state file
    mv "$temp_file" "$RECOVERY_STATE_FILE" || {
        log "ERROR" "Failed to update recovery state file: mv $temp_file $RECOVERY_STATE_FILE"
        rm -f "$temp_file"
        return 1
    }
    
    # Also save attempts to separate file for easy access
    > "$RECOVERY_ATTEMPTS_FILE.new"  # Clear file
    for key in "${!RECOVERY_ATTEMPTS[@]}"; do
        echo "${key}=${RECOVERY_ATTEMPTS[$key]}" >> "$RECOVERY_ATTEMPTS_FILE.new"
    done
    
    # Atomically replace attempts file
    mv "$RECOVERY_ATTEMPTS_FILE.new" "$RECOVERY_ATTEMPTS_FILE" || {
        log "ERROR" "Failed to update recovery attempts file: mv $RECOVERY_ATTEMPTS_FILE.new $RECOVERY_ATTEMPTS_FILE"
        return 1
    }
    
    log "DEBUG" "Saved recovery state to disk"
    return 0
}

# Load recovery state from disk
# Usage: load_recovery_state
# Returns: 0 on success, 1 on failure
load_recovery_state() {
    # Reset arrays
    declare -A RECOVERY_ATTEMPTS
    declare -A RECOVERY_COOLDOWNS
    declare -A RECOVERY_LAST_SUCCESS
    
    # Load attempts from file
    if [ -f "$RECOVERY_ATTEMPTS_FILE" ]; then
        while IFS== read -r key value; do
            [ -z "$key" ] && continue
            RECOVERY_ATTEMPTS["$key"]=$value
        done < "$RECOVERY_ATTEMPTS_FILE"
        log "DEBUG" "Loaded ${#RECOVERY_ATTEMPTS[@]} recovery attempt records from disk"
    else
        log "DEBUG" "No existing recovery attempts file found"
    fi
    
    # Load state from file
    if [ -f "$RECOVERY_STATE_FILE" ]; then
        # Parse cooldowns (simple approach without jq)
        while read -r line; do
            # Parse cooldowns section
            if echo "$line" | grep -q "\".*\": [0-9]"; then
                if [ -n "$(echo "$line" | grep "cooldowns")" ] || [ -n "$COOLDOWNS_SECTION" ]; then
                    local COOLDOWNS_SECTION=1
                    local key=$(echo "$line" | grep -o '"[^"]*"' | head -1 | tr -d '"')
                    local value=$(echo "$line" | grep -o '[0-9]*')
                    
                    if [ -n "$key" ] && [ -n "$value" ]; then
                        RECOVERY_COOLDOWNS["$key"]=$value
                    fi
                fi
                
                # Parse last_success section
                if [ -n "$(echo "$line" | grep "last_success")" ] || [ -n "$SUCCESS_SECTION" ]; then
                    local SUCCESS_SECTION=1
                    local COOLDOWNS_SECTION=
                    local key=$(echo "$line" | grep -o '"[^"]*"' | head -1 | tr -d '"')
                    local value=$(echo "$line" | grep -o '[0-9]*')
                    
                    if [ -n "$key" ] && [ -n "$value" ]; then
                        RECOVERY_LAST_SUCCESS["$key"]=$value
                    fi
                fi
            fi
        done < "$RECOVERY_STATE_FILE"
        
        log "DEBUG" "Loaded ${#RECOVERY_COOLDOWNS[@]} cooldown records and ${#RECOVERY_LAST_SUCCESS[@]} success records from disk"
    else
        log "DEBUG" "No existing recovery state file found"
    fi
    
    return 0
}

# Get timestamp of last recovery action
# Usage: get_last_recovery_timestamp component
# Arguments:
#   component - Component name (e.g., "network.interface")
# Returns: Timestamp of last recovery or 0 if none
get_last_recovery_timestamp() {
    local component="$1"
    
    # Validate input
    if [ -z "$component" ]; then
        log "ERROR" "Missing required parameter for get_last_recovery_timestamp: component not specified"
        return 0
    fi
    
    # Check if we have a last success timestamp
    if [ -n "${RECOVERY_LAST_SUCCESS[$component]}" ]; then
        echo "${RECOVERY_LAST_SUCCESS[$component]}"
    else
        echo "0"
    fi
    
    return 0
}

# Export necessary functions and variables
export -f init_recovery_state
export -f save_recovery_attempt
export -f get_recovery_attempts
export -f update_cooldown_timestamp
export -f is_in_cooldown
export -f prune_old_history
export -f get_recovery_history
export -f save_recovery_state
export -f load_recovery_state
export -f get_last_recovery_timestamp

export RECOVERY_STATE_DIR
export RECOVERY_LEVEL_INTERFACE
export RECOVERY_LEVEL_CONTAINER
export RECOVERY_LEVEL_SERVICE
export RECOVERY_LEVEL_NONE
export RECOVERY_INTERFACE_COOLDOWN
export RECOVERY_CONTAINER_COOLDOWN
export RECOVERY_SERVICE_COOLDOWN
