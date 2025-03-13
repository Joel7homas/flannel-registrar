#!/bin/bash
# fdb-management.sh
# Functions for managing VXLAN FDB entries for Flannel
# Part of flannel-registrar's modular network management system

# Global variables for FDB management
FDB_LAST_UPDATE_TIME=0
FDB_UPDATE_INTERVAL=${FDB_UPDATE_INTERVAL:-120}  # Default 2 minutes between full updates
FDB_STATE_DIR="/var/run/flannel-registrar"
FDB_BACKUP_FILE="$FDB_STATE_DIR/fdb_backup.json"

# Function to initialize FDB management
init_fdb_management() {
  # Create state directory if it doesn't exist
  mkdir -p "$FDB_STATE_DIR"
  
  # Restore from backup if it exists and is recent
  if [ -f "$FDB_BACKUP_FILE" ]; then
    local backup_age=$(($(date +%s) - $(stat -c %Y "$FDB_BACKUP_FILE")))
    
    if [ $backup_age -lt 3600 ]; then  # Backup less than 1 hour old
      log "INFO" "Found recent FDB backup (age: $backup_age seconds), restoring"
      restore_fdb_from_backup
    else
      log "INFO" "Found outdated FDB backup (age: $backup_age seconds), ignoring"
    fi
  fi
}

# Function to backup current FDB entries
backup_fdb_entries() {
  # Get current FDB entries for flannel.1
  if command -v bridge &>/dev/null; then
    local fdb_entries=$(bridge fdb show dev flannel.1 2>/dev/null)
    
    if [ -n "$fdb_entries" ]; then
      # Convert to JSON for easier parsing later
      local fdb_json="["
      local first=true
      
      while read -r entry; do
        if [ -z "$entry" ]; then
          continue
        fi
        
        # Extract MAC and destination
        local mac=$(echo "$entry" | awk '{print $1}')
        local dst=$(echo "$entry" | grep -o 'dst [^ ]*' | cut -d' ' -f2 || echo "")
        
        if ! $first; then
          fdb_json+=","
        fi
        first=false
        
        fdb_json+="{\"mac\":\"$mac\",\"dst\":\"$dst\"}"
      done <<< "$fdb_entries"
      
      fdb_json+="]"
      
      # Save to file
      echo "$fdb_json" > "$FDB_BACKUP_FILE"
      log "DEBUG" "Backed up $(echo "$fdb_json" | grep -o "mac" | wc -l) FDB entries"
    else
      log "WARNING" "No FDB entries found to backup"
      echo "[]" > "$FDB_BACKUP_FILE"
    fi
  else
    log "WARNING" "bridge command not available, cannot backup FDB entries"
  fi
}

