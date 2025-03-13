#!/bin/bash
# monitoring-reporting.sh
# Status reporting and notification functions for flannel-registrar monitoring
# Part of the minimalist multi-module monitoring system

# Module information
MODULE_NAME="monitoring-reporting"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "monitoring-core")

# ==========================================
# Global variables for reporting
# ==========================================

# State directories and files
REPORTING_STATE_DIR="${MONITORING_STATE_DIR}/reporting"
REPORTING_HISTORY_FILE="${REPORTING_STATE_DIR}/status_history.log"
REPORTING_NOTIFICATION_FILE="${REPORTING_STATE_DIR}/notifications.log"

# History and notification settings
REPORTING_MAX_HISTORY=${REPORTING_MAX_HISTORY:-100}  # Maximum history entries
REPORTING_NOTIFICATION_LEVELS=("info" "warning" "critical")

# ==========================================
# Module initialization
# ==========================================

# Initialize reporting module
# Usage: init_monitoring_reporting
# Returns: 0 on success, 1 on failure
init_monitoring_reporting() {
    # Check dependencies
    for dep in log get_component_status get_system_status get_all_component_statuses; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found"
            return 1
        fi
    done

    # Create state directories
    mkdir -p "$REPORTING_STATE_DIR" || {
        log "ERROR" "Failed to create reporting state directory: $REPORTING_STATE_DIR"
        return 1
    }

    # Initialize history file if it doesn't exist
    if [ ! -f "$REPORTING_HISTORY_FILE" ]; then
        touch "$REPORTING_HISTORY_FILE" || {
            log "ERROR" "Failed to create history file: $REPORTING_HISTORY_FILE"
            return 1
        }
    fi

    # Initialize notification file if it doesn't exist
    if [ ! -f "$REPORTING_NOTIFICATION_FILE" ]; then
        touch "$REPORTING_NOTIFICATION_FILE" || {
            log "ERROR" "Failed to create notification file: $REPORTING_NOTIFICATION_FILE"
            return 1
        }
    fi

    log "INFO" "Initialized monitoring-reporting module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Status summary functions
# ==========================================

# Get a concise status summary
# Usage: get_status_summary
# Returns: Brief status summary text
get_status_summary() {
    local system_status=$(get_system_status)
    local timestamp=$(date +%s)
    local summary="time:$timestamp\tstatus:$system_status"
    
    # Count components by status
    local healthy_count=0
    local degraded_count=0
    local critical_count=0
    local unknown_count=0
    
    # Get all component statuses and process them
    local component_statuses=$(get_all_component_statuses)
    
    while IFS=: read -r component status rest; do
        [ -z "$component" ] && continue
        
        case "$status" in
            "$MONITORING_STATUS_HEALTHY") healthy_count=$((healthy_count + 1)) ;;
            "$MONITORING_STATUS_DEGRADED") degraded_count=$((degraded_count + 1)) ;;
            "$MONITORING_STATUS_CRITICAL") critical_count=$((critical_count + 1)) ;;
            *) unknown_count=$((unknown_count + 1)) ;;
        esac
    done <<< "$component_statuses"
    
    # Add counts to summary
    summary+="\thealthy:$healthy_count\tdegraded:$degraded_count"
    summary+="\tcritical:$critical_count\tunknown:$unknown_count"
    
    echo "$summary"
    return 0
}

# Get detailed status for specific component or component group
# Usage: get_component_summary [component_filter]
# Arguments:
#   component_filter - Optional filter (exact name or prefix with *)
# Returns: Detailed component status information
get_component_summary() {
    local filter="$1"
    local summary=""
    
    # Get all component statuses using the API
    local component_statuses=$(get_all_component_statuses)
    
    # Process component statuses line by line
    while IFS=: read -r component status timestamp message; do
        [ -z "$component" ] && continue
        
        # Check if component matches filter
        if [ -n "$filter" ]; then
            if [[ "$filter" == *"*" ]]; then
                # Prefix matching (e.g., "network.*")
                local prefix="${filter%\*}"
                [[ "$component" == "$prefix"* ]] || continue
            else
                # Exact matching
                [ "$component" = "$filter" ] || continue
            fi
        fi
        
        # Add component info to summary
        summary+="$component:$status:$timestamp:$message\n"
    done <<< "$component_statuses"
    
    echo -e "$summary"
    return 0
}

# ==========================================
# Formatting functions
# ==========================================

