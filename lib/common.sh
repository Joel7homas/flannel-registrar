#!/bin/bash
# common.sh
# Core utility functions for flannel-registrar
# Provides logging, error handling, and common utilities

# Module information
MODULE_NAME="common"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=()  # No dependencies for this core module

# ==========================================
# Global variables with default values
# ==========================================

# Debug mode flag
DEBUG="${DEBUG:-false}"

# State directory for permanent storage
COMMON_STATE_DIR="${COMMON_STATE_DIR:-/var/run/flannel-registrar}"

# Initialize common module state
init_common() {
    # Create state directory if it doesn't exist
    mkdir -p "$COMMON_STATE_DIR" || {
        echo "ERROR: Failed to create state directory: $COMMON_STATE_DIR"
        return 1
    }
    
    # Initialize random seed
    RANDOM=$$$(date +%s)
    
    # Log module initialization
    log "INFO" "Initialized common module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Logging functions
# ==========================================

# Standard log function with level and message parameters
# Usage: log "INFO" "Your message here"
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    case $level in
        "DEBUG")
            # Only log DEBUG if debug mode is enabled
            if [ "$DEBUG" = "true" ]; then
                echo -e "[DEBUG] $timestamp - $message" >&2
            fi
            ;;
        "INFO")
            echo -e "[INFO] $timestamp - $message" >&2
            ;;
        "WARNING")
            echo -e "[WARNING] $timestamp - $message" >&2
            ;;
        "ERROR")
            echo -e "[ERROR] $timestamp - $message" >&2
            ;;
        "CRITICAL")
            echo -e "[CRITICAL] $timestamp - $message" >&2
            ;;
        *)
            echo "$timestamp - $message" >&2
            ;;
    esac
}

# Log a debug message (only if DEBUG=true)
# Usage: debug "Your debug message"
debug() {
    log "DEBUG" "$1"
}

# Log an error message and return an error code
# Usage: error "Your error message" [exit_code]
error() {
    local message="$1"
    local exit_code="${2:-1}"  # Default to exit code 1 if not specified
    
    log "ERROR" "$message"
    return $exit_code
}

# Log a critical error and exit the program
# Usage: fatal "Your fatal error message" [exit_code]
fatal() {
    local message="$1"
    local exit_code="${2:-1}"  # Default to exit code 1 if not specified
    
    log "CRITICAL" "$message"
    exit $exit_code
}

# ==========================================
# Array and associative array utilities
# ==========================================

# Check if an item exists in an array
# Usage: array_contains "item" "${array[@]}" && echo "Found!"
array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# Join array elements with a delimiter
# Usage: array_join "," "${array[@]}"
array_join() {
    local delimiter="$1"
    shift
    local result=""
    local first=true
    
    for item in "$@"; do
        if $first; then
            result="$item"
            first=false
        else
            result="${result}${delimiter}${item}"
        fi
    done
    
    echo "$result"
}

# Parse a key-value string with delimiter into an associative array
# Usage: parse_key_value_string "key1:value1,key2:value2" ":" "," "array_name"
parse_key_value_string() {
    local input_string="$1"
    local kv_delimiter="$2"
    local pair_delimiter="$3"
    local array_name="$4"
    
    # Exit if any required argument is missing
    if [ -z "$input_string" ] || [ -z "$kv_delimiter" ] || [ -z "$pair_delimiter" ] || [ -z "$array_name" ]; then
        error "parse_key_value_string requires all arguments"
        return 1
    fi
    
    # Split by pair delimiter
    IFS="$pair_delimiter" read -ra pairs <<< "$input_string"
    
    # Process each pair
    for pair in "${pairs[@]}"; do
        if [ -n "$pair" ]; then
            # Split by key-value delimiter
            IFS="$kv_delimiter" read -r key value <<< "$pair"
            
            if [ -n "$key" ] && [ -n "$value" ]; then
                # Use eval to assign to the named associative array
                eval "$array_name[\$key]=\$value"
            fi
        fi
    done
    
    return 0
}

# ==========================================
# String utility functions
# ==========================================

# Trim whitespace from beginning and end of a string
# Usage: trim_string "  string with spaces  "
trim_string() {
    local var="$*"
    # Remove leading whitespace
    var="${var#"${var%%[![:space:]]*}"}"
    # Remove trailing whitespace
    var="${var%"${var##*[![:space:]]}"}"
    echo "$var"
}

# Check if a string contains a substring
# Usage: string_contains "haystack" "needle" && echo "Found!"
string_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]]
    return $?
}