# Function to restore FDB entries from backup
restore_fdb_from_backup() {
  if [ -f "$FDB_BACKUP_FILE" ]; then
    if command -v bridge &>/dev/null; then
      log "INFO" "Restoring FDB entries from backup"
      
      local entries=0
      local successes=0
      
      # Read the JSON backup
      if command -v jq &>/dev/null; then
        # Parse JSON with jq
        local count=$(jq length "$FDB_BACKUP_FILE")
        
        for ((i=0; i<count; i++)); do
          local mac=$(jq -r ".[$i].mac" "$FDB_BACKUP_FILE")
          local dst=$(jq -r ".[$i].dst" "$FDB_BACKUP_FILE")
          
          if [ -n "$mac" ] && [ -n "$dst" ] && [ "$mac" != "null" ] && [ "$dst" != "null" ]; then
            entries=$((entries + 1))
            
            # Delete any existing entry for this MAC
            bridge fdb del "$mac" dev flannel.1 2>/dev/null || true
            
            # Add the new entry
            if bridge fdb add "$mac" dev flannel.1 dst "$dst"; then
              successes=$((successes + 1))
            fi
          fi
        done
      else
        # Fallback to grep/sed parsing if jq is not available
        # Extract MAC addresses
        local macs=$(grep -o '"mac":"[^"]*"' "$FDB_BACKUP_FILE" | cut -d'"' -f4)
        local dsts=$(grep -o '"dst":"[^"]*"' "$FDB_BACKUP_FILE" | cut -d'"' -f4)
        
        # Convert to arrays
        local mac_array=()
        local dst_array=()
        
        while read -r mac; do
          if [ -n "$mac" ]; then
            mac_array+=("$mac")
          fi
        done <<< "$macs"
        
        while read -r dst; do
          if [ -n "$dst" ]; then
            dst_array+=("$dst")
          fi
        done <<< "$dsts"
        
        # Add FDB entries
        for ((i=0; i<${#mac_array[@]}; i++)); do
          if [ -n "${mac_array[$i]}" ] && [ -n "${dst_array[$i]}" ]; then
            entries=$((entries + 1))
            
            # Delete any existing entry for this MAC
            bridge fdb del "${mac_array[$i]}" dev flannel.1 2>/dev/null || true
            
            # Add the new entry
            if bridge fdb add "${mac_array[$i]}" dev flannel.1 dst "${dst_array[$i]}"; then
              successes=$((successes + 1))
            fi
          fi
        done
      fi
      
      log "INFO" "Restored $successes/$entries FDB entries from backup"
    else
      log "WARNING" "bridge command not available, cannot restore FDB entries"
    fi
  else
    log "WARNING" "No FDB backup file found"
  fi
}

# Function to update FDB entries from etcd
update_fdb_entries_from_etcd() {
  local current_time=$(date +%s)
  
  # Only run full update every FDB_UPDATE_INTERVAL seconds
  if [ $((current_time - FDB_LAST_UPDATE_TIME)) -lt $FDB_UPDATE_INTERVAL ]; then
    return 0
  fi
  
  log "INFO" "Updating FDB entries from etcd"
  FDB_LAST_UPDATE_TIME=$current_time
  
  if ! command -v bridge &>/dev/null; then
    log "WARNING" "bridge command not available, cannot update FDB entries"
    return 1
  fi
  
  # Get all host status entries to find MAC addresses
  local status_keys=$(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/")
  local host_macs=()
  local host_names=()
  
  for key in $status_keys; do
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
        host_macs+=("$vtep_mac")
        host_names+=("$host")
      fi
    fi
  done
  
  # Get subnet entries to find IP addresses
  local subnet_keys=$(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
  local host_ips=()
  local subnet_hosts=()
  
  for key in $subnet_keys; do
    local subnet_data=$(etcd_get "$key")
    
    if [ -n "$subnet_data" ]; then
      local public_ip=""
      local host=""
      
      if command -v jq &>/dev/null; then
        public_ip=$(echo "$subnet_data" | jq -r '.PublicIP')
        host=$(echo "$subnet_data" | jq -r '.hostname // ""')
      else
        public_ip=$(echo "$subnet_data" | grep -o '"PublicIP":"[^"]*"' | cut -d'"' -f4)
        host=$(echo "$subnet_data" | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4 || echo "")
      fi
      
      if [ -n "$public_ip" ] && [ "$public_ip" != "127.0.0.1" ]; then
        host_ips+=("$public_ip")
        subnet_hosts+=("$host")
      fi
    fi
  done
  
  # Current FDB entries
  local current_fdb=$(bridge fdb show dev flannel.1 2>/dev/null)
  local updated=0
  local added=0
  local removed=0
  
  # Process each host
  for i in "${!host_names[@]}"; do
    local host="${host_names[$i]}"
    local mac="${host_macs[$i]}"
    local ip=""
    
    # Skip ourselves
    if [ "$host" = "$(hostname)" ]; then
      continue
    fi
    
    # Find IP for this host
    for j in "${!subnet_hosts[@]}"; do
      if [ "${subnet_hosts[$j]}" = "$host" ]; then
        ip="${host_ips[$j]}"
        break
      fi
    done
    
    # If no exact hostname match, try to find by IP pattern (for older entries without hostname)
    if [ -z "$ip" ]; then
      for j in "${!host_ips[@]}"; do
        # Try to match by hostname resolution
        if [ "$(getent hosts "$host" 2>/dev/null | awk '{print $1}')" = "${host_ips[$j]}" ]; then
          ip="${host_ips[$j]}"
          break
        fi
      done
    fi
    
    if [ -n "$mac" ] && [ -n "$ip" ]; then
      # Determine appropriate endpoint IP (direct or via gateway)
      local endpoint_ip="$ip"
      if [ -n "${HOST_GATEWAYS[$ip]}" ]; then
        endpoint_ip="${HOST_GATEWAYS[$ip]}"
        log "DEBUG" "Using gateway $endpoint_ip for FDB entry (host: $ip)"
      fi
      
      # Check if entry already exists with correct destination
      if echo "$current_fdb" | grep -q "$mac.*dst $endpoint_ip"; then
        log "DEBUG" "FDB entry for $host already exists and is correct: MAC=$mac, IP=$endpoint_ip"
      else
        # Remove any existing entry for this MAC
        if echo "$current_fdb" | grep -q "$mac"; then
          log "INFO" "Updating FDB entry for $host: MAC=$mac, IP=$endpoint_ip"
          bridge fdb del "$mac" dev flannel.1
          updated=$((updated + 1))
        else
          log "INFO" "Adding new FDB entry for $host: MAC=$mac, IP=$endpoint_ip"
          added=$((added + 1))
        fi
        
        # Add the entry
        bridge fdb add "$mac" dev flannel.1 dst "$endpoint_ip"
      fi
    fi
  done
  
  # Look for entries to remove (MAC addresses not in our known list)
  while read -r entry; do
    if [ -z "$entry" ]; then
      continue
    fi
    
    # Extract MAC address
    local entry_mac=$(echo "$entry" | awk '{print $1}')
    
    # Check if this MAC is in our known list
    local known=false
    for mac in "${host_macs[@]}"; do
      if [ "$mac" = "$entry_mac" ]; then
        known=true
        break
      fi
    done
    
    if ! $known; then
      # MAC not in our known list, remove it
      log "INFO" "Removing unknown FDB entry: $entry"
      bridge fdb del "$entry_mac" dev flannel.1
      removed=$((removed + 1))
    fi
  done <<< "$current_fdb"
  
  log "INFO" "FDB update completed: $added added, $updated updated, $removed removed"
  
  # Backup current FDB entries
  backup_fdb_entries
  
  return 0
}

# Function to fix MTU on flannel interface
fix_flannel_mtu() {
  local interface="${1:-flannel.1}"
  local target_mtu="${2:-1370}"
  
  # Check if interface exists
  if ! ip link show "$interface" &>/dev/null; then
    log "WARNING" "Interface $interface does not exist"
    return 1
  fi
  
  # Get current MTU
  local current_mtu=$(ip link show "$interface" | grep -o 'mtu [0-9]*' | cut -d' ' -f2)
  
  if [ "$current_mtu" != "$target_mtu" ]; then
    log "INFO" "Setting $interface MTU to $target_mtu (was $current_mtu)"
    
    if ip link set "$interface" mtu "$target_mtu"; then
      log "INFO" "MTU updated successfully"
      return 0
    else
      log "ERROR" "Failed to set MTU on $interface"
      return 1
    fi
  else
    log "DEBUG" "MTU already set to $target_mtu on $interface"
    return 0
  fi
}

# Function to troubleshoot VXLAN connectivity issues
troubleshoot_vxlan() {
  local interface="${1:-flannel.1}"
  local remote_ip="${2:-}"
  
  log "INFO" "Troubleshooting VXLAN connectivity for $interface"
  
  # Check if interface exists
  if ! ip link show "$interface" &>/dev/null; then
    log "ERROR" "Interface $interface does not exist"
    return 1
  fi
  
  # Check interface state
  local link_state=$(ip link show "$interface" | grep -o 'state [^ ]*' | cut -d' ' -f2)
  if [ "$link_state" != "UNKNOWN" ]; then
    log "WARNING" "Interface $interface is in $link_state state, should be UNKNOWN"
    ip link set "$interface" up
  fi
  
  # Check MTU
  fix_flannel_mtu "$interface"
  
  # Check FDB entries
  log "INFO" "Current FDB entries for $interface:"
  bridge fdb show dev "$interface" | while read -r entry; do
    log "DEBUG" "FDB entry: $entry"
  done
  
  # If specific remote IP provided, check connectivity
  if [ -n "$remote_ip" ]; then
    log "INFO" "Testing connectivity to $remote_ip"
    
    # Check direct IP connectivity
    if ping -c 1 -W 2 "$remote_ip" &>/dev/null; then
      log "INFO" "Direct connectivity to $remote_ip: OK"
    else
      log "WARNING" "Direct connectivity to $remote_ip: FAILED"
      
      # Check route to remote IP
      local route=$(ip route get "$remote_ip" 2>/dev/null)
      log "DEBUG" "Route to $remote_ip: $route"
      
      # Check if we have a gateway for this host
      if [ -n "${HOST_GATEWAYS[$remote_ip]}" ]; then
        local gateway="${HOST_GATEWAYS[$remote_ip]}"
        log "INFO" "Gateway defined for $remote_ip: $gateway"
        
        # Check gateway connectivity
        if ping -c 1 -W 2 "$gateway" &>/dev/null; then
          log "INFO" "Connectivity to gateway $gateway: OK"
        else
          log "WARNING" "Connectivity to gateway $gateway: FAILED"
        fi
      fi
    fi
    
    # Get MAC address from etcd for this IP
    local mac=""
    for key in $(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/"); do
      local status_data=$(etcd_get "$key")
      
      if [ -n "$status_data" ]; then
        local host_ip=""
        for subnet_key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/"); do
          local subnet_data=$(etcd_get "$subnet_key")
          
          if [ -n "$subnet_data" ] && echo "$subnet_data" | grep -q "\"PublicIP\":\"$remote_ip\""; then
            host_ip="$remote_ip"
            break
          fi
        done
        
        if [ "$host_ip" = "$remote_ip" ]; then
          if command -v jq &>/dev/null; then
            mac=$(echo "$status_data" | jq -r '.vtep_mac')
          else
            mac=$(echo "$status_data" | grep -o '"vtep_mac":"[^"]*"' | cut -d'"' -f4)
          fi
          
          break
        fi
      fi
    done
    
    if [ -n "$mac" ]; then
      log "INFO" "VTEP MAC for $remote_ip: $mac"
      
      # Check if we have an FDB entry for this MAC
      if bridge fdb show dev "$interface" | grep -q "$mac"; then
        log "INFO" "FDB entry for MAC $mac exists"
      else
        log "WARNING" "No FDB entry for MAC $mac"
        
        # Determine appropriate endpoint IP (direct or via gateway)
        local endpoint_ip="$remote_ip"
        if [ -n "${HOST_GATEWAYS[$remote_ip]}" ]; then
          endpoint_ip="${HOST_GATEWAYS[$remote_ip]}"
        fi
        
        # Add the entry
        log "INFO" "Adding FDB entry: MAC=$mac, IP=$endpoint_ip"
        bridge fdb add "$mac" dev "$interface" dst "$endpoint_ip"
      fi
    else
      log "WARNING" "Could not find VTEP MAC for $remote_ip in etcd"
    fi
  fi
  
  # Check for one-way communication by analyzing packet stats
  local stats=$(ip -s link show "$interface")
  local rx_packets=$(echo "$stats" | grep -A1 RX | tail -1 | awk '{print $1}')
  local tx_packets=$(echo "$stats" | grep -A1 TX | tail -1 | awk '{print $1}')
  
  log "INFO" "Interface statistics: RX=$rx_packets packets, TX=$tx_packets packets"
  
  # Check for significant imbalance (100:1 ratio or greater)
  if [ $rx_packets -gt 100 ] && [ $tx_packets -lt $(($rx_packets / 100)) ]; then
    log "WARNING" "Possible one-way communication issue: receiving packets but almost no transmission"
  elif [ $tx_packets -gt 100 ] && [ $rx_packets -lt $(($tx_packets / 100)) ]; then
    log "WARNING" "Possible one-way communication issue: transmitting packets but almost no reception"
  fi
  
  # Check kernel configuration for VXLAN
  local vxlan_module=$(lsmod | grep vxlan || echo "")
  if [ -z "$vxlan_module" ]; then
    log "WARNING" "VXLAN kernel module not loaded"
  else
    log "INFO" "VXLAN kernel module is loaded"
  fi
  
  # Check UDP port for VXLAN
  local udp_port=$(cat /proc/net/udp 2>/dev/null | grep "00000000:2118" || echo "")
  if [ -z "$udp_port" ]; then
    log "WARNING" "VXLAN UDP port 8472 (0x2118) not found in /proc/net/udp"
  else
    log "INFO" "VXLAN UDP port 8472 (0x2118) is open"
  fi
  
  # Return troubleshooting summary
  return 0
}

# Function to check VXLAN connectivity and fix common issues
check_and_fix_vxlan() {
  local interface="${1:-flannel.1}"
  
  # Check if interface exists
  if ! ip link show "$interface" &>/dev/null; then
    log "WARNING" "Interface $interface does not exist, cannot fix"
    return 1
  fi
  
  # Fix 1: Ensure MTU is correct
  fix_flannel_mtu "$interface"
  
  # Fix 2: Ensure interface is up
  local link_state=$(ip link show "$interface" | grep -o 'state [^ ]*' | cut -d' ' -f2)
  if [ "$link_state" != "UNKNOWN" ]; then
    log "INFO" "Setting interface $interface to UP"
    ip link set "$interface" up
  fi
  
  # Fix 3: Update FDB entries from etcd
  update_fdb_entries_from_etcd
  
  # Fix 4: Flush ARP cache for known problematic entries
  local arp_cache=$(ip neigh show)
  
  while read -r entry; do
    if [[ "$entry" == *"FAILED"* ]]; then
      local ip=$(echo "$entry" | awk '{print $1}')
      log "INFO" "Flushing failed ARP entry for $ip"
      ip neigh flush dev $interface to $ip 2>/dev/null || true
    fi
  done <<< "$arp_cache"
  
  # Fix 5: Check for and remove duplicate FDB entries
  local fdb_entries=$(bridge fdb show dev "$interface" 2>/dev/null)
  local seen_macs=()
  
  while read -r entry; do
    if [ -z "$entry" ]; then
      continue
    fi
    
    # Extract MAC address
    local mac=$(echo "$entry" | awk '{print $1}')
    
    # Check if we've seen this MAC before
    for seen_mac in "${seen_macs[@]}"; do
      if [ "$seen_mac" = "$mac" ]; then
        log "WARNING" "Found duplicate FDB entry for MAC $mac, removing: $entry"
        bridge fdb del "$mac" dev "$interface"
        break
      fi
    done
    
    seen_macs+=("$mac")
  done <<< "$fdb_entries"
  
  log "INFO" "VXLAN fixes applied to $interface"
  return 0
}
