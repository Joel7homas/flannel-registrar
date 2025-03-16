#!/bin/bash
# network-lib.sh
# Network utilities and discovery for flannel-registrar
# Provides network interface management, subnet operations, and host gateway mapping

# Module information
MODULE_NAME="network-lib"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common")

# ==========================================
# Global variables
# ==========================================

# Global associative array for host gateway mappings
declare -A HOST_GATEWAYS

# Default network interface detection
DEFAULT_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)

# Default MTU for flannel interface
FLANNEL_MTU="${FLANNEL_MTU:-1370}"

# Initialize network-lib module
init_network_lib() {
    # Check dependencies
    if ! type log &>/dev/null; then
        echo "ERROR: Required module 'common' is not loaded"
        return 1
    fi
    
    # Create an empty directory for network state if it doesn't exist
    local network_state_dir="${COMMON_STATE_DIR}/network"
    mkdir -p "$network_state_dir" || {
        log "ERROR" "Failed to create network state directory: $network_state_dir"
        return 1
    }
    
    # Parse host gateway map from environment variable
    parse_host_gateway_map
    
    # Log module initialization
    log "INFO" "Initialized network-lib module (v${MODULE_VERSION})"
    log "INFO" "Default network interface: ${DEFAULT_INTERFACE:-unknown}"
    
    return 0
}

# ==========================================
# Network discovery functions
# ==========================================

