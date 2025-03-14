#!/bin/bash
# etcd-lib.sh
# ETCD operations library for flannel-registrar
# Provides CRUD operations for etcd v2 and v3 APIs with error handling

# Module information
MODULE_NAME="etcd-lib"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common")

# ==========================================
# Global variables with default values
# ==========================================

# ETCD endpoint URL
ETCD_ENDPOINT="${ETCD_ENDPOINT:-http://127.0.0.1:2379}"

# ETCD API version
ETCDCTL_API="${ETCDCTL_API:-3}"

# ETCD state directory
ETCD_STATE_DIR="${COMMON_STATE_DIR}/etcd"

# ETCD operation timeout (seconds)
ETCD_TIMEOUT="${ETCD_TIMEOUT:-5}"

# ETCD operation retry count
ETCD_RETRY_COUNT="${ETCD_RETRY_COUNT:-3}"

# ETCD operation retry delay (seconds)
ETCD_RETRY_DELAY="${ETCD_RETRY_DELAY:-2}"

# Initialize etcd-lib module
init_etcd_lib() {
    # Check dependencies
    if ! type log &>/dev/null; then
        echo "ERROR: Required module 'common' is not loaded"
        return 1
    fi
    
    # Create state directory
    mkdir -p "$ETCD_STATE_DIR" || {
        log "ERROR" "Failed to create etcd state directory: $ETCD_STATE_DIR"
        return 1
    }
    
    # Verify etcd connectivity
    if ! _etcd_check_connectivity; then
        log "WARNING" "Cannot connect to etcd at $ETCD_ENDPOINT"
        return 1
    fi
    
    # Log module initialization
    log "INFO" "Initialized etcd-lib module (v${MODULE_VERSION})"
    log "INFO" "Using etcd endpoint: $ETCD_ENDPOINT (API v$ETCDCTL_API)"
    
    return 0
}

# ==========================================
# Private helper functions
# ==========================================

# Check connectivity to etcd
# Returns 0 if successful, 1 otherwise
_etcd_check_connectivity() {
    log "DEBUG" "Checking connectivity to etcd at $ETCD_ENDPOINT"
    
    if [[ "$ETCDCTL_API" == "3" ]]; then
        # Check etcd v3 health
        local response=$(curl -s -m "$ETCD_TIMEOUT" "${ETCD_ENDPOINT}/health" 2>&1)
        if echo "$response" | grep -q "true"; then
            log "DEBUG" "Successfully connected to etcd v3"
            return 0
        fi
    else
        # Check etcd v2 health
        local response=$(curl -s -m "$ETCD_TIMEOUT" "${ETCD_ENDPOINT}/health" 2>&1)
        if echo "$response" | grep -q "true"; then
            log "DEBUG" "Successfully connected to etcd v2"
            return 0
        fi
    fi
    
    log "ERROR" "Failed to connect to etcd at $ETCD_ENDPOINT"
    return 1
}

# Encode a string to base64
# Usage: encoded=$(_etcd_base64_encode "string")
_etcd_base64_encode() {
    echo -n "$1" | base64 -w 0
}

# Decode a base64 string
# Usage: decoded=$(_etcd_base64_decode "base64string")
_etcd_base64_decode() {
    echo -n "$1" | base64 -d
}

# Retry a function with backoff
# Usage: _etcd_retry function_name [arg1 arg2 ...]
_etcd_retry() {
    local func="$1"
    shift
    
    local retry_count=0
    local result=1
    
    while [ $retry_count -lt $ETCD_RETRY_COUNT ]; do
        if "$func" "$@"; then
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        
        if [ $retry_count -lt $ETCD_RETRY_COUNT ]; then
            log "DEBUG" "Retrying $func (attempt $retry_count/$ETCD_RETRY_COUNT) in ${ETCD_RETRY_DELAY}s..."
            sleep "$ETCD_RETRY_DELAY"
        fi
    done
    
    log "ERROR" "Function $func failed after $ETCD_RETRY_COUNT attempts"
    return 1
}

# ==========================================
# ETCD CRUD operations - v3 API
# ==========================================

