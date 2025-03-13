#!/bin/bash
# routes-advanced.sh
# Advanced route management functions for Flannel
# Part of flannel-registrar's modular network management system

# Module information
MODULE_NAME="routes-advanced"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "network-lib" "routes-core")

# ==========================================
# Initialization function
# ==========================================

# Initialize advanced route management
init_routes_advanced() {
    # Check dependencies
    for dep in log etcd_get ensure_flannel_routes; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found. Make sure all dependencies are loaded."
            return 1
        fi
    done
    
    # Log initialization
    log "INFO" "Initialized routes-advanced module (v${MODULE_VERSION})"
    
    return 0
}

# ==========================================
# Advanced route management functions
# ==========================================

# Detect and fix subnet conflicts
# Usage: detect_and_fix_subnet_conflicts
detect_and_fix_subnet_conflicts() {
    log "INFO" "Checking for subnet conflicts"
    
    # Get all flannel subnets
    local flannel_subnets=()
    
    for key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/"); do
        local subnet_id=$(basename "$key")
        local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
        flannel_subnets+=("$cidr_subnet")
    done
    
    # Get all docker network subnets
    local docker_subnets=()
    
    for network in $(docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none'); do
        local subnet=$(docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
        if [ -n "$subnet" ]; then
            docker_subnets+=("$subnet:$network")
        fi
    done
    
    # Check for conflicts
    local conflicts=0
    
    for flannel_subnet in "${flannel_subnets[@]}"; do
        for docker_entry in "${docker_subnets[@]}"; do
            local docker_subnet=$(echo "$docker_entry" | cut -d':' -f1)
            local docker_name=$(echo "$docker_entry" | cut -d':' -f2)
            
            # Skip if they're exactly the same (expected for some networks)
            if [ "$flannel_subnet" = "$docker_subnet" ]; then
                continue
            fi
            
            # Simple conflict check - compare network parts
            local flannel_net=$(echo "$flannel_subnet" | cut -d'/' -f1)
            local docker_net=$(echo "$docker_subnet" | cut -d'/' -f1)
            
            # Compare first three octets
            local flannel_prefix=$(echo "$flannel_net" | cut -d'.' -f1-3)
            local docker_prefix=$(echo "$docker_net" | cut -d'.' -f1-3)
            
            if [ "$flannel_prefix" = "$docker_prefix" ]; then
                log "WARNING" "Potential conflict: flannel subnet $flannel_subnet overlaps with Docker network $docker_name ($docker_subnet)"
                conflicts=$((conflicts + 1))
                
                # For now, just log the conflict - actual fixing would require more complex logic
                # and potentially disruptive changes
            fi
        done
    done
    
    if [ $conflicts -gt 0 ]; then
        log "WARNING" "Found $conflicts potential subnet conflicts"
        return 1
    else
        log "INFO" "No subnet conflicts detected"
        return 0
    fi
}

# Check if routes are overriding each other
# Usage: check_route_overrides
check_route_overrides() {
    log "INFO" "Checking for route overrides"
    
    local all_routes=$(ip route show)
    local override_count=0
    
    # Check for multiple routes to the same destination with different metrics
    while read -r subnet; do
        if [ -z "$subnet" ]; then
            continue
        fi
        
        local routes_for_subnet=$(echo "$all_routes" | grep "^$subnet" | wc -l)
        
        if [ $routes_for_subnet -gt 1 ]; then
            log "WARNING" "Multiple routes exist for $subnet:"
            echo "$all_routes" | grep "^$subnet" | while read -r route; do
                log "WARNING" "  $route"
            done
            
            override_count=$((override_count + 1))
        fi
    done < <(ip route show | grep -v 'default' | awk '{print $1}' | sort | uniq)
    
    if [ $override_count -gt 0 ]; then
        log "WARNING" "Found $override_count route overrides"
        return 1
    else
        log "INFO" "No route overrides detected"
        return 0
    fi
}

# ==========================================
# Firewall/iptables management
# ==========================================

# Ensure iptables rules exist for flannel traffic
# Usage: ensure_flannel_iptables
ensure_flannel_iptables() {
    log "INFO" "Ensuring iptables rules exist for all flannel networks..."
    
    if ! command -v iptables &>/dev/null; then
        log "ERROR" "iptables command not found. Cannot configure firewall rules."
        return 1
    fi
    
    # Get main flannel network from etcd
    local flannel_config=$(etcd_get "${FLANNEL_PREFIX}/config")
    if [[ -z "$flannel_config" ]]; then
        log "WARNING" "Could not retrieve Flannel network config from etcd."
        return 1
    fi
    
    # Extract the main Flannel network CIDR
    local flannel_network
    if command -v jq &>/dev/null; then
        flannel_network=$(echo "$flannel_config" | jq -r '.Network')
    else
        # Fallback to regex
        flannel_network=$(echo "$flannel_config" | grep -o '"Network":"[^"]*"' | cut -d'"' -f4)
    fi
    
    if [[ -z "$flannel_network" ]]; then
        log "WARNING" "Could not determine Flannel network CIDR."
        return 1
    fi
    
    log "INFO" "Using Flannel network: $flannel_network"
    
    # Check if the FORWARD chain has a policy of DROP
    local forward_policy=$(iptables -L FORWARD | head -n1 | awk '{print $4}')
    
    # Ensure the FLANNEL-FWD chain exists
    if ! iptables -L FLANNEL-FWD >/dev/null 2>&1; then
        log "INFO" "Creating FLANNEL-FWD chain..."
        iptables -N FLANNEL-FWD
        iptables -A FLANNEL-FWD -s $flannel_network -j ACCEPT -m comment --comment "flanneld forward"
        iptables -A FLANNEL-FWD -d $flannel_network -j ACCEPT -m comment --comment "flanneld forward"
    else
        log "DEBUG" "FLANNEL-FWD chain already exists."
    fi
    
    # Check if FLANNEL-FWD is in the FORWARD chain
    if ! iptables -L FORWARD | grep -q "FLANNEL-FWD"; then
        log "INFO" "Adding FLANNEL-FWD to FORWARD chain..."
        iptables -A FORWARD -j FLANNEL-FWD
    fi
    
    # Get all subnet entries to create specific rules
    local subnet_keys
    subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    
    if [[ -n "$subnet_keys" ]]; then
        for key in $subnet_keys; do
            # Extract subnet from key
            local subnet_id=$(basename "$key")
            
            # Convert the subnet notation back to CIDR
            local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
            
            # Add specific subnet rules if not already present
            if ! iptables -L FORWARD | grep -q "$cidr_subnet"; then
                log "INFO" "Adding explicit rule for subnet $cidr_subnet..."
                
                # Add bidirectional rules at the top of the FORWARD chain
                for other_key in $subnet_keys; do
                    local other_subnet_id=$(basename "$other_key")
                    local other_cidr_subnet=$(echo "$other_subnet_id" | sed 's/-/\//g')
                    
                    # Skip if same subnet
                    if [[ "$cidr_subnet" == "$other_cidr_subnet" ]]; then
                        continue
                    fi
                    
                    # Check if rule already exists
                    if ! iptables -C FORWARD -s $cidr_subnet -d $other_cidr_subnet -j ACCEPT 2>/dev/null; then
                        log "INFO" "Adding rule: $cidr_subnet -> $other_cidr_subnet"
                        iptables -I FORWARD 1 -s $cidr_subnet -d $other_cidr_subnet -j ACCEPT
                    fi
                    
                    if ! iptables -C FORWARD -s $other_cidr_subnet -d $cidr_subnet -j ACCEPT 2>/dev/null; then
                        log "INFO" "Adding rule: $other_cidr_subnet -> $cidr_subnet"
                        iptables -I FORWARD 1 -s $other_cidr_subnet -d $cidr_subnet -j ACCEPT
                    fi
                done
            fi
        done
    fi
    
    # Add rules for docker networks to flannel networks
    for docker_net in $(docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none'); do
        # Extract docker subnet without using grep -P
        local docker_subnet=$(docker network inspect $docker_net | grep -o '"Subnet": "[^"]*"' | cut -d'"' -f4)
        if [[ -n "$docker_subnet" ]]; then
            if ! iptables -C FORWARD -s $docker_subnet -d $flannel_network -j ACCEPT 2>/dev/null; then
                log "INFO" "Adding rule: Docker $docker_subnet -> Flannel $flannel_network"
                iptables -I FORWARD 1 -s $docker_subnet -d $flannel_network -j ACCEPT
            fi
            
            if ! iptables -C FORWARD -s $flannel_network -d $docker_subnet -j ACCEPT 2>/dev/null; then
                log "INFO" "Adding rule: Flannel $flannel_network -> Docker $docker_subnet"
                iptables -I FORWARD 1 -s $flannel_network -d $docker_subnet -j ACCEPT
            fi
        fi
    done
    
    # Add masquerading rule if it doesn't exist
    if ! iptables -t nat -C POSTROUTING -s $flannel_network ! -d $flannel_network -j MASQUERADE 2>/dev/null; then
        log "INFO" "Adding masquerade rule for $flannel_network"
        iptables -t nat -A POSTROUTING -s $flannel_network ! -d $flannel_network -j MASQUERADE
    fi
    
    log "INFO" "Iptables rules verification completed"
    return 0
}

# ==========================================
# WireGuard specific route management
# ==========================================

# Set up WireGuard routes
# Usage: setup_wireguard_routes
setup_wireguard_routes() {
    log "INFO" "Setting up WireGuard routes if needed"
    
    # Check if any wireguard interfaces exist
    local wg_interfaces=$(ip link show | grep -o 'wg[0-9]*' || echo "")
    
    if [ -z "$wg_interfaces" ]; then
        log "DEBUG" "No WireGuard interfaces found"
        return 0
    fi
    
    log "INFO" "Found WireGuard interfaces: $wg_interfaces"
    
    # Check for WireGuard IP
    local wg_ip=$(ip addr show | grep -o 'inet 172\.24\.90\.[0-9]*/[0-9]*' || echo "")
    
    if [ -n "$wg_ip" ]; then
        local our_wg_ip=$(echo "$wg_ip" | cut -d'/' -f1 | cut -d' ' -f2)
        log "INFO" "Found WireGuard IP: $our_wg_ip"
        
        # Set up routes based on HOST_GATEWAY_MAP if defined
        if [ -n "$HOST_GATEWAY_MAP" ]; then
            log "INFO" "Setting up routes from HOST_GATEWAY_MAP: $HOST_GATEWAY_MAP"
            
            # Split by comma
            IFS=',' read -ra MAPPINGS <<< "$HOST_GATEWAY_MAP"
            
            for mapping in "${MAPPINGS[@]}"; do
                # Split by colon
                IFS=':' read -r host gateway <<< "$mapping"
                
                if [ -n "$host" ] && [ -n "$gateway" ]; then
                    # If the host is in WireGuard subnet, add route
                    if [[ "$host" == "172.24.90"* ]]; then
                        log "INFO" "Adding WireGuard route: $host via $gateway"
                        ip route replace "$host" via "$gateway" || {
                            log "WARNING" "Failed to add WireGuard route for $host via $gateway"
                        }
                    fi
                fi
            done
        else
            log "DEBUG" "No HOST_GATEWAY_MAP defined, using auto-detection"
            
            # Try to auto-detect other WireGuard peers
            local wg_output=$(wg show all endpoints 2>/dev/null || echo "")
            if [ -n "$wg_output" ]; then
                log "INFO" "Auto-detecting WireGuard peers from wg output"
                
                # Extract peers and endpoints
                while read -r line; do
                    local peer=$(echo "$line" | awk '{print $1}')
                    local endpoint=$(echo "$line" | awk '{print $2}' | cut -d':' -f1)
                    
                    if [ -n "$peer" ] && [ -n "$endpoint" ] && [ "$endpoint" != "(none)" ]; then
                        log "INFO" "Found WireGuard peer: $peer with endpoint $endpoint"
                        
                        # Check if we have the peer's allowed IPs
                        local allowed_ips=$(wg show all allowed-ips | grep "$peer" | awk '{$1=""; print $0}')
                        for ip in $allowed_ips; do
                            if [[ "$ip" == "172.24.90"* ]]; then
                                log "INFO" "Adding route for WireGuard peer IP $ip via endpoint $endpoint"
                                ip route replace "$ip" via "$endpoint" || {
                                    log "WARNING" "Failed to add route for $ip via $endpoint"
                                }
                            fi
                        done
                    fi
                done <<< "$wg_output"
            fi
        fi
    fi
    
    # Ensure there's a route for the entire WireGuard subnet
    local wg_subnet="172.24.90.0/24"
    if ! ip route show | grep -q "$wg_subnet"; then
        # Determine best interface
        local wg_iface=$(echo "$wg_interfaces" | head -1)
        log "INFO" "Adding route for entire WireGuard subnet $wg_subnet via $wg_iface"
        ip route add "$wg_subnet" dev "$wg_iface" 2>/dev/null || {
            log "DEBUG" "Failed to add direct route for $wg_subnet, trying gateway..."
            
            # Try to find a gateway route
            local gateway=$(ip route | grep default | head -1 | awk '{print $3}')
            if [ -n "$gateway" ]; then
                ip route add "$wg_subnet" via "$gateway" || {
                    log "WARNING" "Failed to add route for $wg_subnet via gateway $gateway"
                }
            fi
        }
    fi
    
    return 0
}

# ==========================================
# Route diagnostics and troubleshooting
# ==========================================

# Generate detailed route diagnostics
# Usage: route_diagnostics [subnet]
route_diagnostics() {
    local target_subnet="$1"
    
    log "INFO" "Generating route diagnostics"
    
    local diagnostics=""
    
    # System routing information
    diagnostics+="===== System Routing Table =====\n"
    diagnostics+="$(ip route show)\n\n"
    
    diagnostics+="===== Flannel Routes =====\n"
    diagnostics+="$(ip route show | grep -E '10\.[0-9]+')\n\n"
    
    diagnostics+="===== WireGuard Routes =====\n"
    diagnostics+="$(ip route show | grep -E '172\.24')\n\n"
    
    # Network interfaces
    diagnostics+="===== Network Interfaces =====\n"
    diagnostics+="$(ip -br link show)\n\n"
    
    # Flannel interface details
    diagnostics+="===== Flannel Interface =====\n"
    if ip link show dev flannel.1 &>/dev/null; then
        diagnostics+="$(ip -d link show dev flannel.1)\n"
        diagnostics+="$(ip addr show dev flannel.1)\n"
    else
        diagnostics+="Flannel interface does not exist\n"
    fi
    diagnostics+="\n"
    
    # WireGuard interfaces
    local wg_interfaces=$(ip link show | grep -o 'wg[0-9]*' || echo "")
    if [ -n "$wg_interfaces" ]; then
        diagnostics+="===== WireGuard Interfaces =====\n"
        for wg_iface in $wg_interfaces; do
            diagnostics+="--- $wg_iface ---\n"
            diagnostics+="$(ip -d link show dev $wg_iface)\n"
            diagnostics+="$(ip addr show dev $wg_iface)\n"
            
            # Try to get WireGuard-specific info if the tools are available
            if command -v wg &>/dev/null; then
                diagnostics+="--- WireGuard Config ---\n"
                diagnostics+="$(wg show $wg_iface)\n"
            fi
        done
        diagnostics+="\n"
    fi
    
    # Iptables rules
    if command -v iptables &>/dev/null; then
        diagnostics+="===== Iptables Forward Rules =====\n"
        diagnostics+="$(iptables -L FORWARD -n)\n\n"
        
        diagnostics+="===== Iptables Flannel Chain =====\n"
        if iptables -L FLANNEL-FWD -n &>/dev/null; then
            diagnostics+="$(iptables -L FLANNEL-FWD -n)\n"
        else
            diagnostics+="FLANNEL-FWD chain does not exist\n"
        fi
        diagnostics+="\n"
        
        diagnostics+="===== Iptables NAT Rules =====\n"
        diagnostics+="$(iptables -t nat -L POSTROUTING -n)\n\n"
    fi
    
    # Docker networks
    diagnostics+="===== Docker Networks =====\n"
    if command -v docker &>/dev/null; then
        diagnostics+="$(docker network ls)\n\n"
        
        # Get details for each network
        for network in $(docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none'); do
            diagnostics+="--- $network ---\n"
            diagnostics+="$(docker network inspect $network | grep -E 'Subnet|Gateway')\n"
        done
    else
        diagnostics+="Docker command not available\n"
    fi
    diagnostics+="\n"
    
    # Specific subnet diagnostics if requested
    if [ -n "$target_subnet" ]; then
        diagnostics+="===== Specific Subnet Diagnostics: $target_subnet =====\n"
        
        # Try to extract the network part of the subnet
        local network_part=$(echo "$target_subnet" | cut -d'/' -f1)
        
        # Route to this subnet
        diagnostics+="--- Routes to $target_subnet ---\n"
        diagnostics+="$(ip route show | grep "$network_part")\n\n"
        
        # Subnet data from etcd
        local subnet_key=$(echo "$target_subnet" | sed 's/\//\-/g')
        diagnostics+="--- Etcd Data for $target_subnet ---\n"
        local subnet_data=$(etcd_get "${FLANNEL_PREFIX}/subnets/${subnet_key}")
        if [ -n "$subnet_data" ]; then
            diagnostics+="$subnet_data\n"
        else
            diagnostics+="No etcd data found for this subnet\n"
        fi
        diagnostics+="\n"
        
        # Try to determine the host for this subnet
        local host_ip=""
        if [ -n "$subnet_data" ]; then
            if command -v jq &>/dev/null; then
                host_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
            else
                host_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
            fi
        fi
        
        if [ -n "$host_ip" ]; then
            diagnostics+="--- Host for Subnet: $host_ip ---\n"
            
            # Check if we have a gateway mapping for this host
            local gateway=""
            if type get_host_gateway &>/dev/null; then
                gateway=$(get_host_gateway "$host_ip")
            fi
            
            if [ -n "$gateway" ] && [ "$gateway" != "$host_ip" ]; then
                diagnostics+="Gateway mapping: $host_ip → $gateway\n"
            else
                diagnostics+="No gateway mapping found, using direct routing\n"
            fi
            
            # Check connectivity
            diagnostics+="--- Connectivity Tests ---\n"
            if ping -c 1 -W 3 "$host_ip" &>/dev/null; then
                diagnostics+="Host ping: SUCCESS\n"
            else
                diagnostics+="Host ping: FAILED\n"
            fi
            
            # Try to trace route
            if command -v traceroute &>/dev/null; then
                diagnostics+="--- Traceroute to $host_ip ---\n"
                diagnostics+="$(traceroute -n -w 1 -m 5 "$host_ip" 2>&1)\n"
            fi
        fi
    fi
    
    echo -e "$diagnostics"
}

# Export necessary functions and variables
export -f init_routes_advanced detect_and_fix_subnet_conflicts check_route_overrides
export -f ensure_flannel_iptables setup_wireguard_routes route_diagnostics
