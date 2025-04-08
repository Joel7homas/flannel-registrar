#!/bin/bash
# routes-core.sh
# Core functions for managing network routes for Flannel
# Part of flannel-registrar's modular network management system

# Module information
MODULE_NAME="routes-core"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "network-lib")

# ==========================================
# Global variables for route management
# ==========================================

# Last update time for routes
ROUTES_LAST_UPDATE_TIME=0

# Update interval for routes (seconds)
ROUTES_UPDATE_INTERVAL=${ROUTES_UPDATE_INTERVAL:-120}  # Default 2 minutes

# State directory for routes
ROUTES_STATE_DIR="${COMMON_STATE_DIR}/routes"

# Backup file for routes
ROUTES_BACKUP_FILE="${ROUTES_STATE_DIR}/routes_backup.json"

# Extra routes from environment variable
FLANNEL_ROUTES_EXTRA="${FLANNEL_ROUTES_EXTRA:-}"  # Format: "subnet:gateway:interface,subnet:gateway:interface"

# Whether to manage flannel routes (10.5.x.x or configured FLANNEL_NETWORK)
MANAGE_FLANNEL_ROUTES="${MANAGE_FLANNEL_ROUTES:-false}"

# Flannel network prefix to identify flannel routes (default: 10.5)
FLANNEL_NETWORK_PREFIX="${FLANNEL_NETWORK_PREFIX:-10.5}"

# Whether to detect Docker networks managed by flannel (172.x.x.x)
DETECT_FLANNEL_DOCKER_NETWORKS="${DETECT_FLANNEL_DOCKER_NETWORKS:-true}"

# Additional network prefixes to consider as flannel-managed (comma-separated)
FLANNEL_ADDITIONAL_PREFIXES="${FLANNEL_ADDITIONAL_PREFIXES:-172.}"

# ==========================================
# Initialization function
# ==========================================

# Initialize route management
init_routes_core() {
    # Check dependencies
    for dep in log etcd_get etcd_list_keys parse_host_gateway_map; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found. Make sure all dependencies are loaded."
            return 1
        fi
    done
    
    # Create state directory
    mkdir -p "$ROUTES_STATE_DIR" || {
        log "ERROR" "Failed to create routes state directory: $ROUTES_STATE_DIR"
        return 1
    }
    
    # Restore routes from backup if available and recent
    if [ -f "$ROUTES_BACKUP_FILE" ]; then
        local backup_age=$(($(date +%s) - $(stat -c %Y "$ROUTES_BACKUP_FILE")))
        
        if [ $backup_age -lt 3600 ]; then  # Backup less than 1 hour old
            log "INFO" "Found recent routes backup (age: $backup_age seconds), restoring"
            restore_routes_from_backup
        else
            log "INFO" "Found outdated routes backup (age: $backup_age seconds), ignoring"
        fi
    fi
    
    # Parse extra routes from environment variable
    parse_extra_routes

    if [ "$MANAGE_FLANNEL_ROUTES" = "true" ]; then
        log "INFO" "Initialized routes-core module (v${MODULE_VERSION}) - Managing flannel routes ENABLED"
    else
        log "INFO" "Initialized routes-core module (v${MODULE_VERSION}) - Managing flannel routes DISABLED"
        log "INFO" "Flannel routes (${FLANNEL_NETWORK_PREFIX}.* and onlink routes) will be monitored but NOT modified"
        if [ "$DETECT_FLANNEL_DOCKER_NETWORKS" = "true" ]; then
            log "INFO" "Docker networks with onlink attribute will also be considered flannel-managed"
        fi
    fi
    
    # Log inventory of detected flannel routes
    log_flannel_route_inventory

    # Log initialization
    log "INFO" "Initialized routes-core module (v${MODULE_VERSION})"
    
    return 0
}

# ==========================================
# Utility functions for route management
# ==========================================

# Validate IP address format
is_valid_route_ip() {
    local ip="$1"
    if [ -z "$ip" ]; then
        return 1
    fi
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    return 0
}