# Put a key-value pair in etcd v3
# Usage: _etcd_v3_put "/key" "value"
_etcd_v3_put() {
    local key="$1"
    local value="$2"
    
    local base64_key=$(_etcd_base64_encode "$key")
    local base64_value=$(_etcd_base64_encode "$value")
    
    # Create JSON payload
    local payload="{\"key\":\"$base64_key\",\"value\":\"$base64_value\"}"
    
    log "DEBUG" "Sending etcd v3 PUT: $key (value length: ${#value})"
    
    # Send request to etcd
    local response=$(curl -s -X POST -m "$ETCD_TIMEOUT" \
        "${ETCD_ENDPOINT}/v3/kv/put" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)
    
    # Check response
    if echo "$response" | grep -q "header"; then
        log "DEBUG" "etcd v3 PUT successful: $key"
        return 0
    else
        log "ERROR" "etcd v3 PUT failed: $key - ${response:0:200}"
        return 1
    fi
}

# Get a value from etcd v3
# Usage: value=$(_etcd_v3_get "/key")
_etcd_v3_get() {
    local key="$1"
    
    local base64_key=$(_etcd_base64_encode "$key")
    
    # Create JSON payload
    local payload="{\"key\":\"$base64_key\"}"
    
    log "DEBUG" "Sending etcd v3 GET: $key"
    
    # Send request to etcd
    local response=$(curl -s -X POST -m "$ETCD_TIMEOUT" \
        "${ETCD_ENDPOINT}/v3/kv/range" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)
    
    # Check response
    if echo "$response" | grep -q "\"kvs\""; then
        # Extract the value (base64 encoded)
        # Use grep/cut for compatibility with systems without jq
        local base64_value
        if command -v jq &>/dev/null; then
            base64_value=$(echo "$response" | jq -r '.kvs[0].value')
        else
            base64_value=$(echo "$response" | grep -o '"value":"[^"]*"' | head -1 | cut -d'"' -f4)
        fi
        
        # Decode and return the value
        if [ -n "$base64_value" ]; then
            _etcd_base64_decode "$base64_value"
            return 0
        fi
    fi
    
    log "DEBUG" "etcd v3 GET failed or key not found: $key"
    return 1
}

# Delete a key from etcd v3
# Usage: _etcd_v3_delete "/key"
_etcd_v3_delete() {
    local key="$1"
    
    local base64_key=$(_etcd_base64_encode "$key")
    
    # Create JSON payload
    local payload="{\"key\":\"$base64_key\"}"
    
    log "DEBUG" "Sending etcd v3 DELETE: $key"
    
    # Send request to etcd
    local response=$(curl -s -X POST -m "$ETCD_TIMEOUT" \
        "${ETCD_ENDPOINT}/v3/kv/deleterange" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)
    
    # Check response
    if echo "$response" | grep -q "header"; then
        log "DEBUG" "etcd v3 DELETE successful: $key"
        return 0
    else
        log "ERROR" "etcd v3 DELETE failed: $key - ${response:0:200}"
        return 1
    fi
}

# List keys with a prefix from etcd v3
# Usage: keys=$(_etcd_v3_list_keys "/prefix")
# Enhanced _etcd_v3_list_keys function with better key handling
_etcd_v3_list_keys() {
    local prefix="$1"

    local base64_prefix=$(_etcd_base64_encode "$prefix")
    local base64_end=$(_etcd_base64_encode "${prefix}\xff")

    # Create JSON payload
    local payload="{\"key\":\"$base64_prefix\",\"range_end\":\"$base64_end\",\"keys_only\":true}"

    log "DEBUG" "Sending etcd v3 LIST KEYS: $prefix"

    # Send request to etcd
    local response=$(curl -s -X POST -m "$ETCD_TIMEOUT" \
        "${ETCD_ENDPOINT}/v3/kv/range" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)

    # Check response
    if echo "$response" | grep -q "\"kvs\""; then
        # Extract and decode the keys with proper newline handling
        if command -v jq &>/dev/null; then
            # Use jq if available for more reliable parsing
            echo "$response" | jq -r '.kvs[].key' | while read -r base64_key; do
                if [ -n "$base64_key" ]; then
                    decoded_key=$(_etcd_base64_decode "$base64_key")
                    echo "$decoded_key"  # Each key on its own line
                fi
            done
        else
            # Fall back to grep/sed but ensure each key is on its own line
            echo "$response" | grep -o '"key":"[^"]*"' | cut -d'"' -f4 | while read -r base64_key; do
                if [ -n "$base64_key" ]; then
                    decoded_key=$(_etcd_base64_decode "$base64_key")
                    echo "$decoded_key"  # Each key on its own line
                fi
            done
        fi
        return 0
    else
        log "DEBUG" "etcd v3 LIST KEYS failed or no keys found: $prefix"
        return 1
    fi
}

