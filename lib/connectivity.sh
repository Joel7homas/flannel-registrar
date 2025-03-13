#!/bin/bash
# connectivity.sh
# Functions for network connectivity detection, testing, and reporting
# Part of flannel-registrar's modular network management system

# Global variables for connectivity testing
CONN_TEST_INTERVAL=${CONN_TEST_INTERVAL:-300}  # Default 5 minutes between full tests
CONN_RETRY_COUNT=${CONN_RETRY_COUNT:-3}        # Number of retries before declaring failure
CONN_RETRY_DELAY=${CONN_RETRY_DELAY:-2}        # Seconds between retries
CONN_TEST_TIMEOUT=${CONN_TEST_TIMEOUT:-3}      # Seconds before timeout on ping/curl tests
CONN_LAST_TEST_TIME=0                         # Timestamp of last full test
declare -A CONN_HOST_STATUS                   # Status of each host's connectivity

# Function to test basic connectivity to a remote host
# Arguments: host_ip
# Returns: 0 if reachable, 1 if not
test_host_connectivity() {
  local host_ip="$1"
  local timeout="${2:-$CONN_TEST_TIMEOUT}"
  local retry="${3:-$CONN_RETRY_COUNT}"
  local success=false
  
  for ((i=1; i<=retry; i++)); do
    if ping -c 1 -W "$timeout" "$host_ip" &>/dev/null; then
      success=true
      break
    fi
    sleep 1
  done
  
  if $success; then
    CONN_HOST_STATUS["$host_ip"]="up"
    return 0
  else
    CONN_HOST_STATUS["$host_ip"]="down"
    return 1
  fi
}

# Function to test flannel VXLAN connectivity to a remote subnet
# Arguments: subnet, test_ip (optional - first host in subnet if not provided)
# Returns: 0 if reachable, 1 if not
test_flannel_connectivity() {
  local subnet="$1"
  local test_ip="$2"
  local timeout="${3:-$CONN_TEST_TIMEOUT}"
  local retry="${4:-$CONN_RETRY_COUNT}"
  local success=false
  
  # If no test IP provided, use the first usable IP in the subnet
  if [ -z "$test_ip" ]; then
    local subnet_base=$(echo "$subnet" | cut -d'/' -f1)
    test_ip="${subnet_base%.*}.$((${subnet_base##*.} + 1))"
  fi
  
  log "DEBUG" "Testing flannel connectivity to $subnet (using $test_ip)"
  
  for ((i=1; i<=retry; i++)); do
    if ping -c 1 -W "$timeout" "$test_ip" &>/dev/null; then
      success=true
      break
    fi
    sleep 1
  done
  
  if $success; then
    local status_key="${subnet}"
    CONN_HOST_STATUS["$status_key"]="up"
    log "DEBUG" "Connectivity to $subnet is UP (pinged $test_ip successfully)"
    return 0
  else
    local status_key="${subnet}"
    CONN_HOST_STATUS["$status_key"]="down"
    log "DEBUG" "Connectivity to $subnet is DOWN (failed to ping $test_ip)"
    return 1
  fi
}

# Function to test TCP connectivity to a service on a remote host
# Arguments: host_ip, port, timeout_seconds
# Returns: 0 if reachable, 1 if not
test_service_connectivity() {
  local host_ip="$1"
  local port="$2"
  local timeout="${3:-$CONN_TEST_TIMEOUT}"
  local retry="${4:-$CONN_RETRY_COUNT}"
  local success=false
  
  for ((i=1; i<=retry; i++)); do
    # Use timeout command with nc for TCP connectivity test
    if timeout "$timeout" bash -c "echo > /dev/tcp/$host_ip/$port" 2>/dev/null; then
      success=true
      break
    fi
    sleep 1
  done
  
  if $success; then
    local status_key="${host_ip}:${port}"
    CONN_HOST_STATUS["$status_key"]="up"
    return 0
  else
    local status_key="${host_ip}:${port}"
    CONN_HOST_STATUS["$status_key"]="down"
    return 1
  fi
}