# Format status as plain text
# Usage: format_status_text [component_filter]
# Arguments:
#   component_filter - Optional filter (exact name or prefix with *)
# Returns: Human-readable text status report
format_status_text() {
    local filter="$1"
    local system_status=$(get_system_status)
    local report="System Status: $system_status (as of $(date))\n\n"
    
    # Add summary counts
    local summary=$(get_status_summary)
    local healthy=$(echo "$summary" | grep -o "healthy:[0-9]*" | cut -d':' -f2)
    local degraded=$(echo "$summary" | grep -o "degraded:[0-9]*" | cut -d':' -f2)
    local critical=$(echo "$summary" | grep -o "critical:[0-9]*" | cut -d':' -f2)
    local unknown=$(echo "$summary" | grep -o "unknown:[0-9]*" | cut -d':' -f2)
    
    report+="Components: $healthy healthy, $degraded degraded, "
    report+="$critical critical, $unknown unknown\n\n"
    report+="Component Details:\n"
    report+="==================\n"
    
    # Add component details
    local component_data=$(get_component_summary "$filter")
    if [ -z "$component_data" ]; then
        report+="No matching components found.\n"
    else
        while IFS=: read -r component status timestamp message; do
            [ -z "$component" ] && continue
            
            local status_time=$(date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || 
                               date -r "$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null ||
                               echo "Unknown time")
            
            report+="$component: $status\n"
            report+="  Last Updated: $status_time\n"
            report+="  Message: $message\n\n"
        done <<< "$component_data"
    fi
    
    echo -e "$report"
    return 0
}

# Format status as key-value pairs
# Usage: format_status_keyvalue [component_filter]
# Arguments:
#   component_filter - Optional filter (exact name or prefix with *)
# Returns: Status formatted as key=value pairs
format_status_keyvalue() {
    local filter="$1"
    local system_status=$(get_system_status)
    local timestamp=$(date +%s)
    local output="timestamp=$timestamp\n"
    output+="system_status=$system_status\n"
    
    # Add summary counts
    local summary=$(get_status_summary)
    local healthy=$(echo "$summary" | grep -o "healthy:[0-9]*" | cut -d':' -f2)
    local degraded=$(echo "$summary" | grep -o "degraded:[0-9]*" | cut -d':' -f2)
    local critical=$(echo "$summary" | grep -o "critical:[0-9]*" | cut -d':' -f2)
    local unknown=$(echo "$summary" | grep -o "unknown:[0-9]*" | cut -d':' -f2)
    
    output+="healthy_count=$healthy\n"
    output+="degraded_count=$degraded\n"
    output+="critical_count=$critical\n"
    output+="unknown_count=$unknown\n"
    
    # Add component details
    local component_data=$(get_component_summary "$filter")
    local index=0
    
    while IFS=: read -r component status timestamp message; do
        [ -z "$component" ] && continue
        
        output+="component_${index}_name=$component\n"
        output+="component_${index}_status=$status\n"
        output+="component_${index}_timestamp=$timestamp\n"
        output+="component_${index}_message=$message\n"
        
        index=$((index + 1))
    done <<< "$component_data"
    
    output+="component_count=$index\n"
    
    echo -e "$output"
    return 0
}

# Format status as simple JSON
# Usage: format_status_json [component_filter]
# Arguments:
#   component_filter - Optional filter (exact name or prefix with *)
# Returns: Status formatted as JSON
format_status_json() {
    local filter="$1"
    local system_status=$(get_system_status)
    local timestamp=$(date +%s)
    
    # Start JSON output
    local json="{\n"
    json+="  \"timestamp\": $timestamp,\n"
    json+="  \"system_status\": \"$system_status\",\n"
    
    # Add summary counts
    local summary=$(get_status_summary)
    local healthy=$(echo "$summary" | grep -o "healthy:[0-9]*" | cut -d':' -f2)
    local degraded=$(echo "$summary" | grep -o "degraded:[0-9]*" | cut -d':' -f2)
    local critical=$(echo "$summary" | grep -o "critical:[0-9]*" | cut -d':' -f2)
    local unknown=$(echo "$summary" | grep -o "unknown:[0-9]*" | cut -d':' -f2)
    
    json+="  \"counts\": {\n"
    json+="    \"healthy\": $healthy,\n"
    json+="    \"degraded\": $degraded,\n"
    json+="    \"critical\": $critical,\n"
    json+="    \"unknown\": $unknown\n"
    json+="  },\n"
    
    # Add components
    json+="  \"components\": [\n"
    
    # Get component details
    local component_data=$(get_component_summary "$filter")
    local first_component=true
    
    while IFS=: read -r component status timestamp message; do
        [ -z "$component" ] && continue
        
        # Add comma for all but first component
        if $first_component; then
            first_component=false
        else
            json+=",\n"
        fi
        
        json+="    {\n"
        json+="      \"name\": \"$component\",\n"
        json+="      \"status\": \"$status\",\n"
        json+="      \"timestamp\": $timestamp,\n"
        json+="      \"message\": \"$message\"\n"
        json+="    }"
    done <<< "$component_data"
    
    # Close JSON structure
    json+="\n  ]\n"
    json+="}\n"
    
    echo -e "$json"
    return 0
}

# ==========================================
# History and notification functions
# ==========================================

