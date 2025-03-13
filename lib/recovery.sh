#!/bin/bash
# recovery.sh
# Functions for automated network recovery and interface management
# Part of flannel-registrar's modular network management system

# Global variables for recovery operations
RECOVERY_COOLDOWN=${RECOVERY_COOLDOWN:-300}  # Minimum seconds between recovery operations
RECOVERY_MAX_ATTEMPTS=${RECOVERY_MAX_ATTEMPTS:-3}  # Maximum recovery attempts before escalation
RECOVERY_STATE_DIR="/var/run/flannel-registrar"
RECOVERY_LAST_ACTION_TIME=0  # Timestamp of last recovery action
RECOVERY_ATTEMPT_COUNT=0  # Counter for recovery attempts
declare -A RECOVERY_HOST_ATTEMPTS  # Track recovery attempts per host/subnet

# Function to initialize recovery system
init_recovery_system() {
  # Create state directory if it doesn't exist
  mkdir -p "$RECOVERY_STATE_DIR"
  
  # Load previous recovery state if available
  if [ -f "$RECOVERY_STATE_DIR/recovery_state.env" ]; then
    source "$RECOVERY_STATE_DIR/recovery_state.env"
  fi
  
  # Register this host in etcd as active
  register_host_as_active
  
  # Check for hosts that rebooted and need recovery
  check_for_rebooted_hosts
  
  log "INFO" "Recovery system initialized. Last action: $(date -d "@$RECOVERY_LAST_ACTION_TIME")"
}

# Function to register this host as active in etcd
register_host_as_active() {
  local hostname=$(hostname)
  local boot_time=$(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1)
  local current_time=$(date +%s)
  local boot_timestamp=$((current_time - boot_time))
  local flannel_mac=$(cat /sys/class/net/flannel.1/address 2>/dev/null || echo "unknown")
  
  # Create a status entry in etcd
  local status_key="${FLANNEL_CONFIG_PREFIX}/_host_status/${hostname}"
  local status_data="{\"last_seen\":$current_time,\"boot_time\":$boot_timestamp,\"vtep_mac\":\"$flannel_mac\"}"
  
  if etcd_put "$status_key" "$status_data"; then
    log "INFO" "Registered host status in etcd: $hostname (boot: $(date -d "@$boot_timestamp"), VTEP MAC: $flannel_mac)"
  else
    log "WARNING" "Failed to register host status in etcd"
  fi
}