# ==========================================
# ETCD CRUD operations - v2 API
# ==========================================

# Put a key-value pair in etcd v2
# Usage: _etcd_v2_put "/key" "value" [is_dir]
_etcd_v2_put() {
    local key="$1"
    local value="$2"
    local is_dir="${3:-false}"
    
    local endpoint="${ETCD_ENDPOINT}/v2/keys${key}"
    local params="value=$value"
    
    if [[ "$is_dir" == "true" ]]; then
        endpoint="${endpoint}?dir=true"
    fi
    
    log "DEBUG" "Sending etcd v2 PUT: $key (value length: ${#value})"
    
    # Send request to etcd
    local response=$(curl -s -X PUT -m "$ETCD_TIMEOUT" "$endpoint" -d "$params" 2>&1)
    
    # Check response
    if echo "$response" | grep -q "\"action\":\"set\""; then
        log "DEBUG" "etcd v2 PUT successful: $key"
        return 0
    else
        log "ERROR" "etcd v2 PUT failed: $key - ${response:0:200}"
        return 1
    fi
}

# Get a value from etcd v2
# Usage: value=$(_etcd_v2_get "/key")
_etcd_v2_get() {
    local key="$1"
    
    local endpoint="${ETCD_ENDPOINT}/v2/keys${key}"
    
    log "DEBUG" "Sending etcd v2 GET: $key"
    
    # Send request to etcd
    local response=$(curl -s -m "$ETCD_TIMEOUT" "$endpoint" 2>&1)
    
    # Check response
    if echo "$response" | grep -q "\"action\":\"get\""; then
        # Extract the value
        if command -v jq &>/dev/null; then
            echo "$response" | jq -r '.node.value'
        else
            echo "$response" | grep -o '"value":"[^"]*"' | cut -d'"' -f4
        fi
        return 0
    else
        log "DEBUG" "etcd v2 GET failed or key not found: $key"
        return 1
    fi
}

# Delete a key from etcd v2
# Usage: _etcd_v2_delete "/key"
_etcd_v2_delete() {
    local key="$1"
    
    local endpoint="${ETCD_ENDPOINT}/v2/keys${key}"
    
    log "DEBUG" "Sending etcd v2 DELETE: $key"
    
    # Send request to etcd
    local response=$(curl -s -X DELETE -m "$ETCD_TIMEOUT" "$endpoint" 2>&1)
    
    # Check response
    if echo "$response" | grep -q "\"action\":\"delete\""; then
        log "DEBUG" "etcd v2 DELETE successful: $key"
        return 0
    else
        log "ERROR" "etcd v2 DELETE failed: $key - ${response:0:200}"
        return 1
    fi
}

# List keys with a prefix from etcd v2
# Usage: keys=$(_etcd_v2_list_keys "/prefix")
_etcd_v2_list_keys() {
    local prefix="$1"
    
    local endpoint="${ETCD_ENDPOINT}/v2/keys${prefix}?recursive=true"
    
    log "DEBUG" "Sending etcd v2 LIST KEYS: $prefix"
    
    # Send request to etcd
    local response=$(curl -s -m "$ETCD_TIMEOUT" "$endpoint" 2>&1)
    
    # Check response
    if echo "$response" | grep -q "\"action\":\"get\""; then
        # Extract the keys
        if command -v jq &>/dev/null; then
            echo "$response" | jq -r '.node.nodes[].key'
        else
            echo "$response" | grep -o '"key":"[^"]*"' | cut -d'"' -f4
        fi
        return 0
    else
        log "DEBUG" "etcd v2 LIST KEYS failed or no keys found: $prefix"
        return 1
    fi
}

# ==========================================
# Public API functions - version-agnostic
# ==========================================

# Put a key-value pair in etcd (version agnostic)
# Usage: etcd_put "/key" "value" [is_dir]
etcd_put() {
    local key="$1"
    local value="$2"
    local is_dir="${3:-false}"
    
    if [[ "$ETCDCTL_API" == "3" ]]; then
        _etcd_retry _etcd_v3_put "$key" "$value"
    else
        _etcd_retry _etcd_v2_put "$key" "$value" "$is_dir"
    fi
    
    return $?
}