# Function to test container-to-container connectivity 
# Arguments: local_network, remote_host, remote_subnet
# Returns: 0 if reachable, 1 if not
test_container_connectivity() {
  local local_network="$1"
  local remote_host="$2"
  local remote_subnet="$3"
  
  log "INFO" "Testing container connectivity from $local_network to $remote_subnet on $remote_host"
  
  # Find a container on the local network to use for testing
  local test_container=$(docker ps --filter network="$local_network" --format "{{.Names}}" | head -1)
  
  if [ -z "$test_container" ]; then
    # If no existing container, create a temporary one
    test_container="flannel-connectivity-test-$$"
    docker run --rm -d --name "$test_container" --network "$local_network" alpine:latest sleep 300 >/dev/null
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to create test container on network $local_network"
      return 1
    fi
    
    local cleanup_container=true
  else
    local cleanup_container=false
  fi
  
  # Get the first usable IP in the remote subnet for testing
  local subnet_base=$(echo "$remote_subnet" | cut -d'/' -f1)
  local test_ip="${subnet_base%.*}.$((${subnet_base##*.} + 1))"
  
  # Try to ping from the test container
  local result=$(docker exec "$test_container" ping -c 2 -W 3 "$test_ip" 2>&1)
  local exit_code=$?
  
  # Clean up temporary container if we created one
  if $cleanup_container; then
    docker rm -f "$test_container" >/dev/null 2>&1
  fi
  
  if [ $exit_code -eq 0 ]; then
    log "INFO" "Container connectivity test PASSED: $local_network to $remote_subnet"
    return 0
  else
    log "WARNING" "Container connectivity test FAILED: $local_network to $remote_subnet"
    log "DEBUG" "Ping result: $result"
    return 1
  fi
}

# Function to check if flannel interfaces have active traffic
# Arguments: interface_name (default: flannel.1)
# Returns: 0 if traffic seen, 1 if interface is idle
check_interface_traffic() {
  local interface="${1:-flannel.1}"
  
  # Check if interface exists
  if ! ip link show "$interface" &>/dev/null; then
    log "WARNING" "Interface $interface does not exist"
    return 1
  fi
  
  # Get current rx/tx packets
  local stats=$(ip -s link show "$interface")
  local rx_packets=$(echo "$stats" | grep -A1 RX | tail -1 | awk '{print $1}')
  local tx_packets=$(echo "$stats" | grep -A1 TX | tail -1 | awk '{print $1}')
  
  # Store current counts and time
  local current_time=$(date +%s)
  local traffic_file="/tmp/flannel_traffic_${interface//\//_}.dat"
  
  # Load previous values if available
  local prev_time=0
  local prev_rx=0
  local prev_tx=0
  
  if [ -f "$traffic_file" ]; then
    source "$traffic_file"
  fi
  
  # Calculate packets per second
  local time_diff=$((current_time - prev_time))
  if [ $time_diff -gt 0 ]; then
    local rx_pps=$(( (rx_packets - prev_rx) / time_diff ))
    local tx_pps=$(( (tx_packets - prev_tx) / time_diff ))
  else
    local rx_pps=0
    local tx_pps=0
  fi
  
  # Save current values for next check
  echo "prev_time=$current_time" > "$traffic_file"
  echo "prev_rx=$rx_packets" >> "$traffic_file"
  echo "prev_tx=$tx_packets" >> "$traffic_file"
  
  # Check for one-way communication issues (significant traffic in one direction only)
  if [ $rx_pps -gt 5 ] && [ $tx_pps -lt 1 ]; then
    log "WARNING" "Possible one-way communication issue on $interface: RX=$rx_pps pps, TX=$tx_pps pps"
    return 1
  fi
  
  if [ $tx_pps -gt 5 ] && [ $rx_pps -lt 1 ]; then
    log "WARNING" "Possible one-way communication issue on $interface: RX=$rx_pps pps, TX=$tx_pps pps"
    return 1
  fi
  
  # If we see traffic in both directions, interface is active
  if [ $rx_pps -gt 0 ] || [ $tx_pps -gt 0 ]; then
    log "DEBUG" "Interface $interface is active: RX=$rx_pps pps, TX=$tx_pps pps"
    return 0
  else
    log "DEBUG" "Interface $interface is idle: RX=$rx_pps pps, TX=$tx_pps pps"
    # Being idle isn't necessarily a problem, so return 0
    return 0
  fi
}