# Validate CIDR notation
is_valid_route_cidr() {
    local cidr="$1"
    if [ -z "$cidr" ]; then
        return 1
    fi
    [[ $cidr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || return 1
    return 0
}

# Validate network interface
is_valid_route_interface() {
    local interface="$1"
    if [ -z "$interface" ]; then
        return 1
    fi
    ip link show dev "$interface" &>/dev/null || return 1
    return 0
}

# Improve the validation in ensure_flannel_routes() or similar functions
validate_subnet() {
    local subnet="$1"
    
    # Skip anything that looks like a date (YYYY/MM/DD format)
    if [[ "$subnet" =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]]; then
        log "DEBUG" "Skipping date-like subnet: $subnet" 
        return 1
    fi

    # Skip anything that looks like a date (YYYY-MM-DD format)
    if [[ "$subnet" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        log "DEBUG" "Skipping date-like subnet: $subnet" 
        return 1
    fi
    
    # Ensure subnet is in CIDR format (IP/mask)
    if ! [[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        log "WARNING" "Invalid subnet format: $subnet" 
        return 1
    fi
    
    # Validate IP portion
    local ip=$(echo "$subnet" | cut -d'/' -f1)
    local octets=(${ip//./ })
    if [ ${#octets[@]} -ne 4 ]; then
        log "WARNING" "Invalid IP in subnet: $subnet" 
        return 1
    fi
    
    for octet in "${octets[@]}"; do
        if ! [[ "$octet" =~ ^[0-9]+$ ]] || [ "$octet" -gt 255 ]; then
            log "WARNING" "Invalid octet in subnet IP: $subnet" 
            return 1
        fi
    done
    
    # Validate mask portion
    local mask=$(echo "$subnet" | cut -d'/' -f2)
    if ! [[ "$mask" =~ ^[0-9]+$ ]] || [ "$mask" -lt 1 ] || [ "$mask" -gt 32 ]; then
        log "WARNING" "Invalid mask in subnet: $subnet" 
        return 1
    fi
    
    return 0
}

# function to troubleshoot etcd data retrieval
debug_etcd_subnet_data() {
    local subnet_key="$1"
    log "DEBUG" "Debugging subnet data for: $subnet_key" 
    
    # Get the data with error handling
    local subnet_data=""
    set +e
    subnet_data=$(etcd_get "$subnet_key")
    local get_result=$?
    set -e
    
    if [ $get_result -ne 0 ]; then
        log "WARNING" "Failed to get data for key: $subnet_key" 
        return 1
    fi
    
    # Validate the data format
    if [ -z "$subnet_data" ]; then
        log "WARNING" "Empty data for key: $subnet_key" 
        return 1
    fi
    
    # Check if it's valid JSON
    if command -v jq &>/dev/null; then
        if ! echo "$subnet_data" | jq . >/dev/null 2>&1; then
            log "WARNING" "Invalid JSON for key: $subnet_key" 
            # Print first 100 chars of data for debugging
            log "DEBUG" "Data (first 100 chars): ${subnet_data:0:100}" 
            return 1
        fi
        
        # Extract PublicIP with debugging
        local public_ip=$(echo "$subnet_data" | jq -r '.PublicIP' 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$public_ip" ] || [ "$public_ip" = "null" ]; then
            log "WARNING" "No PublicIP in data for key: $subnet_key" 
            log "DEBUG" "JSON data: $subnet_data" 
            return 1
        fi
        
        log "DEBUG" "Successfully extracted PublicIP: $public_ip for key: $subnet_key" 
    else
        # Fallback to grep/sed
        local public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
        if [ -z "$public_ip" ]; then
            log "WARNING" "No PublicIP in data for key: $subnet_key" 
            return 1
        fi
        
        log "DEBUG" "Extracted PublicIP using grep: $public_ip for key: $subnet_key" 
    fi
    
    return 0
}

# Safe JSON parsing function
safe_jq_parse() {
    local json_data="$1"
    local jq_filter="$2"
    local default_value="${3:-}"
    
    if [ -z "$json_data" ]; then
        echo "$default_value"
        return 1
    fi
    
    # Validate JSON before passing to jq
    if ! echo "$json_data" | grep -q "^{" && ! echo "$json_data" | grep -q "^\["; then
        log "DEBUG" "Invalid JSON format detected" 
        echo "$default_value"
        return 1
    fi
    
    # Try to parse with jq
    local result
    result=$(echo "$json_data" | jq -r "$jq_filter" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$result" ] || [ "$result" = "null" ]; then
        echo "$default_value"
        return 1
    fi
    
    echo "$result"
    return 0
}

# Log inventory of detected flannel routes
log_flannel_route_inventory() {
    log "INFO" "Generating flannel route inventory"
    
    # Check for onlink routes
    local onlink_routes=$(ip route show | grep "onlink" | grep "flannel.1")
    local onlink_count=$(echo "$onlink_routes" | grep -v "^$" | wc -l)
    
    # Check for prefix routes
    local prefix_routes=$(ip route show | grep "^${FLANNEL_NETWORK_PREFIX}\.")
    local prefix_count=$(echo "$prefix_routes" | grep -v "^$" | wc -l)
    
    log "INFO" "Detected $onlink_count flannel routes with onlink attribute"
    log "INFO" "Detected $prefix_count routes with flannel prefix ${FLANNEL_NETWORK_PREFIX}"
    
    if [ "$DEBUG" = "true" ]; then
        if [ -n "$onlink_routes" ]; then
            log "DEBUG" "Flannel onlink routes:"
            echo "$onlink_routes" | while read -r route; do
                log "DEBUG" "  $route"
            done
        fi
        
        if [ -n "$prefix_routes" ]; then
            log "DEBUG" "Flannel prefix routes:"
            echo "$prefix_routes" | while read -r route; do
                log "DEBUG" "  $route"
            done
        fi
    fi
}

# ==========================================
# Route backup and restore functions
# ==========================================

# Backup current routes
# Usage: backup_routes
backup_routes() {
    log "DEBUG" "Backing up current routes"
    
    # Get current routes for flannel subnets
    local routes=$(ip route show | grep -E '10\.[0-9]+\.')
    
    if [ -z "$routes" ]; then
        log "WARNING" "No flannel routes found to backup"
        echo "[]" > "$ROUTES_BACKUP_FILE"
        return 0
    fi
    
    # Convert to JSON for easier parsing later
    local routes_json="["
    local first=true
    
    while read -r route; do
        if [ -z "$route" ]; then
            continue
        fi
        
        # Extract subnet, gateway, and interface
        local subnet=$(echo "$route" | awk '{print $1}')
        local via=$(echo "$route" | grep -o 'via [^ ]*' | cut -d' ' -f2 || echo "")
        local dev=$(echo "$route" | grep -o 'dev [^ ]*' | cut -d' ' -f2 || echo "")
        
        if ! $first; then
            routes_json+=","
        fi
        first=false
        
        routes_json+="{\"subnet\":\"$subnet\",\"via\":\"$via\",\"dev\":\"$dev\"}"
    done <<< "$routes"
    
    routes_json+="]"
    
    # Save to file
    echo "$routes_json" > "$ROUTES_BACKUP_FILE"
    log "DEBUG" "Backed up $(echo "$routes_json" | grep -o "subnet" | wc -l) routes"
    
    return 0
}

# Restore routes from backup
# Usage: restore_routes_from_backup
restore_routes_from_backup() {
    if [ ! -f "$ROUTES_BACKUP_FILE" ]; then
        log "WARNING" "No routes backup file found"
        return 1
    fi
    
    log "INFO" "Restoring routes from backup"
    
    local entries=0
    local successes=0
    
    # Read the JSON backup
    if command -v jq &>/dev/null; then

        # Skip flannel routes if not managing them
        if is_flannel_route "$subnet" && [ "$MANAGE_FLANNEL_ROUTES" != "true" ]; then
            log "DEBUG" "Skipping flannel route during restore: $subnet"
            continue
        fi
        # Parse JSON with jq
        local count=$(jq length "$ROUTES_BACKUP_FILE")
        
        for ((i=0; i<count; i++)); do
            local subnet=$(jq -r ".[$i].subnet" "$ROUTES_BACKUP_FILE")
            local via=$(jq -r ".[$i].via" "$ROUTES_BACKUP_FILE")
            local dev=$(jq -r ".[$i].dev" "$ROUTES_BACKUP_FILE")
            
            if [ -n "$subnet" ] && [ "$subnet" != "null" ]; then
                entries=$((entries + 1))
                
                # Construct the route command
                local cmd="ip route replace $subnet"
                
                if [ -n "$via" ] && [ "$via" != "null" ]; then
                    cmd+=" via $via"
                fi
                
                if [ -n "$dev" ] && [ "$dev" != "null" ]; then
                    cmd+=" dev $dev"
                fi
                
                if eval "$cmd"; then
                    successes=$((successes + 1))
                fi
            fi
        done
    else
        # Fallback to grep/sed parsing if jq is not available

        # Skip flannel routes if not managing them
        if is_flannel_route "$subnet" && [ "$MANAGE_FLANNEL_ROUTES" != "true" ]; then
            log "DEBUG" "Skipping flannel route during restore: $subnet"
            continue
        fi

        # Extract route components
        local subnets=$(grep -o '"subnet":"[^"]*"' "$ROUTES_BACKUP_FILE" | cut -d'"' -f4)
        local vias=$(grep -o '"via":"[^"]*"' "$ROUTES_BACKUP_FILE" | cut -d'"' -f4)
        local devs=$(grep -o '"dev":"[^"]*"' "$ROUTES_BACKUP_FILE" | cut -d'"' -f4)
        
        # Convert to arrays
        local subnet_array=()
        local via_array=()
        local dev_array=()
        
        while read -r subnet; do
            if [ -n "$subnet" ]; then
                subnet_array+=("$subnet")
            fi
        done <<< "$subnets"
        
        while read -r via; do
            if [ -n "$via" ]; then
                via_array+=("$via")
            fi
        done <<< "$vias"
        
        while read -r dev; do
            if [ -n "$dev" ]; then
                dev_array+=("$dev")
            fi
        done <<< "$devs"
        
        # Add routes
        for ((i=0; i<${#subnet_array[@]}; i++)); do
            if [ -n "${subnet_array[$i]}" ]; then
                entries=$((entries + 1))
                
                # Construct the route command
                local cmd="ip route replace ${subnet_array[$i]}"
                
                if [ -n "${via_array[$i]}" ]; then
                    cmd+=" via ${via_array[$i]}"
                fi
                
                if [ -n "${dev_array[$i]}" ]; then
                    cmd+=" dev ${dev_array[$i]}"
                fi
                
                if eval "$cmd"; then
                    successes=$((successes + 1))
                fi
            fi
        done
    fi
    
    log "INFO" "Restored $successes/$entries routes from backup"
    return 0
}

# ==========================================
# Route configuration functions
# ==========================================

# Parse extra routes from environment variable
# Usage: parse_extra_routes
parse_extra_routes() {
    if [ -z "$FLANNEL_ROUTES_EXTRA" ]; then
        return 0
    fi
    
    log "INFO" "Parsing extra routes: $FLANNEL_ROUTES_EXTRA"
    
    # Split routes by comma
    IFS=',' read -ra EXTRA_ROUTES <<< "$FLANNEL_ROUTES_EXTRA"
    
    for route in "${EXTRA_ROUTES[@]}"; do
        # Split route by colon
        IFS=':' read -r subnet gateway interface <<< "$route"
        
        if is_valid_route_cidr "$subnet" && is_valid_route_ip "$gateway"; then
            log "INFO" "Adding extra route: $subnet via $gateway dev ${interface:-auto}"
            
            if [ -n "$interface" ] && is_valid_route_interface "$interface"; then
                ip route replace "$subnet" via "$gateway" dev "$interface" proto static || {
                    log "WARNING" "Failed to add extra route: $subnet via $gateway dev $interface"
                }
            else
                ip route replace "$subnet" via "$gateway" proto static || {
                    log "WARNING" "Failed to add extra route: $subnet via $gateway"
                }
            fi
        fi
    done
    
    return 0
}
# =========================================
# Helper functions
# =========================================

# Check if a route is managed by flannel
is_flannel_route() {
    local subnet="$1"
    if [ -z "$subnet" ]; then
        return 1
    fi
    
    # Primary detection: Check if the route has the onlink attribute on flannel.1
    if has_flannel_onlink_route "$subnet"; then
        return 0
    fi
    
    # Secondary detection: Check prefix pattern (traditional flannel subnets)
    if [[ "$subnet" =~ ^${FLANNEL_NETWORK_PREFIX}\. ]]; then
        return 0
    fi
    
    return 1
}

# Check if a route exists with flannel onlink attribute
# Check if a route exists with flannel onlink attribute
has_flannel_onlink_route() {
    local subnet="$1"
    if [ -z "$subnet" ]; then
        return 1
    fi
    
    # Check if there's a route for this subnet with the onlink attribute on flannel.1
    if ip route show | grep -q "$subnet.*dev flannel.1.*onlink"; then
        return 0
    fi
    
    return 1
}

# ==========================================
# Core route management functions
# ==========================================

# Ensure routes exist between registered hosts
ensure_host_routes() {
    log "INFO" "Ensuring host-to-host routes exist for indirect routing"
    
    # Skip if HOST_GATEWAY_MAP is not defined
    if [ -z "$HOST_GATEWAY_MAP" ]; then
        log "DEBUG" "No HOST_GATEWAY_MAP defined, skipping host route configuration"
        return 0
    fi
    
    local success=0
    
    # Process the HOST_GATEWAY_MAP to ensure routes between hosts
    IFS=',' read -ra MAP_ENTRIES <<< "$HOST_GATEWAY_MAP"
    for entry in "${MAP_ENTRIES[@]}"; do
        IFS=':' read -r remote_host gateway <<< "$entry"
        
        # Skip empty entries
        if [ -z "$remote_host" ] || [ -z "$gateway" ]; then
            continue
        fi
        
        # Extract the network from the remote host for the route
        local remote_network=$(echo "$remote_host" | cut -d. -f1-3).0/24
        
        # Check if the route already exists
        if ip route show | grep -q "$remote_network via $gateway"; then
            log "DEBUG" "Host route already exists for $remote_network via $gateway"
            success=$((success + 1))
        else
            log "INFO" "Adding host route for $remote_network via $gateway"
            
            # Get the right interface
            local gateway_iface=$(ip route get $gateway 2>/dev/null | grep -o 'dev [^ ]*' | cut -d' ' -f2 || echo "")
            
            if [ -n "$gateway_iface" ]; then
                # Add the route with the explicit interface
                if ip route add "$remote_network" via "$gateway" dev "$gateway_iface"; then
                    log "INFO" "Successfully added host route for $remote_network via $gateway"
                    success=$((success + 1))
                else
                    log "ERROR" "Failed to add host route for $remote_network via $gateway dev $gateway_iface"
                fi
            else
                # Try without explicit interface
                if ip route add "$remote_network" via "$gateway"; then
                    log "INFO" "Successfully added host route for $remote_network via $gateway"
                    success=$((success + 1))
                else
                    log "ERROR" "Failed to add host route for $remote_network via $gateway"
                fi
            fi
        fi
    done
    
    log "INFO" "Host route configuration completed: $success routes configured"
    return 0
}


# Ensure routes exist for all registered networks
# Usage: ensure_flannel_routes
ensure_flannel_routes() {
    local current_time=$(date +%s)
    
    # Only run full update every ROUTES_UPDATE_INTERVAL seconds
    if [ $((current_time - ROUTES_LAST_UPDATE_TIME)) -lt $ROUTES_UPDATE_INTERVAL ]; then
        log "DEBUG" "Skipping route update - last update was $(($current_time - ROUTES_LAST_UPDATE_TIME)) seconds ago"
        return 0
    fi
    
    log "INFO" "Ensuring routes exist for all registered flannel networks"
    ROUTES_LAST_UPDATE_TIME=$current_time
    
    # First, ensure host-to-host routes exist (NEW LINE)
    ensure_host_routes
    
    # Log flannel route management mode
    if [ "$MANAGE_FLANNEL_ROUTES" = "true" ]; then
        log "INFO" "Flannel route management is ENABLED - will modify flannel routes if needed"
    else
        log "INFO" "Flannel route management is DISABLED - will monitor but not modify flannel routes"
    fi
    
    # Initialize auto-detected gateway map
    declare -A DETECTED_GATEWAYS
    
    # Get all subnet entries with their PublicIPs
    local subnet_keys=""
    while read -r key; do
        if [ -n "$key" ]; then
            subnet_keys+=" $key"
        fi
    done < <(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    
    if [[ -z "$subnet_keys" ]]; then
        log "WARNING" "No subnet entries found or could not access etcd."
        return 1
    fi
    
    # First pass - analyze network topology and detect potential indirect routes
    log "DEBUG" "Analyzing network topology for indirect routing..."
    for key in $subnet_keys; do
        local subnet_id=$(basename "$key")

        # Validate key to ensure it's not a concatenated key
        if [[ "$key" == *"/"*"/"* ]] && [[ $(echo "$key" | grep -o "/" | wc -l) -gt 5 ]]; then
            log "WARNING" "Skipping potentially concatenated key: $key"
            continue
        fi

        local subnet_data=$(etcd_get "$key")
        
        if [[ -n "$subnet_data" ]]; then
            # Extract PublicIP
            local public_ip
            if command -v jq &>/dev/null; then
                public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
            else
                public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
            fi
            
            # Auto-detect possible indirect routing needs
            if [[ "$public_ip" == "172.24."* ]]; then
                # This is a WireGuard IP - we might need indirect routing
                log "DEBUG" "Detected WireGuard IP: $public_ip - checking for routing"
                
                # Check if we have direct connectivity
                if ! ping -c 1 -W 1 "$public_ip" &>/dev/null; then
                    log "DEBUG" "No direct connectivity to $public_ip - looking for gateway"
                    
                    # Try to determine best gateway
                    local wg_iface=$(ip link show | grep -o 'wg[0-9]*' | head -1)
                    if [[ -n "$wg_iface" ]]; then
                        # Get the gateway for this interface
                        local wg_routes=$(ip route | grep "$wg_iface")
                        log "DEBUG" "Found WireGuard interface: $wg_iface with routes: $wg_routes"
                        
                        # Extract a potential gateway (this is simplified)
                        local wg_gateway=$(ip route | grep "172.24." | grep -o 'via [0-9.]*' | head -1 | cut -d' ' -f2)
                        if [[ -n "$wg_gateway" ]]; then
                            log "DEBUG" "Auto-detected gateway for $public_ip: $wg_gateway"
                            DETECTED_GATEWAYS["$public_ip"]="$wg_gateway"
                        fi
                    fi
                fi
            fi
        fi
    done
    
    # Log detected gateways
    for ip in "${!DETECTED_GATEWAYS[@]}"; do
        log "DEBUG" "Auto-detected routing: $ip via ${DETECTED_GATEWAYS[$ip]}"
    done
    
    # Second pass - add/update routes
    local added=0
    local updated=0
    local unchanged=0
    local skipped=0
    local success=0
    local flannel_skipped=0
    
    for key in $subnet_keys; do
        # Extract subnet from key (e.g., 10.5.40.0-24 from /coreos.com/network/subnets/10.5.40.0-24)
        local subnet_id=$(basename "$key")
        local subnet_data=$(etcd_get "$key")
        
        # Validate subnet_id format before processing
        # Skip date-like entries and other invalid formats
        if [[ "$subnet_id" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            log "DEBUG" "Skipping date-like key: $subnet_id"
            skipped=$((skipped + 1))
            continue
        fi
        
        # Additional validation for subnet_id format
        if ! [[ "$subnet_id" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]; then
            log "DEBUG" "Skipping invalid subnet key format: $subnet_id"
            skipped=$((skipped + 1))
            continue
        fi

        # Only process if we got data
        if [[ -n "$subnet_data" ]]; then
            # Extract PublicIP using jq if available
            local public_ip
            if command -v jq &>/dev/null; then
                public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
            else
                # Fallback to regex
                public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
            fi
            
            # Convert the subnet notation back to CIDR (e.g., 10.5.40.0-24 to 10.5.40.0/24)
            local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')

            if ! validate_subnet "$cidr_subnet"; then
                log "WARNING" "Skipping invalid CIDR: $cidr_subnet"
                skipped=$((skipped + 1))
                continue
            fi

            # Skip any subnet with localhost IP or our own IP
            if [[ "$public_ip" == "127.0.0.1" || "$public_ip" == "$FLANNELD_PUBLIC_IP" ]]; then
                continue
            fi
            
            # Check if this is a flannel route
            local is_flannel=false
            if is_flannel_route "$cidr_subnet"; then
                is_flannel=true
                
                # Provide more detailed logging about which detection method was used
                if has_flannel_onlink_route "$cidr_subnet"; then
                    log "DEBUG" "Skipping flannel onlink route: $cidr_subnet via flannel.1"
                else
                    log "DEBUG" "Skipping flannel prefix route: $cidr_subnet"
                fi
    
                # If we're not managing flannel routes, monitor but don't modify
                if [ "$MANAGE_FLANNEL_ROUTES" != "true" ]; then
                    flannel_skipped=$((flannel_skipped + 1))
                    continue
                fi
    
                # If we get here, we're managing flannel routes
                log "DEBUG" "Processing flannel route: $cidr_subnet (MANAGE_FLANNEL_ROUTES=true)"
            fi
            
            # Determine the appropriate gateway for this host
            # First check user-defined map, then auto-detected map, then use direct routing
            local gateway=""
            
            # Check user defined map first
            if type get_host_gateway &>/dev/null; then
                gateway=$(get_host_gateway "$public_ip")
            fi
            
            # If no gateway found and we have an auto-detected one, use that
            if [ -z "$gateway" ] && [ -n "$public_ip" ] && [ -n "${DETECTED_GATEWAYS[$public_ip]:-}" ]; then
                gateway="${DETECTED_GATEWAYS[$public_ip]}"
                log "DEBUG" "Using auto-detected gateway for $public_ip: $gateway"
            fi
            
            # If still no gateway, use direct routing
            if [ -z "$gateway" ]; then
                gateway="$public_ip"
            fi

            # For container subnets (10.5.x.x or 172.x.x.x), use bridge interfaces where possible
            if [[ "$cidr_subnet" == "10.5."* || "$cidr_subnet" == "172."* ]]; then
                log "DEBUG" "Processing subnet $cidr_subnet"

                # First, determine if this is a local subnet that should use a bridge interface
                local is_local_subnet=false
                local bridge_interface=""

                # Try to find a matching bridge interface by checking IP addresses
                for bridge in $(ip link show type bridge | grep -o "br-[0-9a-f]\{12\}\|caddy[^ ]*\|docker[^ ]*" | tr -d ':' | sort -u); do
                    if ip link show dev "$bridge" &>/dev/null && ip link show dev "$bridge" | grep -q "UP"; then
                        # Get the bridge subnet
                        local bridge_subnet=$(ip addr show dev "$bridge" | grep -o "inet [0-9.]\+/[0-9]\+" | awk '{print $2}' | head -1)
                        if [ -n "$bridge_subnet" ]; then
                            local bridge_network=$(echo $bridge_subnet | sed 's#/.*##')
                            local bridge_prefix=$(echo $bridge_network | cut -d. -f1-3)
                            local bridge_network_cidr="$bridge_prefix.0/24"

                            # Debug output
                            log "DEBUG" "Checking bridge $bridge with network $bridge_network_cidr against subnet $cidr_subnet"

                            if [ "$bridge_network_cidr" = "$cidr_subnet" ]; then
                                log "DEBUG" "Found matching bridge $bridge for subnet $cidr_subnet"
                                is_local_subnet=true
                                bridge_interface="$bridge"
                                break
                            fi
                        fi
                    fi
                done

                # Handle based on whether it's a local subnet or not
                if [ "$is_local_subnet" = true ] && [ -n "$bridge_interface" ]; then
                    # This is a local subnet, use direct bridge routing
                    log "INFO" "Subnet $cidr_subnet is local, using bridge $bridge_interface"

                    # Remove any existing routes to this subnet to ensure clean state
                    ip route del "$cidr_subnet" &>/dev/null || true

                    # Add direct route through bridge interface
                    if ip route add "$cidr_subnet" dev "$bridge_interface" scope link; then
                        log "INFO" "Successfully added direct bridge route for $cidr_subnet via $bridge_interface"
                        success=$((success + 1))
                    else
                        log "ERROR" "Failed to add direct bridge route for $cidr_subnet via $bridge_interface"
                    fi
                else
                    # Special handling for flannel routes with onlink
                    if is_flannel_route "$cidr_subnet" && has_flannel_onlink_route "$cidr_subnet"; then
                        log "DEBUG" "Preserving existing flannel onlink route for $cidr_subnet"
                        unchanged=$((unchanged + 1))
                        continue
                    fi
                    
                    # For non-local container subnets, use standard routing logic
                    log "DEBUG" "Subnet $cidr_subnet is remote, using standard routing"
                    
                    # Check if we're routing via a gateway or directly
                    if [[ "$gateway" != "$public_ip" ]]; then
                        if is_valid_route_cidr "$cidr_subnet" && is_valid_route_ip "$gateway"; then
                            # Check if route via gateway exists
                            if ip route show | grep -q "$cidr_subnet.*via $gateway"; then
                                log "DEBUG" "Route already exists for $cidr_subnet via gateway $gateway"
                                unchanged=$((unchanged + 1))
                            else
                                # Skip if this is a flannel route with onlink that we're not supposed to manage
                                if is_flannel_route "$cidr_subnet" && has_flannel_onlink_route "$cidr_subnet" && [ "$MANAGE_FLANNEL_ROUTES" != "true" ]; then
                                    log "DEBUG" "Not modifying flannel onlink route for $cidr_subnet"
                                    flannel_skipped=$((flannel_skipped + 1))
                                    continue
                                fi
                                
                                # Add gateway route and prevent onlink option
                                if ip route add "$cidr_subnet" via "$gateway"; then
                                    log "INFO" "Successfully added route for $cidr_subnet via gateway $gateway"
                                    added=$((added + 1))
                                else
                                    log "ERROR" "Failed to add route for $cidr_subnet via gateway $gateway"
                                fi
                            fi
                        else
                            log "WARNING" "Skipping invalid gateway route: subnet='$cidr_subnet', gateway='$gateway'"
                        fi
                    else
                        # Direct routing
                        log "DEBUG" "Direct routing for $cidr_subnet via $public_ip"

                        # Skip if this is a flannel route with onlink that we're not supposed to manage
                        if is_flannel_route "$cidr_subnet" && has_flannel_onlink_route "$cidr_subnet" && [ "$MANAGE_FLANNEL_ROUTES" != "true" ]; then
                            log "DEBUG" "Not modifying flannel onlink route for $cidr_subnet"
                            flannel_skipped=$((flannel_skipped + 1))
                            continue
                        fi

                        # Check if direct route exists and it's not using flannel.1 with onlink
                        if ip route show | grep -q "$cidr_subnet.*via $public_ip" && ! ip route show | grep -q "$cidr_subnet.*via $public_ip.*onlink"; then
                            log "DEBUG" "Proper route already exists for $cidr_subnet via $public_ip"
                            unchanged=$((unchanged + 1))
                        else
                            # Skip if this is a flannel route with onlink that we're not supposed to manage
                            if is_flannel_route "$cidr_subnet" && has_flannel_onlink_route "$cidr_subnet" && [ "$MANAGE_FLANNEL_ROUTES" != "true" ]; then
                                log "DEBUG" "Not modifying flannel onlink route for $cidr_subnet"
                                flannel_skipped=$((flannel_skipped + 1))
                                continue
                            fi
                            
                            # Remove any existing problematic route
                            if ip route show | grep -q "$cidr_subnet.*onlink"; then
                                if is_flannel_route "$cidr_subnet" && [ "$MANAGE_FLANNEL_ROUTES" != "true" ]; then
                                    log "WARNING" "Found onlink route for flannel subnet $cidr_subnet. Not modifying due to MANAGE_FLANNEL_ROUTES=false."
                                    flannel_skipped=$((flannel_skipped + 1))
                                    continue
                                else 
                                    log "INFO" "Removing problematic onlink route for $cidr_subnet"
                                    ip route del "$cidr_subnet" &>/dev/null || true
                                fi
                            fi
                            
                            log "INFO" "Adding direct route for $cidr_subnet via $public_ip"

                            # Add the direct route - specifically prevent onlink option
                            if is_valid_route_cidr "$cidr_subnet" && is_valid_route_ip "$public_ip"; then
                                if ip route add "$cidr_subnet" via "$public_ip"; then
                                    log "INFO" "Successfully added direct route for $cidr_subnet via $public_ip"
                                    added=$((added + 1))
                                else
                                    log "ERROR" "Failed to add direct route, trying alternative methods..."

                                    # Try to determine interface to the public_ip
                                    local gateway_iface=$(ip route get $public_ip 2>/dev/null | grep -o 'dev [^ ]*' | cut -d' ' -f2 || echo "")
                                    if [[ -n "$gateway_iface" ]]; then
                                        log "INFO" "Trying to add route via interface $gateway_iface"
                                        if ip route add "$cidr_subnet" via "$public_ip" dev "$gateway_iface"; then
                                            log "INFO" "Successfully added route using explicit interface"
                                            added=$((added + 1))
                                        else
                                            log "ERROR" "Failed to add route even with explicit interface"
                                        fi
                                    fi
                                fi
                            else
                                log "WARNING" "Skipping invalid route: subnet='$cidr_subnet', gateway='$public_ip'"
                            fi
                        fi
                    fi
                fi
            else 
                # Non-container subnets use standard routing
                # Check if we're routing via a gateway or directly
                if [[ "$gateway" != "$public_ip" ]]; then
                    if is_valid_route_cidr "$cidr_subnet" && is_valid_route_ip "$gateway"; then
                        # Check if route already exists
                        if ip route show | grep -q "$cidr_subnet.*via $gateway"; then
                            log "DEBUG" "Route already exists for $cidr_subnet via $gateway"
                            unchanged=$((unchanged + 1))
                        else
                            # Add the route
                            if ip route add "$cidr_subnet" via "$gateway"; then
                                log "INFO" "Successfully added route for $cidr_subnet via $gateway"
                                added=$((added + 1))
                            else
                                log "ERROR" "Failed to add route for $cidr_subnet via $gateway"
                            fi
                        fi
                    else
                        log "WARNING" "Skipping invalid gateway route: subnet='$cidr_subnet', gateway='$gateway'"
                    fi
                else
                    # Direct routing
                    log "DEBUG" "Direct routing for $cidr_subnet via $public_ip"
                    
                    # Special handling for WireGuard networks
                    if [[ "$public_ip" == "172.24."* ]]; then
                        log "DEBUG" "WireGuard network: $public_ip"
                        
                        # Check for direct route to WireGuard network
                        if ! ip route show | grep -q "172.24."; then
                            log "WARNING" "No route to WireGuard network"
                            
                            # Try to find a WireGuard interface on the host
                            local wg_iface=$(ip link show | grep -o 'wg[0-9]*' | head -1)
                            if [[ -n "$wg_iface" ]]; then
                                log "DEBUG" "Found WireGuard interface: $wg_iface"
                                
                                # Add a direct route through WireGuard interface
                                if is_valid_route_cidr "$cidr_subnet" && is_valid_route_interface "$wg_iface"; then
                                    log "INFO" "Attempting to add direct route through WireGuard interface"
                                    if ip route add "$cidr_subnet" dev "$wg_iface"; then
                                        log "INFO" "Successfully added direct route for $cidr_subnet via WireGuard interface"
                                        added=$((added + 1))
                                    else
                                        log "ERROR" "Failed to add direct route for $cidr_subnet via WireGuard interface"
                                    fi
                                else
                                    log "WARNING" "Skipping invalid WireGuard route: subnet='$cidr_subnet', interface='$wg_iface'"
                                fi
                            fi
                            continue
                        fi
                    fi
                    
                    # Check if direct route exists
                    if ip route show | grep -q "$cidr_subnet.*via $public_ip"; then
                        log "DEBUG" "Route already exists for $cidr_subnet via $public_ip"
                        unchanged=$((unchanged + 1))
                    elif ip route show | grep -q "$cidr_subnet"; then
                        # Route exists but with different gateway
                        log "INFO" "Updating route for $cidr_subnet to use $public_ip"
                        ip route del "$cidr_subnet" &>/dev/null || true
                        
                        if ip route add "$cidr_subnet" via "$public_ip"; then
                            log "INFO" "Successfully updated route for $cidr_subnet via $public_ip"
                            updated=$((updated + 1))
                        else
                            log "ERROR" "Failed to update route for $cidr_subnet via $public_ip"
                        fi
                    else
                        log "INFO" "Adding direct route for $cidr_subnet via $public_ip"
                        
                        # Add the direct route
                        if is_valid_route_cidr "$cidr_subnet" && is_valid_route_ip "$public_ip"; then
                            # Proceed with adding the route as in the original code
                            if ip route add "$cidr_subnet" via "$public_ip"; then
                                log "INFO" "Successfully added direct route for $cidr_subnet via $public_ip"
                                added=$((added + 1))
                            else
                                log "ERROR" "Failed to add direct route, trying alternative methods..."
                            
                                # Try to determine interface to the public_ip
                                local gateway_iface=$(ip route get $public_ip 2>/dev/null | grep -o 'dev [^ ]*' | cut -d' ' -f2 || echo "")
                                if [[ -n "$gateway_iface" ]]; then
                                    log "INFO" "Trying to add route via interface $gateway_iface"
                                    if ip route add "$cidr_subnet" via "$public_ip" dev "$gateway_iface"; then
                                        log "INFO" "Successfully added route using explicit interface"
                                        added=$((added + 1))
                                    else
                                        log "ERROR" "Failed to add route even with explicit interface"
                                    fi
                                fi
                            fi
                         else
                             log "WARNING" "Skipping invalid route: subnet='$cidr_subnet', gateway='$public_ip'"
                         fi
                    fi
                fi
            fi
        fi
    done
    
    # Add extra routes if defined
    parse_extra_routes
    
    log "INFO" "Route management completed: $added added, $updated updated, $unchanged unchanged, $skipped skipped, $success direct bridge routes, $flannel_skipped flannel routes skipped"
    
    # Backup current routes
    backup_routes
    
    # Run check for problematic routes
    verify_no_onlink_routes
    
    return 0
}

# Fix for routes that flannel sometimes adds that break routing
verify_no_onlink_routes() {
    log "INFO" "Verifying no problematic onlink routes exist"
    
    # Find all routes with the problematic pattern
    local problematic_routes=$(ip route | grep "via .* dev flannel.1 onlink" | awk '{print $1}')
    
    if [ -z "$problematic_routes" ]; then
        log "DEBUG" "No problematic routes found"
        return 0
    fi
    
    log "WARNING" "Found problematic routes, fixing..."
    
    # Process each route
    echo "$problematic_routes" | while read subnet; do
        log "INFO" "Fixing problematic route for $subnet"
        
        # Remove the problematic route
        ip route del "$subnet" || true
        
        # Find potential bridge interfaces
        for bridge in $(ip link show type bridge | grep -o "br-[0-9a-f]\{12\}\|caddy[^ ]*\|docker[^ ]*" | tr -d ':' | sort -u); do
            if [ -z "$bridge" ]; then continue; fi
            
            # Check if bridge exists and is up
            if ip link show dev "$bridge" &>/dev/null && ip link show dev "$bridge" | grep -q "UP"; then
                # Check if subnet belongs to this bridge's network
                bridge_subnet=$(ip addr show dev "$bridge" | grep -o "inet [0-9.]\+/[0-9]\+" | awk '{print $2}' | head -1)
                if [ -n "$bridge_subnet" ]; then
                    bridge_network=$(echo $bridge_subnet | sed 's#/.*##')
                    bridge_prefix=$(echo $bridge_network | cut -d. -f1-3)
                    bridge_network_cidr="$bridge_prefix.0/24"
                    
                    if [ "$bridge_network_cidr" = "$subnet" ]; then
                        log "INFO" "Found matching bridge $bridge for subnet $subnet"
                        
                        # Fix the route
                        if ip route add "$subnet" dev "$bridge" scope link; then
                            log "INFO" "Successfully fixed route for $subnet via $bridge"
                        else
                            log "ERROR" "Failed to add route for $subnet via $bridge"
                        fi
                        
                        break
                    fi
                fi
            fi
        done
    done
    
    return 0
}



# ==========================================
# Route verification functions
# ==========================================

# Verify route integrity
# Usage: verify_routes
verify_routes() {
    log "INFO" "Verifying route integrity"
    
    # Get all expected subnet routes
    local expected_routes=()
    
    local all_subnet_keys=""
    while read -r key; do
        if [ -n "$key" ]; then
            all_subnet_keys+=" $key"
        fi
    done < <(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")

    for key in $all_subnet_keys; do
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
            
            expected_routes+=("$cidr_subnet")
        fi
    done
    
    # Check if all expected routes exist
    local missing_routes=()
    
    for subnet in "${expected_routes[@]}"; do

        # Skip flannel routes if not managing them
        if is_flannel_route "$subnet" && [ "$MANAGE_FLANNEL_ROUTES" != "true" ]; then
            log "DEBUG" "Skipping flannel route verification: $subnet"
            continue
        fi

        if ! ip route show | grep -q "$subnet"; then
            missing_routes+=("$subnet")
        fi
    done
    
    if [ ${#missing_routes[@]} -gt 0 ]; then
        log "WARNING" "Missing routes: ${missing_routes[*]}"
        log "INFO" "Triggering route update to fix missing routes"
        # Force update by resetting the last update time
        ROUTES_LAST_UPDATE_TIME=0
        ensure_flannel_routes
        return 1
    else
        log "INFO" "All expected routes are present"
        return 0
    fi
}

# Get route summary
# Usage: get_route_summary
get_route_summary() {
    log "INFO" "Generating route summary"
    
    local summary=""
    local flannel_routes=$(ip route show | grep -E '10\.[0-9]+\.')
    
    summary+="Flannel Routes:\n"
    summary+="$flannel_routes\n\n"
    
    summary+="WireGuard Routes:\n"
    local wg_routes=$(ip route show | grep -E '172\.24\.')
    summary+="$wg_routes\n\n"
    
    summary+="Default Route:\n"
    local default_route=$(ip route show default)
    summary+="$default_route\n\n"
    
    # Host Gateways
    summary+="Host Gateways:\n"
    if declare -p HOST_GATEWAYS &>/dev/null; then
        for host in "${!HOST_GATEWAYS[@]}"; do
            summary+="$host -> ${HOST_GATEWAYS[$host]}\n"
        done
    else
        summary+="No host gateways defined\n"
    fi
    summary+="\n"
    
    # Extra Routes
    summary+="Extra Routes:\n"
    if [ -n "$FLANNEL_ROUTES_EXTRA" ]; then
        summary+="$FLANNEL_ROUTES_EXTRA\n"
    else
        summary+="None defined\n"
    fi
    
    echo -e "$summary"
}

# Export necessary functions and variables
export -f init_routes_core backup_routes restore_routes_from_backup
export -f parse_extra_routes ensure_flannel_routes ensure_host_routes
export -f verify_routes get_route_summary
export -f is_valid_route_ip is_valid_route_cidr is_valid_route_interface
export -f is_flannel_route has_flannel_onlink_route
export -f is_flannel_route has_flannel_onlink_route log_flannel_route_inventory
export MANAGE_FLANNEL_ROUTES FLANNEL_NETWORK_PREFIX DETECT_FLANNEL_DOCKER_NETWORKS FLANNEL_ADDITIONAL_PREFIXES
export MANAGE_FLANNEL_ROUTES FLANNEL_NETWORK_PREFIX
export ROUTES_LAST_UPDATE_TIME ROUTES_UPDATE_INTERVAL
export ROUTES_STATE_DIR ROUTES_BACKUP_FILE FLANNEL_ROUTES_EXTRA