# Get a value from etcd (version agnostic)
# Usage: value=$(etcd_get "/key")
etcd_get() {
    local key="$1"
    
    if [[ "$ETCDCTL_API" == "3" ]]; then
        _etcd_v3_get "$key"
    else
        _etcd_v2_get "$key"
    fi
    
    return $?
}

# Delete a key from etcd (version agnostic)
# Usage: etcd_delete "/key"
etcd_delete() {
    local key="$1"
    
    if [[ "$ETCDCTL_API" == "3" ]]; then
        _etcd_retry _etcd_v3_delete "$key"
    else
        _etcd_retry _etcd_v2_delete "$key"
    fi
    
    return $?
}

# List keys with a prefix from etcd (version agnostic)
# Usage: keys=$(etcd_list_keys "/prefix")
etcd_list_keys() {
    local prefix="$1"
    
    if [[ "$ETCDCTL_API" == "3" ]]; then
        _etcd_v3_list_keys "$prefix"
    else
        _etcd_v2_list_keys "$prefix"
    fi
    
    return $?
}

# Check if a key exists in etcd
# Usage: etcd_key_exists "/key" && echo "Key exists!"
etcd_key_exists() {
    local key="$1"
    
    if [[ "$ETCDCTL_API" == "3" ]]; then
        _etcd_v3_get "$key" &>/dev/null
    else
        _etcd_v2_get "$key" &>/dev/null
    fi
    
    return $?
}

# Initialize etcd structure
# Creates necessary directories and default config
# Usage: initialize_etcd
initialize_etcd() {
    log "INFO" "Initializing etcd structure for Flannel..."
    
    # Verify etcd is running and accessible
    if ! _etcd_check_connectivity; then
        log "ERROR" "Cannot connect to etcd at ${ETCD_ENDPOINT}"
        log "ERROR" "Please verify etcd is running and accessible"
        return 1
    fi
    
    log "INFO" "Successfully connected to etcd at ${ETCD_ENDPOINT}"
    
    # Clean up any malformed entries from previous runs
    if [[ "$ETCDCTL_API" == "3" ]]; then
        log "INFO" "Checking for and cleaning up malformed entries..."
        
        # Find any keys containing timestamps or other obvious malformed patterns
        local malformed_key_base64=$(_etcd_base64_encode "${FLANNEL_CONFIG_PREFIX}/[")
        local range_end_base64=$(_etcd_base64_encode "${FLANNEL_CONFIG_PREFIX}/\\")
        local payload="{\"key\":\"$malformed_key_base64\",\"range_end\":\"$range_end_base64\",\"keys_only\":true}"
        
        local response=$(curl -s -X POST -m "$ETCD_TIMEOUT" \
            "${ETCD_ENDPOINT}/v3/kv/range" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)
        
        local malformed_keys=""
        if echo "$response" | grep -q "\"kvs\""; then
            malformed_keys=$(echo "$response" | grep -o '"key":"[^"]*"' | cut -d'"' -f4)
        fi
        
        if [[ -n "$malformed_keys" ]]; then
            for encoded_key in $malformed_keys; do
                local decoded_key=$(_etcd_base64_decode "$encoded_key" 2>/dev/null)
                if [[ -n "$decoded_key" && "$decoded_key" == *"["* ]]; then
                    log "INFO" "Found malformed key: $decoded_key - removing"
                    local del_payload="{\"key\":\"$encoded_key\"}"
                    curl -s -X POST -m "$ETCD_TIMEOUT" \
                        "${ETCD_ENDPOINT}/v3/kv/deleterange" \
                        -H "Content-Type: application/json" \
                        -d "$del_payload" > /dev/null
                fi
            done
        fi
    fi
    
    # Create flannel network config marker
    etcd_put "${FLANNEL_CONFIG_PREFIX}/_exists" "true" || log "WARNING" "Failed to initialize ${FLANNEL_CONFIG_PREFIX}"
    
    # Ensure the standard Flannel network prefix exists
    if ! etcd_key_exists "${FLANNEL_PREFIX}/config"; then
        log "WARNING" "Flannel config not found. Creating default config..."
        # Default Flannel config
        local flannel_config='{"Network":"10.5.0.0/16", "SubnetLen":24, "Backend":{"Type":"vxlan"}}'
        etcd_put "${FLANNEL_PREFIX}/config" "$flannel_config" || log "WARNING" "Failed to create default Flannel config"
    fi
    
    log "INFO" "Etcd initialization completed"
    return 0
}