# Function to perform comprehensive connectivity tests to all known hosts/subnets
# Returns: 0 if all critical connections work, 1 if issues detected
run_connectivity_tests() {
  local current_time=$(date +%s)
  
  # Only run full test every CONN_TEST_INTERVAL seconds
  if [ $((current_time - CONN_LAST_TEST_TIME)) -lt $CONN_TEST_INTERVAL ]; then
    return 0
  fi
  
  log "INFO" "Running comprehensive connectivity tests"
  CONN_LAST_TEST_TIME=$current_time
  local has_failures=false
  
  # Test flannel interface condition first
  check_interface_traffic "flannel.1" || has_failures=true
  
  # Get all subnet entries with their PublicIPs from etcd
  local subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
  if [ -z "$subnet_keys" ]; then
    log "WARNING" "No subnet entries found in etcd"
    return 1
  fi
  
  # Test connectivity to each flannel subnet
  for key in $subnet_keys; do
    # Extract subnet
    local subnet_id=$(basename "$key")
    local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
    
    # Get the host IP for this subnet
    local subnet_data=$(etcd_get "$key")
    local public_ip=""
    
    if [ -n "$subnet_data" ]; then
      if command -v jq &>/dev/null; then
        public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
      else
        public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
      fi
    fi
    
    # Skip our own subnet
    if ip route show | grep -q "$cidr_subnet.*dev flannel.1"; then
      continue
    fi
    
    # Skip subnets with localhost IP
    if [ "$public_ip" = "127.0.0.1" ]; then
      continue
    fi
    
    # First test connectivity to the host itself
    if ! test_host_connectivity "$public_ip"; then
      log "WARNING" "Cannot reach host $public_ip"
      
      # Check if we're using a gateway for this host
      local gateway=""
      if [ -n "${HOST_GATEWAYS[$public_ip]}" ]; then
        gateway="${HOST_GATEWAYS[$public_ip]}"
        
        # Test connectivity to the gateway
        if ! test_host_connectivity "$gateway"; then
          log "ERROR" "Cannot reach gateway $gateway for host $public_ip"
          has_failures=true
        else
          log "INFO" "Can reach gateway $gateway but not host $public_ip"
          # This might be expected in some topologies
        fi
      else
        has_failures=true
      fi
    fi
    
    # Then test flannel subnet connectivity
    if ! test_flannel_connectivity "$cidr_subnet"; then
      log "WARNING" "Cannot reach flannel subnet $cidr_subnet"
      has_failures=true
    fi
  done
  
  # Test container-to-container connectivity for key networks
  for network in "caddy-public-net" "caddy_net"; do
    # Skip if this network doesn't exist locally
    if ! docker network ls --format '{{.Name}}' | grep -q "^$network$"; then
      continue
    fi
    
    for key in $subnet_keys; do
      # Extract subnet
      local subnet_id=$(basename "$key")
      local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
      
      # Skip our own subnet
      if ip route show | grep -q "$cidr_subnet.*dev flannel.1"; then
        continue
      fi
      
      # Get the host for this subnet
      local subnet_data=$(etcd_get "$key")
      local public_ip=""
      
      if [ -n "$subnet_data" ]; then
        if command -v jq &>/dev/null; then
          public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
        else
          public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
        fi
      fi
      
      # Skip if we couldn't determine the host
      if [ -z "$public_ip" ] || [ "$public_ip" = "127.0.0.1" ]; then
        continue
      fi
      
      # Test container connectivity for important networks
      if test_container_connectivity "$network" "$public_ip" "$cidr_subnet"; then
        log "INFO" "Container connectivity OK from $network to $cidr_subnet"
      else
        log "WARNING" "Container connectivity failed from $network to $cidr_subnet"
        has_failures=true
      fi
    done
  done
  
  if $has_failures; then
    log "WARNING" "Connectivity tests completed with some failures"
    return 1
  else
    log "INFO" "All connectivity tests passed successfully"
    return 0
  fi
}

