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
    
    # Log initialization
    log "INFO" "Initialized routes-core module (v${MODULE_VERSION})"
    
    return 0
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
        
        if [ -n "$subnet" ] && [ -n "$gateway" ]; then
            log "INFO" "Adding extra route: $subnet via $gateway dev ${interface:-auto}"
            
            if [ -n "$interface" ]; then
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

# ==========================================
# Core route management functions
# ==========================================

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
    
    # Initialize auto-detected gateway map
    declare -A DETECTED_GATEWAYS
    
    # Get all subnet entries with their PublicIPs
    local subnet_keys
    subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    
    if [[ -z "$subnet_keys" ]]; then
        log "WARNING" "No subnet entries found or could not access etcd."
        return 1
    fi
    
    # First pass - analyze network topology and detect potential indirect routes
    log "DEBUG" "Analyzing network topology for indirect routing..."
    for key in $subnet_keys; do
        local subnet_id=$(basename "$key")
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
    
    for key in $subnet_keys; do
        # Extract subnet from key (e.g., 10.5.40.0-24 from /coreos.com/network/subnets/10.5.40.0-24)
        local subnet_id=$(basename "$key")
        local subnet_data=$(etcd_get "$key")
        
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
            
            # Skip any subnet with localhost IP or our own IP
            if [[ "$public_ip" == "127.0.0.1" || "$public_ip" == "$FLANNELD_PUBLIC_IP" ]]; then
                continue
            fi
            
            # Determine the appropriate gateway for this host
            # First check user-defined map, then auto-detected map, then use direct routing
            local gateway=""
            
            # Check user defined map first
            if type get_host_gateway &>/dev/null; then
                gateway=$(get_host_gateway "$public_ip")
            fi
            
            # If no gateway found and we have an auto-detected one, use that
            if [ -z "$gateway" ] && [ -n "${DETECTED_GATEWAYS[$public_ip]}" ]; then
                gateway="${DETECTED_GATEWAYS[$public_ip]}"
                log "DEBUG" "Using auto-detected gateway for $public_ip: $gateway"
            fi
            
            # If still no gateway, use direct routing
            if [ -z "$gateway" ]; then
                gateway="$public_ip"
            fi
            
            # Check if we're routing via a gateway or directly
            if [[ "$gateway" != "$public_ip" ]]; then
                log "DEBUG" "Routing for $cidr_subnet via gateway $gateway (target host: $public_ip)"
                
                # Check if route via gateway exists
                if ip route show | grep -q "$cidr_subnet.*via $gateway"; then
                    log "DEBUG" "Route already exists for $cidr_subnet via gateway $gateway"
                    unchanged=$((unchanged + 1))
                else
                    # Remove any direct routes first
                    ip route del "$cidr_subnet" &>/dev/null || true
                    
                    # Add the gateway route
                    if ip route add "$cidr_subnet" via "$gateway"; then
                        log "INFO" "Successfully added route for $cidr_subnet via gateway $gateway"
                        added=$((added + 1))
                    else
                        log "ERROR" "Failed to add route for $cidr_subnet via gateway $gateway"
                    fi
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
                            log "INFO" "Attempting to add direct route through WireGuard interface"
                            if ip route add $cidr_subnet dev $wg_iface; then
                                log "INFO" "Successfully added direct route for $cidr_subnet via WireGuard interface"
                                added=$((added + 1))
                            else
                                log "ERROR" "Failed to add direct route for $cidr_subnet via WireGuard interface"
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
                fi
            fi
        fi
    done
    
    # Add extra routes if defined
    parse_extra_routes
    
    log "INFO" "Route management completed: $added added, $updated updated, $unchanged unchanged"
    
    # Backup current routes
    backup_routes
    
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
    
    for key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/"); do
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
export -f parse_extra_routes ensure_flannel_routes verify_routes get_route_summary
export ROUTES_LAST_UPDATE_TIME ROUTES_UPDATE_INTERVAL
export ROUTES_STATE_DIR ROUTES_BACKUP_FILE FLANNEL_ROUTES_EXTRA