# Clean up localhost IP entries in etcd
# These entries can cause routing problems
# Usage: cleanup_localhost_entries
cleanup_localhost_entries() {
    log "INFO" "Checking for etcd entries with localhost IPs..."
    
    # First check if we can connect to etcd at all
    if ! _etcd_check_connectivity; then
        log "WARNING" "Cannot connect to etcd at $ETCD_ENDPOINT during cleanup_localhost_entries"
        log "WARNING" "This may be due to the network connectivity issues that flannel-registrar is designed to fix"
        log "WARNING" "Will continue startup process and retry later during normal operation"
        return 0  # Return success to allow the process to continue
    fi
    
    log "DEBUG" "Etcd connectivity verified, proceeding with cleanup"
    
    # Get all subnet entries
    log "DEBUG" "Attempting to list subnet keys from ${FLANNEL_PREFIX}/subnets/"
    local subnet_keys=""
    
    # Try to get subnet keys with error handling
    set +e  # Disable exit on error temporarily
    subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    local list_result=$?
    set -e  # Re-enable exit on error
    
    # Check if the key listing failed
    if [[ $list_result -ne 0 ]]; then
        log "WARNING" "Failed to list subnet keys from ${FLANNEL_PREFIX}/subnets/"
        log "WARNING" "Skipping localhost cleanup for now, will retry during normal operation"
        return 0  # Return success to allow the process to continue
    fi
    
    # Check if we got any keys back
    if [[ -z "$subnet_keys" ]]; then
        log "INFO" "No subnet entries found in ${FLANNEL_PREFIX}/subnets/ - this may be normal for a fresh installation"
        return 0
    fi
    
    log "DEBUG" "Found $(echo "$subnet_keys" | wc -l) subnet keys to check"
    
    local cleaned_count=0
    local error_count=0
    
    # Process each subnet key with careful error handling
    while read -r key; do
        # Skip empty lines
        [ -z "$key" ] && continue
        
        log "DEBUG" "Checking subnet key: $key"
        
        # Get the subnet value (JSON data) with error handling
        local subnet_data=""
        set +e  # Disable exit on error temporarily
        subnet_data=$(etcd_get "$key")
        local get_result=$?
        set -e  # Re-enable exit on error
        
        # Check if the get operation failed
        if [[ $get_result -ne 0 ]]; then
            log "WARNING" "Failed to get data for key $key"
            error_count=$((error_count + 1))
            continue
        fi
        
        # Skip if no data
        if [[ -z "$subnet_data" ]]; then
            log "DEBUG" "No data found for key $key, skipping"
            continue
        fi
        
        # Check if the data contains "PublicIP":"127.0.0.1"
        if [[ "$subnet_data" == *"\"PublicIP\":\"127.0.0.1\""* ]]; then
            log "INFO" "Found localhost IP entry: $key"
            
            # Extract subnet from key
            local subnet_id=$(basename "$key")
            log "DEBUG" "Extracted subnet ID: $subnet_id"
            
            # Delete the key with error handling
            set +e  # Disable exit on error temporarily
            if etcd_delete "$key"; then
                log "INFO" "Successfully deleted localhost entry: $key"
                cleaned_count=$((cleaned_count + 1))
            else
                log "WARNING" "Failed to delete localhost entry: $key"
                error_count=$((error_count + 1))
            fi
            set -e  # Re-enable exit on error
        else 
            log "DEBUG" "Key $key does not contain localhost IP, skipping"
        fi
    done <<< "$subnet_keys"
    
    if [[ $cleaned_count -gt 0 ]]; then
        log "INFO" "Cleaned up $cleaned_count entries with localhost IPs"
    else 
        log "INFO" "No localhost IP entries found"
    fi
    
    if [[ $error_count -gt 0 ]]; then
        log "WARNING" "Encountered $error_count errors during localhost cleanup"
        # Still return 0 to allow the process to continue
    fi
    
    return 0
}

# Export necessary functions and variables
export -f etcd_put etcd_get etcd_delete etcd_list_keys
export -f etcd_key_exists initialize_etcd cleanup_localhost_entries
export ETCD_ENDPOINT ETCDCTL_API ETCD_STATE_DIR
export ETCD_TIMEOUT ETCD_RETRY_COUNT ETCD_RETRY_DELAY