# Function to check for hosts that have rebooted and need recovery
check_for_rebooted_hosts() {
  log "INFO" "Checking for hosts that have recently rebooted"
  
  # Get all host status entries
  local status_keys=$(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/")
  
  if [ -z "$status_keys" ]; then
    log "DEBUG" "No host status entries found"
    return
  fi
  
  local current_time=$(date +%s)
  local recent_reboot_threshold=$((current_time - 600))  # Consider reboots in the last 10 minutes
  
  for key in $status_keys; do
    local host=$(basename "$key")
    local status_data=$(etcd_get "$key")
    
    if [ -n "$status_data" ]; then
      local boot_time=0
      local vtep_mac=""
      
      if command -v jq &>/dev/null; then
        boot_time=$(echo "$status_data" | jq -r '.boot_time')
        vtep_mac=$(echo "$status_data" | jq -r '.vtep_mac')
      else
        boot_time=$(echo "$status_data" | grep -o '"boot_time":[0-9]*' | cut -d':' -f2)
        vtep_mac=$(echo "$status_data" | grep -o '"vtep_mac":"[^"]*"' | cut -d'"' -f4)
      fi
      
      # If host rebooted recently, take recovery actions
      if [ $boot_time -gt $recent_reboot_threshold ]; then
        log "INFO" "Host $host rebooted recently ($(date -d "@$boot_time"))"
        
        # Update FDB entries for this host if we have its VTEP MAC
        if [ -n "$vtep_mac" ] && [ "$vtep_mac" != "unknown" ]; then
          update_fdb_entry_for_host "$host" "$vtep_mac"
        fi
        
        # Check network connectivity to this host
        check_and_recover_connectivity_to_host "$host"
      fi
    fi
  done
}

# Function to update FDB entry for a rebooted host
update_fdb_entry_for_host() {
  local host="$1"
  local vtep_mac="$2"
  
  # Get the host's IP address
  local public_ip=""
  
  # Find subnet entries for this host
  for key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/"); do
    local subnet_data=$(etcd_get "$key")
    
    if [ -n "$subnet_data" ]; then
      local subnet_host=""
      
      if command -v jq &>/dev/null; then
        subnet_host=$(echo "$subnet_data" | jq -r '.PublicIP')
      else
        subnet_host=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
      fi
      
      # Find entries for our target host
      if echo "$subnet_data" | grep -q "\"hostname\":\"$host\""; then
        public_ip="$subnet_host"
        break
      fi
    fi
  done
  
  # If we couldn't find the host's IP, try to resolve it
  if [ -z "$public_ip" ]; then
    public_ip=$(getent hosts "$host" | awk '{print $1}')
  fi
  
  # If we have both MAC and IP, update the FDB entry
  if [ -n "$vtep_mac" ] && [ -n "$public_ip" ]; then
    log "INFO" "Updating FDB entry for $host: MAC=$vtep_mac, IP=$public_ip"
    
    # Remove any existing entry for this MAC
    bridge fdb del "$vtep_mac" dev flannel.1 2>/dev/null || true
    
    # Determine the appropriate endpoint IP (direct or via gateway)
    local endpoint_ip="$public_ip"
    if [ -n "${HOST_GATEWAYS[$public_ip]}" ]; then
      endpoint_ip="${HOST_GATEWAYS[$public_ip]}"
      log "INFO" "Using gateway $endpoint_ip for FDB entry (host: $public_ip)"
    fi
    
    # Add the new entry
    if bridge fdb add "$vtep_mac" dev flannel.1 dst "$endpoint_ip"; then
      log "INFO" "Successfully updated FDB entry for $host"
    else
      log "WARNING" "Failed to update FDB entry for $host"
    fi
  else
    log "WARNING" "Insufficient information to update FDB entry for $host (MAC: $vtep_mac, IP: $public_ip)"
  fi
}

# Function to cycle the flannel interface
# Returns: 0 if successful, 1 if failed
cycle_flannel_interface() {
  local interface="${1:-flannel.1}"
  local force="${2:-false}"
  
  # Check for cooldown period unless forced
  if ! $force; then
    local current_time=$(date +%s)
    if [ $((current_time - RECOVERY_LAST_ACTION_TIME)) -lt $RECOVERY_COOLDOWN ]; then
      log "INFO" "Skipping interface cycle - in cooldown period ($(($RECOVERY_COOLDOWN - (current_time - RECOVERY_LAST_ACTION_TIME))) seconds remaining)"
      return 1
    fi
  fi
  
  log "INFO" "Cycling interface $interface"
  
  # Remember the current MTU and other settings
  local current_mtu=$(ip link show "$interface" 2>/dev/null | grep -o 'mtu [0-9]*' | cut -d' ' -f2 || echo "1370")
  
  # Bring the interface down
  if ! ip link set "$interface" down; then
    log "ERROR" "Failed to bring interface $interface down"
    return 1
  fi
  
  # Short pause to ensure everything settles
  sleep 2
  
  # Bring the interface back up
  if ! ip link set "$interface" up; then
    log "ERROR" "Failed to bring interface $interface up"
    return 1
  fi
  
  # Restore MTU if needed
  if [ "$current_mtu" != "1370" ]; then
    log "INFO" "Restoring MTU to $current_mtu"
    ip link set "$interface" mtu "$current_mtu"
  fi
  
  # Update timestamp
  RECOVERY_LAST_ACTION_TIME=$(date +%s)
  RECOVERY_ATTEMPT_COUNT=$((RECOVERY_ATTEMPT_COUNT + 1))
  
  # Save recovery state
  save_recovery_state
  
  log "INFO" "Interface $interface cycled successfully"
  return 0
}

# Function to restart the flannel container
# Returns: 0 if successful, 1 if failed
restart_flannel_container() {
  local force="${1:-false}"
  
  # Check for cooldown period unless forced
  if ! $force; then
    local current_time=$(date +%s)
    if [ $((current_time - RECOVERY_LAST_ACTION_TIME)) -lt $RECOVERY_COOLDOWN ]; then
      log "INFO" "Skipping flannel container restart - in cooldown period ($(($RECOVERY_COOLDOWN - (current_time - RECOVERY_LAST_ACTION_TIME))) seconds remaining)"
      return 1
    fi
  fi
  
  # Find the flannel container
  local flannel_name="${FLANNEL_CONTAINER_NAME:-flannel}"
  local container_id=$(docker ps --filter name="$flannel_name" --format '{{.ID}}' 2>/dev/null | head -1)
  
  if [ -z "$container_id" ]; then
    log "ERROR" "Flannel container not found"
    return 1
  fi
  
  log "INFO" "Restarting flannel container ($container_id)"
  
  # Restart the container
  if ! docker restart "$container_id"; then
    log "ERROR" "Failed to restart flannel container"
    return 1
  fi
  
  # Update timestamp
  RECOVERY_LAST_ACTION_TIME=$(date +%s)
  RECOVERY_ATTEMPT_COUNT=$((RECOVERY_ATTEMPT_COUNT + 1))
  
  # Save recovery state
  save_recovery_state
  
  # Wait for flannel to initialize
  log "INFO" "Waiting for flannel container to initialize..."
  sleep 10
  
  log "INFO" "Flannel container restarted successfully"
  return 0
}

# Function to restart the docker service on the host
# Requires running as root with systemd
# Returns: 0 if successful, 1 if failed
restart_docker_service() {
  local force="${1:-false}"
  
  # Check if we're running as root
  if [ "$(id -u)" -ne 0 ]; then
    log "ERROR" "Must be running as root to restart Docker service"
    return 1
  fi
  
  # Check for cooldown period unless forced
  if ! $force; then
    local current_time=$(date +%s)
    if [ $((current_time - RECOVERY_LAST_ACTION_TIME)) -lt $((RECOVERY_COOLDOWN * 2)) ]; then
      log "INFO" "Skipping Docker service restart - in extended cooldown period"
      return 1
    fi
  fi
  
  log "WARNING" "Restarting Docker service - this is a disruptive operation"
  
  # Check if using systemd
  if command -v systemctl &>/dev/null; then
    # Record all running containers to restart them later
    local running_containers=$(docker ps --format '{{.Names}}')
    local non_essential_containers=$(docker ps --format '{{.Names}}' | grep -v -E '(flannel|etcd|registrar)')
    
    # Stop non-essential containers gracefully first
    if [ -n "$non_essential_containers" ]; then
      log "INFO" "Stopping non-essential containers..."
      echo "$non_essential_containers" | xargs -r docker stop -t 10
    fi
    
    # Restart Docker service
    log "INFO" "Restarting Docker service..."
    if ! systemctl restart docker; then
      log "ERROR" "Failed to restart Docker service"
      return 1
    fi
    
    # Wait for Docker to become available
    local docker_ready=false
    local timeout=60
    local count=0
    log "INFO" "Waiting for Docker service to become available..."
    
    while [ $count -lt $timeout ]; do
      if docker info &>/dev/null; then
        docker_ready=true
        break
      fi
      sleep 2
      count=$((count + 2))
    done
    
    if ! $docker_ready; then
      log "ERROR" "Docker service did not become available within timeout"
      return 1
    fi
    
    # Update timestamp
    RECOVERY_LAST_ACTION_TIME=$(date +%s)
    RECOVERY_ATTEMPT_COUNT=$((RECOVERY_ATTEMPT_COUNT + 1))
    
    # Save recovery state
    save_recovery_state
    
    log "INFO" "Docker service restarted successfully"
    
    # Start essential containers first
    log "INFO" "Starting essential containers..."
    for container in flannel etcd flannel-registrar; do
      docker start "$container" &>/dev/null || true
    done
    
    # Wait a bit for essential services
    sleep 10
    
    # Start other containers that were running
    if [ -n "$running_containers" ]; then
      log "INFO" "Restarting previously running containers..."
      for container in $running_containers; do
        docker start "$container" &>/dev/null || true
      done
    fi
    
    return 0
  else
    log "ERROR" "System does not appear to use systemd"
    return 1
  fi
}

# Function to check and recover connectivity to a specific host
check_and_recover_connectivity_to_host() {
  local host="$1"
  local public_ip=""
  
  # Try to get the IP address if a hostname was provided
  if [[ ! "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    public_ip=$(getent hosts "$host" | awk '{print $1}')
  else
    public_ip="$host"
  fi
  
  if [ -z "$public_ip" ]; then
    log "ERROR" "Could not determine IP address for host $host"
    return 1
  fi
  
  # Check basic connectivity
  if ! test_host_connectivity "$public_ip"; then
    log "WARNING" "No connectivity to host $public_ip, checking routes"
    
    # Check if we have a gateway for this host
    local gateway=""
    if [ -n "${HOST_GATEWAYS[$public_ip]}" ]; then
      gateway="${HOST_GATEWAYS[$public_ip]}"
      
      # Check gateway connectivity
      if ! test_host_connectivity "$gateway"; then
        log "ERROR" "Cannot reach gateway $gateway for host $public_ip"
        return 1
      fi
      
      # Gateway is reachable but host isn't, ensure routes are correct
      ensure_flannel_routes
      
      # Test again after route update
      if ! test_host_connectivity "$public_ip"; then
        log "WARNING" "Still can't reach host $public_ip after route update"
      else
        log "INFO" "Connectivity to host $public_ip restored after route update"
      fi
    else
      # No gateway defined, try cycling the interface as last resort
      cycle_flannel_interface
    fi
  fi
  
  # Check flannel subnet connectivity
  local host_subnets=()
  
  # Find subnets for this host
  for key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/"); do
    local subnet_data=$(etcd_get "$key")
    
    if [ -n "$subnet_data" ] && echo "$subnet_data" | grep -q "\"PublicIP\":\"$public_ip\""; then
      local subnet_id=$(basename "$key")
      local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
      host_subnets+=("$cidr_subnet")
    fi
  done
  
  # Test connectivity to each subnet
  for subnet in "${host_subnets[@]}"; do
    if ! test_flannel_connectivity "$subnet"; then
      log "WARNING" "Cannot reach flannel subnet $subnet on host $public_ip"
      
      # Check if we've attempted recovery for this host/subnet too many times
      local recovery_key="${public_ip}:${subnet}"
      local attempt_count=0
      
      if [ -n "${RECOVERY_HOST_ATTEMPTS[$recovery_key]}" ]; then
        attempt_count=${RECOVERY_HOST_ATTEMPTS[$recovery_key]}
      fi
      
      if [ $attempt_count -ge $RECOVERY_MAX_ATTEMPTS ]; then
        log "ERROR" "Too many recovery attempts for $recovery_key, skipping"
        continue
      fi
      
      # Increment attempt count
      RECOVERY_HOST_ATTEMPTS[$recovery_key]=$((attempt_count + 1))
      
      # Try recovery actions
      log "INFO" "Attempting recovery for subnet $subnet on host $public_ip"
      
      # Cycle flannel interface
      if cycle_flannel_interface; then
        log "INFO" "Cycled flannel interface, testing connectivity again"
        
        # Test again after cycling
        if test_flannel_connectivity "$subnet"; then
          log "INFO" "Connectivity to $subnet restored after cycling flannel interface"
          continue
        fi
      fi
      
      # If cycling didn't help, try restarting flannel container
      log "INFO" "Interface cycling didn't restore connectivity, trying to restart flannel container"
      if restart_flannel_container; then
        log "INFO" "Restarted flannel container, testing connectivity again"
        
        # Test again after restart
        if test_flannel_connectivity "$subnet"; then
          log "INFO" "Connectivity to $subnet restored after restarting flannel"
          continue
        fi
      fi
      
      # If still not working, get diagnostics
      log "WARNING" "Recovery attempts failed for $subnet on host $public_ip"
      local diagnostics=$(get_connectivity_diagnostics "$subnet")
      log "DEBUG" "Diagnostics for $subnet connectivity:\n$diagnostics"
      
      # Escalate to Docker restart as last resort if running as root and multiple attempts failed
      if [ "$(id -u)" -eq 0 ] && [ $attempt_count -ge $((RECOVERY_MAX_ATTEMPTS - 1)) ]; then
        log "WARNING" "Multiple recovery attempts failed, escalating to Docker service restart"
        restart_docker_service
      fi
    fi
  done
  
  # Save recovery state
  save_recovery_state
}

# Function to save recovery state
save_recovery_state() {
  # Create state directory if it doesn't exist
  mkdir -p "$RECOVERY_STATE_DIR"
  
  # Save basic state
  echo "RECOVERY_LAST_ACTION_TIME=$RECOVERY_LAST_ACTION_TIME" > "$RECOVERY_STATE_DIR/recovery_state.env"
  echo "RECOVERY_ATTEMPT_COUNT=$RECOVERY_ATTEMPT_COUNT" >> "$RECOVERY_STATE_DIR/recovery_state.env"
  
  # Save host attempt counts
  for key in "${!RECOVERY_HOST_ATTEMPTS[@]}"; do
    echo "RECOVERY_HOST_ATTEMPTS[$key]=${RECOVERY_HOST_ATTEMPTS[$key]}" >> "$RECOVERY_STATE_DIR/recovery_state.env"
  done
}

# Function to check if systemd service is needed for recovery
check_systemd_service_needed() {
  # Check if running in container or directly on host
  if [ -f "/.dockerenv" ]; then
    log "INFO" "Running in container, systemd service likely needed for deep recovery"
    return 0
  else
    log "INFO" "Running directly on host, no additional systemd service needed"
    return 1
  fi
}

# Function to recover from flannel interface disappearing
recover_missing_flannel_interface() {
  local interface="${1:-flannel.1}"
  
  if ! ip link show "$interface" &>/dev/null; then
    log "WARNING" "Flannel interface $interface is missing"
    
    # Check if flannel container is running
    local flannel_name="${FLANNEL_CONTAINER_NAME:-flannel}"
    local container_id=$(docker ps --filter name="$flannel_name" --format '{{.ID}}' 2>/dev/null | head -1)
    
    if [ -z "$container_id" ]; then
      log "ERROR" "Flannel container not found, trying to start it"
      
      # Try to find and start flannel container
      container_id=$(docker ps -a --filter name="$flannel_name" --format '{{.ID}}' 2>/dev/null | head -1)
      
      if [ -n "$container_id" ]; then
        log "INFO" "Starting flannel container $container_id"
        docker start "$container_id"
        
        # Wait for flannel to initialize
        log "INFO" "Waiting for flannel to initialize..."
        sleep 10
      else
        log "ERROR" "Flannel container not found, cannot recover"
        return 1
      fi
    else
      # Flannel container is running but interface is missing, restart it
      log "INFO" "Restarting flannel container $container_id"
      docker restart "$container_id"
      
      # Wait for flannel to initialize
      log "INFO" "Waiting for flannel to initialize..."
      sleep 10
    fi
    
    # Check if interface appeared
    if ip link show "$interface" &>/dev/null; then
      log "INFO" "Flannel interface $interface recovered"
      return 0
    else
      log "ERROR" "Failed to recover flannel interface $interface"
      return 1
    fi
  fi
  
  return 0
}

# Function to recover from stale FDB entries
recover_stale_fdb_entries() {
  log "INFO" "Checking for stale FDB entries"
  
  # Get current FDB entries for flannel.1
  local fdb_entries=$(bridge fdb show dev flannel.1 2>/dev/null)
  
  if [ -z "$fdb_entries" ]; then
    log "DEBUG" "No FDB entries found for flannel.1"
    return 0
  fi
  
  # Get all valid VTEP MACs from etcd
  local valid_macs=()
  local valid_hosts=()
  
  for key in $(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/"); do
    local host=$(basename "$key")
    local status_data=$(etcd_get "$key")
    
    if [ -n "$status_data" ]; then
      local vtep_mac=""
      
      if command -v jq &>/dev/null; then
        vtep_mac=$(echo "$status_data" | jq -r '.vtep_mac')
      else
        vtep_mac=$(echo "$status_data" | grep -o '"vtep_mac":"[^"]*"' | cut -d'"' -f4)
      fi
      
      if [ -n "$vtep_mac" ] && [ "$vtep_mac" != "unknown" ]; then
        valid_macs+=("$vtep_mac")
        valid_hosts+=("$host")
      fi
    fi
  done
  
  # Process each FDB entry
  local stale_count=0
  
  while read -r entry; do
    if [ -z "$entry" ]; then
      continue
    fi
    
    # Extract MAC address
    local mac=$(echo "$entry" | awk '{print $1}')
    
    # Check if this MAC is in our valid list
    local is_valid=false
    local host_idx=-1
    
    for i in "${!valid_macs[@]}"; do
      if [ "${valid_macs[$i]}" = "$mac" ]; then
        is_valid=true
        host_idx=$i
        break
      fi
    done
    
    if ! $is_valid; then
      # MAC not in valid list, remove it
      log "WARNING" "Removing stale FDB entry: $entry"
      bridge fdb del "$mac" dev flannel.1
      stale_count=$((stale_count + 1))
    elif [ $host_idx -ne -1 ]; then
      # MAC is valid, check if destination IP is correct
      local host="${valid_hosts[$host_idx]}"
      
      # Get host IP
      local public_ip=""
      for subnet_key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/"); do
        local subnet_data=$(etcd_get "$subnet_key")
        
        if [ -n "$subnet_data" ] && echo "$subnet_data" | grep -q "\"hostname\":\"$host\""; then
          if command -v jq &>/dev/null; then
            public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
          else
            public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
          fi
          
          break
        fi
      done
      
      if [ -n "$public_ip" ]; then
        # Determine correct endpoint (direct or via gateway)
        local endpoint_ip="$public_ip"
        if [ -n "${HOST_GATEWAYS[$public_ip]}" ]; then
          endpoint_ip="${HOST_GATEWAYS[$public_ip]}"
        fi
        
        # Extract current destination
        local current_dst=$(echo "$entry" | grep -o 'dst [^ ]*' | cut -d' ' -f2)
        
        if [ "$current_dst" != "$endpoint_ip" ]; then
          log "WARNING" "Updating FDB entry for $host: MAC=$mac, IP=$endpoint_ip (was $current_dst)"
          bridge fdb del "$mac" dev flannel.1
          bridge fdb add "$mac" dev flannel.1 dst "$endpoint_ip"
        fi
      fi
    fi
  done <<< "$fdb_entries"
  
  if [ $stale_count -gt 0 ]; then
    log "INFO" "Removed $stale_count stale FDB entries"
  else
    log "DEBUG" "No stale FDB entries found"
  fi
  
  return 0
}

# Function to run complete recovery sequence
run_recovery_sequence() {
  log "INFO" "Running complete recovery sequence"
  
  # Step 1: Verify flannel interface exists
  recover_missing_flannel_interface || log "WARNING" "Failed to recover missing flannel interface"
  
  # Step 2: Cycle flannel interface
  cycle_flannel_interface "flannel.1" true || log "WARNING" "Failed to cycle flannel interface"
  
  # Step 3: Check and update FDB entries
  recover_stale_fdb_entries || log "WARNING" "Failed to recover stale FDB entries"
  
  # Step 4: Ensure routes are correct
  ensure_flannel_routes || log "WARNING" "Failed to ensure flannel routes"
  
  # Step 5: Notify other hosts about our current state
  register_host_as_active || log "WARNING" "Failed to register host as active"
  
  # Step 6: Check connectivity to all hosts
  for key in $(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/"); do
    local host=$(basename "$key")
    
    # Skip ourselves
    if [ "$host" = "$(hostname)" ]; then
      continue
    fi
    
    check_and_recover_connectivity_to_host "$host" || log "WARNING" "Failed to recover connectivity to host $host"
  done
  
  log "INFO" "Recovery sequence completed"
  return 0
}