# Log significant status changes to history file
# Usage: log_status_change component old_status new_status message
# Arguments:
#   component - Component name
#   old_status - Previous status
#   new_status - New status
#   message - Status message
# Returns: 0 on success, 1 on failure
log_status_change() {
    local component="$1"
    local old_status="$2"
    local new_status="$3"
    local message="$4"
    local timestamp=$(date +%s)
    
    # Skip if component or statuses are empty
    if [ -z "$component" ] || [ -z "$new_status" ]; then
        return 1
    fi
    
    # Create history entry
    local entry="$timestamp:$component:$old_status:$new_status:$message"
    
    # Append to history file
    echo "$entry" >> "$REPORTING_HISTORY_FILE" || {
        log "ERROR" "Failed to write to history file"
        return 1
    }
    
    # Keep only the most recent entries
    if [ -f "$REPORTING_HISTORY_FILE" ]; then
        local line_count=$(wc -l < "$REPORTING_HISTORY_FILE")
        if [ "$line_count" -gt "$REPORTING_MAX_HISTORY" ]; then
            local tail_lines=$(( REPORTING_MAX_HISTORY - 10 ))
            if [ "$tail_lines" -lt 1 ]; then
                tail_lines=1
            fi
            
            # Create temp file with most recent entries
            local temp_file="${REPORTING_STATE_DIR}/history.tmp.$$"
            tail -n "$tail_lines" "$REPORTING_HISTORY_FILE" > "$temp_file" && 
            mv "$temp_file" "$REPORTING_HISTORY_FILE"
        fi
    fi
    
    return 0
}

# Get status history from logs
# Usage: get_status_history [component] [limit]
# Arguments:
#   component - Optional component filter
#   limit - Optional limit of entries (default: all)
# Returns: Status history entries
get_status_history() {
    local component="$1"
    local limit="$2"
    
    # Check if history file exists
    if [ ! -f "$REPORTING_HISTORY_FILE" ]; then
        echo "No history available"
        return 0
    fi
    
    # Apply component filter if specified
    if [ -n "$component" ]; then
        local filtered=$(grep ":$component:" "$REPORTING_HISTORY_FILE" || echo "")
    else
        local filtered=$(cat "$REPORTING_HISTORY_FILE")
    fi
    
    # Apply limit if specified
    if [ -n "$limit" ] && [[ "$limit" =~ ^[0-9]+$ ]]; then
        echo "$filtered" | tail -n "$limit"
    else
        echo "$filtered"
    fi
    
    return 0
}

# Send status notification
# Usage: send_status_notification severity component message
# Arguments:
#   severity - Notification severity (info, warning, critical)
#   component - Component triggering notification
#   message - Notification message
# Returns: 0 on success, 1 on failure
send_status_notification() {
    local severity="$1"
    local component="$2"
    local message="$3"
    local timestamp=$(date +%s)
    
    # Validate severity
    local valid_severity=false
    for level in "${REPORTING_NOTIFICATION_LEVELS[@]}"; do
        if [ "$level" = "$severity" ]; then
            valid_severity=true
            break
        fi
    done
    
    if ! $valid_severity; then
        log "WARNING" "Invalid notification severity: $severity"
        severity="info"  # Default to info for invalid levels
    fi
    
    # Create notification entry
    local entry="$timestamp:$severity:$component:$message"
    
    # Write to notification file
    echo "$entry" >> "$REPORTING_NOTIFICATION_FILE" || {
        log "ERROR" "Failed to write to notification file"
        return 1
    }
    
    # Also output to standard output with appropriate formatting
    case "$severity" in
        "info")
            echo "[INFO] $component: $message"
            ;;
        "warning")
            echo "[WARNING] $component: $message"
            ;;
        "critical")
            echo "[CRITICAL] $component: $message"
            ;;
    esac
    
    return 0
}

# ==========================================
# Output functions
# ==========================================

# Print formatted status report
# Usage: print_status_report [format] [component_filter]
# Arguments:
#   format - Output format (text, json, keyvalue)
#   component_filter - Optional component filter
# Returns: 0 on success, 1 on failure
print_status_report() {
    local format="${1:-text}"
    local filter="$2"
    
    case "$format" in
        "text")
            format_status_text "$filter"
            ;;
        "json")
            format_status_json "$filter"
            ;;
        "keyvalue")
            format_status_keyvalue "$filter"
            ;;
        *)
            log "ERROR" "Invalid format: $format"
            echo "ERROR: Invalid format: $format (valid: text, json, keyvalue)"
            return 1
            ;;
    esac
    
    return $?
}

# Export necessary functions and variables
export -f init_monitoring_reporting
export -f get_status_summary
export -f get_component_summary
export -f format_status_text
export -f format_status_json
export -f format_status_keyvalue
export -f log_status_change
export -f get_status_history
export -f send_status_notification
export -f print_status_report

export REPORTING_STATE_DIR
export REPORTING_HISTORY_FILE
export REPORTING_NOTIFICATION_FILE
export REPORTING_MAX_HISTORY
export REPORTING_NOTIFICATION_LEVELS