# Get the primary IP address of the host
# Returns: The primary IP address
get_primary_ip() {
    local interface="${1:-$DEFAULT_INTERFACE}"
    
    if [ -z "$interface" ]; then
        log "WARNING" "No default interface found, trying to determine primary IP"
        # Try to get any non-loopback IPv4 address
        ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1
        return $?
    fi
    
    # Get the primary IP from the default interface
    local primary_ip=$(ip -4 addr show dev "$interface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    
    if [ -z "$primary_ip" ]; then
        log "WARNING" "No IPv4 address found on interface $interface"
        return 1
    fi
    
    echo "$primary_ip"
    return 0
}

# Get all IPv4 addresses for this host
# Returns: List of IPv4 addresses, one per line
get_all_ips() {
    # Get all non-loopback IPv4 addresses
    ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
    return $?
}

# Check if an IP address belongs to this host
# Usage: is_local_ip "192.168.1.10" && echo "This is a local IP"
is_local_ip() {
    local ip="$1"
    
    if [ -z "$ip" ] || ! is_valid_ip "$ip"; then
        return 1
    fi
    
    # Special case for localhost
    if [ "$ip" = "127.0.0.1" ]; then
        return 0
    fi
    
    # Check against all local IPs
    local local_ips=$(get_all_ips)
    
    for local_ip in $local_ips; do
        if [ "$ip" = "$local_ip" ]; then
            return 0
        fi
    done
    
    return 1
}

# Get available Docker networks
# Returns: List of network names and subnets in format "hostname/network subnet"
get_docker_networks() {
    log "INFO" "Discovering Docker networks"
    
    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        log "ERROR" "Docker command not found"
        return 1
    fi
    
    # Check if we can access the Docker API
    if ! docker info &>/dev/null; then
        log "WARNING" "Cannot access Docker API. Check permissions."
        return 1
    fi
    
    # Get hostname
    local hostname="${HOST_NAME:-$(hostname)}"
    
    # Get all networks as JSON
    local networks_json=""
    networks_json=$(docker network ls --format '{{.ID}}' | while read -r id; do
        docker network inspect "$id" 2>/dev/null
    done)
    
    if [ -z "$networks_json" ]; then
        log "WARNING" "Could not get Docker networks"
        return 1
    fi
    
    # Process the JSON to extract network details
    local networks=""
    
    if command -v jq &>/dev/null; then
        # Use jq for more reliable JSON parsing if available
        networks=$(echo "$networks_json" | jq -r '.[] | 
            select(.Name != "bridge" and .Name != "host" and .Name != "none") | 
            select(.IPAM.Config != null) | 
            .Name as $name | 
            .IPAM.Config[0].Subnet as $subnet | 
            if $subnet then "'$hostname'/\($name)\t\($subnet)" else empty end')
    else
        # Fallback to simpler grep/sed approach
        local name=""
        while read -r line; do
            if [[ "$line" == *"\"Name\":"* ]]; then
                name=$(echo "$line" | sed 's/.*"Name": *"\([^"]*\)".*/\1/')
                
                # Skip default networks
                if [[ "$name" == "bridge" || "$name" == "host" || "$name" == "none" ]]; then
                    name=""
                fi
            elif [[ -n "$name" && "$line" == *"\"Subnet\":"* ]]; then
                # Extract subnet
                local subnet=$(echo "$line" | sed 's/.*"Subnet": *"\([^"]*\)".*/\1/')
                
                if [[ -n "$subnet" ]]; then
                    networks+="${hostname}/${name}\t${subnet}\n"
                    name=""
                fi
            fi
        done <<< "$(echo "$networks_json" | grep -E '("Name"|"Subnet")')"
    fi
    
    if [ -z "$networks" ]; then
        log "WARNING" "No Docker networks found"
        return 1
    fi
    
    echo -e "$networks"
    return 0
}

# Register host status with VTEP MAC information in etcd
# Usage: register_host_status
# Updated register_host_status function with compatibility wrapper
register_host_status() {
    # Check if recovery-host.sh functions are available
    if type register_host_as_active &>/dev/null; then
        log "WARNING" "register_host_status() is deprecated - using register_host_as_active() from recovery-host.sh"
        register_host_as_active
        return $?
    fi
    
    # Fallback to original implementation
    log "INFO" "recovery-host.sh not available, using local implementation for host status registration"
    
    local hostname=$(hostname)
    local vtep_mac=""
    local primary_ip=$(get_primary_ip)
    local timestamp=$(date +%s)
    
    # Get VTEP MAC using a more compatible approach
    if [ -e /sys/class/net/flannel.1/address ]; then
        vtep_mac=$(cat /sys/class/net/flannel.1/address)
    else
        # Try using ip command as fallback
        vtep_mac=$(ip link show flannel.1 2>/dev/null | grep -o 'link/ether [^ ]*' | cut -d' ' -f2)
    fi
    
    if [ -z "$vtep_mac" ]; then
        log "ERROR" "Failed to get VTEP MAC address for host status registration"
        return 1
    fi
    
    log "INFO" "Registering host status for $hostname (VTEP MAC: $vtep_mac)"
    
    # Create JSON data
    local status_data="{\"hostname\":\"$hostname\",\"vtep_mac\":\"$vtep_mac\",\"primary_ip\":\"$primary_ip\",\"timestamp\":$timestamp}"
    
    # Write to etcd
    local status_key="${FLANNEL_CONFIG_PREFIX}/_host_status/$hostname"
    if ! etcd_put "$status_key" "$status_data"; then
        log "ERROR" "Failed to register host status in etcd"
        return 1
    fi
    
    log "INFO" "Successfully registered host status in etcd"
    return 0
}

# ==========================================
# Host status management functions (Compatibility)
# ==========================================

# New compatibility function for host status refreshing
refresh_host_status_compat() {
    # Check if recovery-host.sh functions are available
    if type refresh_host_status &>/dev/null; then
        log "DEBUG" "Using refresh_host_status() from recovery-host.sh"
        refresh_host_status
        return $?
    fi
    
    # Fallback to calling register_host_status
    log "DEBUG" "recovery-host.sh not available, using register_host_status() for refresh"
    register_host_status
    return $?
}

# ==========================================
# Host gateway mapping functions
# ==========================================

# Parse HOST_GATEWAY_MAP environment variable
# Populates the global HOST_GATEWAYS associative array
parse_host_gateway_map() {
    local host_gateway_map="${HOST_GATEWAY_MAP:-}"
    
    # Clear existing entries
    for key in "${!HOST_GATEWAYS[@]}"; do
        unset "HOST_GATEWAYS[$key]"
    done
    
    if [ -z "$host_gateway_map" ]; then
        log "DEBUG" "No HOST_GATEWAY_MAP defined"
        return 0
    fi
    
    log "INFO" "Parsing host gateway map: $host_gateway_map"
    
    # Split by comma
    IFS=',' read -ra mappings <<< "$host_gateway_map"
    
    for mapping in "${mappings[@]}"; do
        # Split by colon
        IFS=':' read -r host gateway <<< "$mapping"
        
        if [ -n "$host" ] && [ -n "$gateway" ]; then
            # Validate IP addresses
            if ! is_valid_ip "$host" && ! is_valid_cidr "$host"; then
                log "WARNING" "Invalid host IP or subnet in gateway mapping: $host"
                continue
            fi
            
            if ! is_valid_ip "$gateway"; then
                log "WARNING" "Invalid gateway IP in gateway mapping: $gateway"
                continue
            fi
            
            # Add to associative array
            HOST_GATEWAYS["$host"]="$gateway"
            log "INFO" "Added gateway mapping: $host via $gateway"
        fi
    done
    
    local mapping_count=${#HOST_GATEWAYS[@]}
    log "INFO" "Parsed $mapping_count host-to-gateway mappings"
    
    return 0
}

# Get gateway for a host if defined
# Usage: gateway=$(get_host_gateway "192.168.1.10")
get_host_gateway() {
    local host="$1"
    
    if [ -z "$host" ]; then
        return 1
    fi
    
    # Check direct host match
    if [ -n "${HOST_GATEWAYS[$host]}" ]; then
        echo "${HOST_GATEWAYS[$host]}"
        return 0
    fi
    
    # Check if it's a subnet match
    for subnet in "${!HOST_GATEWAYS[@]}"; do
        if [[ "$subnet" == *"/"* ]] && is_ip_in_subnet "$host" "$subnet"; then
            echo "${HOST_GATEWAYS[$subnet]}"
            return 0
        fi
    done
    
    return 1
}

# ==========================================
# Subnet handling utilities
# ==========================================

# Check if an IP is in a subnet
# Usage: is_ip_in_subnet "192.168.1.10" "192.168.1.0/24" && echo "IP is in subnet"
is_ip_in_subnet() {
    local ip="$1"
    local subnet="$2"
    
    if [ -z "$ip" ] || [ -z "$subnet" ]; then
        return 1
    fi
    
    # Basic validation
    if ! is_valid_ip "$ip" || ! is_valid_cidr "$subnet"; then
        return 1
    fi
    
    # Split subnet into base and prefix
    IFS='/' read -r subnet_base prefix <<< "$subnet"
    
    # Convert IP to integer
    local ip_int=0
    IFS='.' read -ra ip_octets <<< "$ip"
    for i in {0..3}; do
        ip_int=$((ip_int + (${ip_octets[$i]} << (24 - i * 8))))
    done
    
    # Convert subnet base to integer
    local subnet_int=0
    IFS='.' read -ra subnet_octets <<< "$subnet_base"
    for i in {0..3}; do
        subnet_int=$((subnet_int + (${subnet_octets[$i]} << (24 - i * 8))))
    done
    
    # Calculate mask
    local mask=$((0xffffffff << (32 - prefix)))
    
    # Check if IP is in subnet
    local subnet_network=$((subnet_int & mask))
    local ip_network=$((ip_int & mask))
    
    if [ $subnet_network -eq $ip_network ]; then
        return 0
    else
        return 1
    fi
}

# Convert subnet string from etcd to CIDR format
# Usage: cidr=$(convert_subnet_to_cidr "10.5.40.0-24")
convert_subnet_to_cidr() {
    local subnet_id="$1"
    
    if [ -z "$subnet_id" ]; then
        return 1
    fi
    
    # Convert from 10.5.40.0-24 to 10.5.40.0/24
    echo "$subnet_id" | sed 's/-/\//g'
    return $?
}

# Convert CIDR subnet to etcd key format
# Usage: key=$(convert_cidr_to_subnet_key "10.5.40.0/24")
convert_cidr_to_subnet_key() {
    local cidr="$1"
    
    if [ -z "$cidr" ]; then
        return 1
    fi
    
    # Convert from 10.5.40.0/24 to 10.5.40.0-24
    echo "$cidr" | sed 's/\//\-/g'
    return $?
}

# Get first usable IP address in a subnet
# Usage: first_ip=$(get_first_ip_in_subnet "10.5.40.0/24")
get_first_ip_in_subnet() {
    local cidr="$1"
    
    if [ -z "$cidr" ] || ! is_valid_cidr "$cidr"; then
        return 1
    fi
    
    # Extract subnet base
    local subnet_base=$(echo "$cidr" | cut -d'/' -f1)
    
    # For standard flannel networks, use the first host address
    local first_ip="${subnet_base%.*}.$((${subnet_base##*.} + 1))"
    
    echo "$first_ip"
    return 0
}

# ==========================================
# Interface management functions
# ==========================================

# Check if flannel interface exists
# Usage: check_flannel_interface && echo "Interface exists"
check_flannel_interface() {
    local interface="${1:-flannel.1}"
    
    if ip link show "$interface" &>/dev/null; then
        log "DEBUG" "Flannel interface $interface exists"
        return 0
    else
        log "WARNING" "Flannel interface $interface does not exist"
        return 1
    fi
}

# Get flannel interface MAC address
# Usage: mac=$(get_flannel_mac_address)
get_flannel_mac_address() {
    local interface="${1:-flannel.1}"
    
    if ! check_flannel_interface "$interface"; then
        return 1
    fi
    
    local mac=$(cat /sys/class/net/$interface/address 2>/dev/null)
    
    if [ -z "$mac" ]; then
        log "WARNING" "Could not get MAC address for $interface"
        return 1
    fi
    
    echo "$mac"
    return 0
}

# Set MTU on flannel interface
# Usage: set_flannel_mtu 1370
set_flannel_mtu() {
    local mtu="${1:-$FLANNEL_MTU}"
    local interface="${2:-flannel.1}"
    
    if ! check_flannel_interface "$interface"; then
        return 1
    fi
    
    # Get current MTU
    local current_mtu=$(ip link show "$interface" | grep -o 'mtu [0-9]*' | cut -d' ' -f2)
    
    if [ "$current_mtu" = "$mtu" ]; then
        log "DEBUG" "MTU for $interface already set to $mtu"
        return 0
    fi
    
    log "INFO" "Setting MTU for $interface to $mtu (was $current_mtu)"
    
    if ip link set "$interface" mtu "$mtu"; then
        log "INFO" "Successfully set MTU for $interface to $mtu"
        return 0
    else
        log "ERROR" "Failed to set MTU for $interface to $mtu"
        return 1
    fi
}

# Check if VXLAN kernel module is loaded
# Usage: check_vxlan_module && echo "VXLAN module loaded"
check_vxlan_module() {
    if lsmod | grep -q vxlan; then
        log "DEBUG" "VXLAN kernel module is loaded"
        return 0
    else
        log "WARNING" "VXLAN kernel module is not loaded"
        return 1
    fi
}

# Ensure flannel interface is up
# Usage: ensure_flannel_interface_up
ensure_flannel_interface_up() {
    local interface="${1:-flannel.1}"
    
    if ! check_flannel_interface "$interface"; then
        return 1
    fi
    
    # Check if interface is up
    local state=$(ip link show "$interface" | grep -o 'state [^ ]*' | cut -d' ' -f2)
    
    if [ "$state" = "UP" ] || [ "$state" = "UNKNOWN" ]; then
        log "DEBUG" "Interface $interface is already up"
        return 0
    fi
    
    log "INFO" "Bringing up interface $interface"
    
    if ip link set "$interface" up; then
        log "INFO" "Successfully brought up interface $interface"
        return 0
    else
        log "ERROR" "Failed to bring up interface $interface"
        return 1
    fi
}

# Get host behind a subnet (from etcd)
# Usage: host_ip=$(get_host_for_subnet "10.5.40.0/24")
get_host_for_subnet() {
    local subnet="$1"
    
    if [ -z "$subnet" ]; then
        return 1
    fi
    
    # Convert to subnet key format if in CIDR format
    if [[ "$subnet" == *"/"* ]]; then
        subnet=$(convert_cidr_to_subnet_key "$subnet")
    fi
    
    # Get subnet data from etcd
    local subnet_data=$(etcd_get "${FLANNEL_PREFIX}/subnets/${subnet}")
    
    if [ -z "$subnet_data" ]; then
        log "WARNING" "No subnet data found for $subnet"
        return 1
    fi
    
    # Extract PublicIP
    local public_ip=""
    
    if command -v jq &>/dev/null; then
        public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
    else
        public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
    fi
    
    if [ -z "$public_ip" ] || [ "$public_ip" = "null" ]; then
        log "WARNING" "No PublicIP found for subnet $subnet"
        return 1
    fi
    
    echo "$public_ip"
    return 0
}

# Export necessary functions and variables
export -f parse_host_gateway_map get_host_gateway
export -f is_ip_in_subnet convert_subnet_to_cidr convert_cidr_to_subnet_key
export -f get_first_ip_in_subnet
export -f check_flannel_interface get_flannel_mac_address set_flannel_mtu
export -f check_vxlan_module ensure_flannel_interface_up get_host_for_subnet
export -f get_primary_ip get_all_ips is_local_ip get_docker_networks
export -f register_host_status
export -f refresh_host_status_compat
export -A HOST_GATEWAYS
export DEFAULT_INTERFACE FLANNEL_MTU