# Generate a random alphanumeric string of specified length
# Usage: random_string 10
random_string() {
    local length="${1:-8}"
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local result=""
    
    for ((i=0; i<length; i++)); do
        local rand_index=$((RANDOM % ${#chars}))
        result+="${chars:rand_index:1}"
    done
    
    echo "$result"
}

# ==========================================
# File and state management utilities
# ==========================================

# Write key-value data to state file
# Usage: write_state "key" "value" ["filename"]
write_state() {
    local key="$1"
    local value="$2"
    local filename="${3:-state.env}"
    local state_file="${COMMON_STATE_DIR}/${filename}"
    
    # Create temporary file
    local temp_file=$(mktemp)
    
    # Read existing state except the line with our key
    if [ -f "$state_file" ]; then
        grep -v "^${key}=" "$state_file" > "$temp_file" || true
    fi
    
    # Append our key-value pair
    echo "${key}=${value}" >> "$temp_file"
    
    # Replace the original file
    mv "$temp_file" "$state_file"
    
    return $?
}

# Read key-value data from state file
# Usage: read_state "key" ["filename"]
read_state() {
    local key="$1"
    local filename="${2:-state.env}"
    local state_file="${COMMON_STATE_DIR}/${filename}"
    
    if [ ! -f "$state_file" ]; then
        return 1
    fi
    
    local value=$(grep "^${key}=" "$state_file" | cut -d'=' -f2-)
    
    if [ -z "$value" ]; then
        return 1
    fi
    
    echo "$value"
    return 0
}

# Ensure a command exists
# Usage: ensure_command "docker" "Please install Docker to continue"
ensure_command() {
    local cmd="$1"
    local message="${2:-Command $cmd is required but not installed}"
    
    if ! command -v "$cmd" &>/dev/null; then
        error "$message"
        return 1
    fi
    
    return 0
}

# ==========================================
# Network utility functions
# ==========================================

# Check if an IP address is valid
# Usage: is_valid_ip "192.168.1.1" && echo "Valid!"
is_valid_ip() {
    local ip="$1"
    
    # Simple pattern matching for IPv4
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Check each octet
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [[ "$octet" -lt 0 || "$octet" -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    
    return 1
}

# Check if a CIDR subnet is valid
# Usage: is_valid_cidr "192.168.1.0/24" && echo "Valid!"
is_valid_cidr() {
    local cidr="$1"
    
    # Split into IP and prefix
    IFS='/' read -r ip prefix <<< "$cidr"
    
    # Check IP validity
    if ! is_valid_ip "$ip"; then
        return 1
    fi
    
    # Check prefix validity
    if [[ -z "$prefix" || "$prefix" -lt 0 || "$prefix" -gt 32 ]]; then
        return 1
    fi
    
    return 0
}

# Get current timestamp in seconds
# Usage: timestamp=$(get_timestamp)
get_timestamp() {
    date +%s
}

# Calculate time elapsed since a timestamp
# Usage: elapsed=$(time_since "$start_time")
time_since() {
    local start_time="$1"
    local current_time=$(get_timestamp)
    echo $((current_time - start_time))
}

# ==========================================
# Version checking functions
# ==========================================

# Compare version strings (major.minor.patch)
# Returns 0 if v1 >= v2, 1 if v1 < v2
# Usage: version_ge "1.2.3" "1.2.0" && echo "Version is greater or equal"
version_ge() {
    local v1="$1"
    local v2="$2"
    
    # If versions are identical, return success
    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi
    
    # Split versions into components
    IFS='.' read -r -a v1_parts <<< "$v1"
    IFS='.' read -r -a v2_parts <<< "$v2"
    
    # Compare major version
    if [[ "${v1_parts[0]}" -gt "${v2_parts[0]}" ]]; then
        return 0
    elif [[ "${v1_parts[0]}" -lt "${v2_parts[0]}" ]]; then
        return 1
    fi
    
    # Compare minor version
    if [[ "${v1_parts[1]:-0}" -gt "${v2_parts[1]:-0}" ]]; then
        return 0
    elif [[ "${v1_parts[1]:-0}" -lt "${v2_parts[1]:-0}" ]]; then
        return 1
    fi
    
    # Compare patch version
    if [[ "${v1_parts[2]:-0}" -ge "${v2_parts[2]:-0}" ]]; then
        return 0
    else
        return 1
    fi
}

# Export necessary functions and variables
export -f log debug error fatal
export -f array_contains array_join parse_key_value_string
export -f trim_string string_contains random_string
export -f write_state read_state ensure_command
export -f is_valid_ip is_valid_cidr get_timestamp time_since
export -f version_ge
export COMMON_STATE_DIR