# Function to detect one-way communication issues
# Arguments: subnet1, subnet2
# Returns: 0 if bidirectional, 1 if one-way or no connectivity
detect_one_way_communication() {
  local subnet1="$1"
  local subnet2="$2"
  
  log "INFO" "Testing bidirectional connectivity between $subnet1 and $subnet2"
  
  # Get test IPs (first usable IP in each subnet)
  local subnet1_base=$(echo "$subnet1" | cut -d'/' -f1)
  local test_ip1="${subnet1_base%.*}.$((${subnet1_base##*.} + 1))"
  
  local subnet2_base=$(echo "$subnet2" | cut -d'/' -f1)
  local test_ip2="${subnet2_base%.*}.$((${subnet2_base##*.} + 1))"
  
  # Find containers in each subnet to use for testing
  local network1=$(docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none' | head -1)
  local network2=$(docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none' | grep -v "$network1" | head -1)
  
  if [ -z "$network1" ] || [ -z "$network2" ]; then
    log "WARNING" "Not enough networks to test bidirectional connectivity"
    return 1
  fi
  
  local container1=$(docker ps --filter network="$network1" --format "{{.Names}}" | head -1)
  local container2=$(docker ps --filter network="$network2" --format "{{.Names}}" | head -1)
  
  # Create temporary containers if needed
  local temp_containers=()
  
  if [ -z "$container1" ]; then
    container1="flannel-bidir-test1-$$"
    docker run --rm -d --name "$container1" --network "$network1" alpine:latest sleep 300 >/dev/null
    temp_containers+=("$container1")
  fi
  
  if [ -z "$container2" ]; then
    container2="flannel-bidir-test2-$$"
    docker run --rm -d --name "$container2" --network "$network2" alpine:latest sleep 300 >/dev/null
    temp_containers+=("$container2")
  fi
  
  # Test 1→2 connectivity
  log "DEBUG" "Testing connectivity from $container1 to $test_ip2"
  local result1to2=$(docker exec "$container1" ping -c 2 -W 3 "$test_ip2" 2>&1)
  local success1to2=$?
  
  # Test 2→1 connectivity
  log "DEBUG" "Testing connectivity from $container2 to $test_ip1"
  local result2to1=$(docker exec "$container2" ping -c 2 -W 3 "$test_ip1" 2>&1)
  local success2to1=$?
  
  # Clean up temporary containers
  for container in "${temp_containers[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1
  done
  
  # Analyze results
  if [ $success1to2 -eq 0 ] && [ $success2to1 -eq 0 ]; then
    log "INFO" "Bidirectional connectivity confirmed between $subnet1 and $subnet2"
    return 0
  elif [ $success1to2 -eq 0 ] && [ $success2to1 -ne 0 ]; then
    log "WARNING" "One-way communication detected: $subnet1 → $subnet2 works, but return path fails"
    return 1
  elif [ $success1to2 -ne 0 ] && [ $success2to1 -eq 0 ]; then
    log "WARNING" "One-way communication detected: $subnet2 → $subnet1 works, but return path fails"
    return 1
  else
    log "WARNING" "No connectivity between $subnet1 and $subnet2 in either direction"
    return 1
  fi
}

# Function to get diagnostic information for connectivity issues
# Arguments: subnet or host with issues
# Returns: String with diagnostic information
get_connectivity_diagnostics() {
  local target="$1"
  local diagnostics=""
  
  diagnostics+="Connectivity diagnostics for $target:\n"
  
  # Check if target is a subnet or host
  if [[ "$target" == *"/"* ]]; then
    # It's a subnet
    local subnet_base=$(echo "$target" | cut -d'/' -f1)
    local test_ip="${subnet_base%.*}.$((${subnet_base##*.} + 1))"
    
    # Traceroute
    diagnostics+="Traceroute to $test_ip:\n"
    diagnostics+="$(traceroute -n -m 5 -w 1 "$test_ip" 2>&1)\n\n"
    
    # Route information
    diagnostics+="Routes for this subnet:\n"
    diagnostics+="$(ip route show | grep "$subnet_base")\n\n"
    
    # Check ARP cache
    diagnostics+="ARP cache entries:\n"
    diagnostics+="$(ip neigh show | grep "$subnet_base")\n\n"
  else
    # It's a host
    # Traceroute
    diagnostics+="Traceroute to $target:\n"
    diagnostics+="$(traceroute -n -m 5 -w 1 "$target" 2>&1)\n\n"
    
    # Route information
    diagnostics+="Routes for this host:\n"
    diagnostics+="$(ip route get "$target")\n\n"
    
    # Check ARP cache
    diagnostics+="ARP cache entry:\n"
    diagnostics+="$(ip neigh show | grep "$target")\n\n"
  fi
  
  # FDB entries
  diagnostics+="FDB entries for flannel.1:\n"
  diagnostics+="$(bridge fdb show dev flannel.1)\n\n"
  
  # Interface statistics
  diagnostics+="Interface statistics for flannel.1:\n"
  diagnostics+="$(ip -s link show flannel.1)\n\n"
  
  # Recent kernel messages related to networking
  diagnostics+="Recent kernel messages related to networking:\n"
  diagnostics+="$(dmesg | grep -i -E 'flannel|vxlan|eth|network' | tail -20)\n\n"
  
  echo -e "$diagnostics"
}
