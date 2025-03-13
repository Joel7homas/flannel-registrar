#!/bin/bash
# monitoring.sh
# Functions for monitoring network health and diagnostics
# Part of flannel-registrar's modular network management system

# Global variables for monitoring
MONITORING_INTERVAL=${MONITORING_INTERVAL:-300}  # Default 5 minutes between health checks
MONITORING_LAST_CHECK_TIME=0
MONITORING_STATE_DIR="/var/run/flannel-registrar"
MONITORING_HEALTH_FILE="$MONITORING_STATE_DIR/health_status.json"
MONITORING_STATUS_ENDPOINT=${MONITORING_STATUS_ENDPOINT:-""}  # Optional HTTP endpoint to POST health updates

# Function to initialize monitoring system
init_monitoring() {
  # Create state directory if it doesn't exist
  mkdir -p "$MONITORING_STATE_DIR"
  
  # Initialize health status
  if [ ! -f "$MONITORING_HEALTH_FILE" ]; then
    echo '{"status":"starting","last_check":0,"issues":[]}' > "$MONITORING_HEALTH_FILE"
  fi
}

# Function to update health status
update_health_status() {
  local status="$1"
  local message="$2"
  local issues="$3"
  
  local current_time=$(date +%s)
  
  # Create JSON health status
  local health_json="{\"status\":\"$status\",\"last_check\":$current_time,\"message\":\"$message\",\"hostname\":\"$(hostname)\""
  
  if [ -n "$issues" ]; then
    health_json+=",\"issues\":$issues"
  else
    health_json+=",\"issues\":[]"
  fi
  
  health_json+="}"
  
  # Save to file
  echo "$health_json" > "$MONITORING_HEALTH_FILE"
  
  # Report to status endpoint if configured
  if [ -n "$MONITORING_STATUS_ENDPOINT" ]; then
    curl -s -X POST -H "Content-Type: application/json" -d "$health_json" "$MONITORING_STATUS_ENDPOINT" &>/dev/null || true
  fi
  
  # Update etcd status if possible
  local status_key="${FLANNEL_CONFIG_PREFIX}/_health/$(hostname)"
  etcd_put "$status_key" "$health_json" || true
}

# Function to run a health check
run_health_check() {
  local current_time=$(date +%s)
  
  # Only run full check every MONITORING_INTERVAL seconds
  if [ $((current_time - MONITORING_LAST_CHECK_TIME)) -lt $MONITORING_INTERVAL ]; then
    return 0
  fi
  
  log "INFO" "Running comprehensive health check"
  MONITORING_LAST_CHECK_TIME=$current_time
  
  local issues="["
  local issues_found=false
  local health_status="healthy"
  local health_message="All systems operational"
  
  # Check 1: Flannel interface exists and is up
  if ! ip link show flannel.1 &>/dev/null; then
    if ! $issues_found; then
      issues_found=true
    else
      issues+=","
    fi
    issues+="{\"type\":\"interface\",\"message\":\"flannel.1 interface missing\",\"severity\":\"critical\"}"
    health_status="critical"
    health_message="flannel.1 interface missing"
  else
    local link_state=$(ip link show flannel.1 | grep -o 'state [^ ]*' | cut -d' ' -f2)
    if [ "$link_state" != "UNKNOWN" ]; then
      if ! $issues_found; then
        issues_found=true
      else
        issues+=","
      fi
      issues+="{\"type\":\"interface\",\"message\":\"flannel.1 interface in wrong state: $link_state\",\"severity\":\"warning\"}"
      
      if [ "$health_status" != "critical" ]; then
        health_status="degraded"
        health_message="flannel.1 interface in wrong state"
      fi
    fi
  fi
  
  # Check 2: Flannel container is running
  local flannel_name="${FLANNEL_CONTAINER_NAME:-flannel}"
  if ! docker ps --filter name="$flannel_name" | grep -q "$flannel_name"; then
    if ! $issues_found; then
      issues_found=true
    else
      issues+=","
    fi
    issues+="{\"type\":\"container\",\"message\":\"flannel container not running\",\"severity\":\"critical\"}"
    health_status="critical"
    health_message="flannel container not running"
  fi
  
  # Check 3: Routes to other flannel hosts exist
  local missing_routes=0
  for key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/" 2>/dev/null); do
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
      
      if ! ip route show | grep -q "$cidr_subnet"; then
        missing_routes=$((missing_routes + 1))
      fi
    fi
  done
  
  if [ $missing_routes -gt 0 ]; then
    if ! $issues_found; then
      issues_found=true
    else
      issues+=","
    fi
    issues+="{\"type\":\"routes\",\"message\":\"$missing_routes flannel routes missing\",\"severity\":\"warning\"}"
    
    if [ "$health_status" != "critical" ]; then
      health_status="degraded"
      health_message="$missing_routes flannel routes missing"
    fi
  fi
  
  # Check 4: VXLAN traffic is flowing
  local vxlan_stats=$(ip -s link show flannel.1 2>/dev/null)
  if [ -n "$vxlan_stats" ]; then
    local rx_bytes=$(echo "$vxlan_stats" | grep -A2 RX | tail -1 | awk '{print $1}')
    local tx_bytes=$(echo "$vxlan_stats" | grep -A2 TX | tail -1 | awk '{print $1}')
    
    if [ $rx_bytes -eq 0 ] && [ $tx_bytes -eq 0 ]; then
      if ! $issues_found; then
        issues_found=true
      else
        issues+=","
      fi
      issues+="{\"type\":\"traffic\",\"message\":\"No VXLAN traffic on flannel.1\",\"severity\":\"warning\"}"
      
      if [ "$health_status" != "critical" ]; then
        health_status="degraded"
        health_message="No VXLAN traffic detected"
      fi
    elif [ $rx_bytes -gt 1000000 ] && [ $tx_bytes -lt 1000 ]; then
      if ! $issues_found; then
        issues_found=true
      else
        issues+=","
      fi
      issues+="{\"type\":\"traffic\",\"message\":\"One-way VXLAN traffic detected (receiving only)\",\"severity\":\"warning\"}"
      
      if [ "$health_status" != "critical" ]; then
        health_status="degraded"
        health_message="One-way VXLAN traffic detected"
      fi
    elif [ $tx_bytes -gt 1000000 ] && [ $rx_bytes -lt 1000 ]; then
      if ! $issues_found; then
        issues_found=true
      else
        issues+=","
      fi
      issues+="{\"type\":\"traffic\",\"message\":\"One-way VXLAN traffic detected (sending only)\",\"severity\":\"warning\"}"
      
      if [ "$health_status" != "critical" ]; then
        health_status="degraded"
        health_message="One-way VXLAN traffic detected"
      fi
    fi
  else
    if ! $issues_found; then
      issues_found=true
    else
      issues+=","
    fi
    issues+="{\"type\":\"interface\",\"message\":\"Cannot get VXLAN traffic statistics\",\"severity\":\"warning\"}"
    
    if [ "$health_status" != "critical" ]; then
      health_status="degraded"
      health_message="Cannot get VXLAN traffic statistics"
    fi
  fi
  
  # Check 5: Test connectivity to a sample of hosts
  local connectivity_issues=0
  local hosts_tested=0
  
  for key in $(etcd_list_keys "${FLANNEL_CONFIG_PREFIX}/_host_status/" 2>/dev/null | shuf | head -3); do
    local host=$(basename "$key")
    
    # Skip ourselves
    if [ "$host" = "$(hostname)" ]; then
      continue
    fi
    
    hosts_tested=$((hosts_tested + 1))
    
    # Get host IP
    local public_ip=""
    for subnet_key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/" 2>/dev/null); do
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
    
    if [ -n "$public_ip" ] && [ "$public_ip" != "127.0.0.1" ]; then
      if ! ping -c 1 -W 2 "$public_ip" &>/dev/null; then
        connectivity_issues=$((connectivity_issues + 1))
      fi
    fi
  done
  
  if [ $hosts_tested -gt 0 ] && [ $connectivity_issues -gt 0 ]; then
    if ! $issues_found; then
      issues_found=true
    else
      issues+=","
    fi
    issues+="{\"type\":\"connectivity\",\"message\":\"$connectivity_issues/$hosts_tested hosts unreachable\",\"severity\":\"warning\"}"
    
    if [ "$health_status" != "critical" ]; then
      health_status="degraded"
      health_message="$connectivity_issues/$hosts_tested hosts unreachable"
    fi
  fi
  
  # Check 6: Etcd connectivity
  if ! etcd_get "${FLANNEL_PREFIX}/config" &>/dev/null; then
    if ! $issues_found; then
      issues_found=true
    else
      issues+=","
    fi
    issues+="{\"type\":\"etcd\",\"message\":\"Cannot connect to etcd\",\"severity\":\"critical\"}"
    health_status="critical"
    health_message="Cannot connect to etcd"
  fi
  
  # Finalize issues array
  issues+="]"
  
  # Update health status
  update_health_status "$health_status" "$health_message" "$issues"
  
  log "INFO" "Health check completed - status: $health_status"
  
  # Return 0 if healthy, 1 otherwise
  if [ "$health_status" = "healthy" ]; then
    return 0
  else
    return 1
  fi
}

# Function to get health status
get_health_status() {
  if [ -f "$MONITORING_HEALTH_FILE" ]; then
    cat "$MONITORING_HEALTH_FILE"
  else
    echo '{"status":"unknown","last_check":0,"message":"No health check performed yet","issues":[]}'
  fi
}

# Function to collect diagnostic information
collect_diagnostics() {
  local output_dir="$MONITORING_STATE_DIR/diagnostics_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$output_dir"
  
  log "INFO" "Collecting diagnostic information to $output_dir"
  
  # 1. Network interfaces
  ip addr show > "$output_dir/interfaces.txt"
  
  # 2. Routes
  ip route show > "$output_dir/routes.txt"
  
  # 3. FDB entries
  bridge fdb show dev flannel.1 > "$output_dir/fdb.txt" 2>/dev/null || echo "No FDB entries found" > "$output_dir/fdb.txt"
  
  # 4. Iptables rules
  iptables-save > "$output_dir/iptables.txt" 2>/dev/null || echo "Could not get iptables rules" > "$output_dir/iptables.txt"
  
  # 5. Flannel interface stats
  ip -s link show flannel.1 > "$output_dir/flannel_stats.txt" 2>/dev/null || echo "No flannel interface found" > "$output_dir/flannel_stats.txt"
  
  # 6. Docker networks
  docker network ls > "$output_dir/docker_networks.txt" 2>/dev/null || echo "Could not list Docker networks" > "$output_dir/docker_networks.txt"
  
  # 7. Docker containers
  docker ps > "$output_dir/docker_containers.txt" 2>/dev/null || echo "Could not list Docker containers" > "$output_dir/docker_containers.txt"
  
  # 8. Etcd data
  for key in $(etcd_list_keys "${FLANNEL_PREFIX}" 2>/dev/null); do
    local value=$(etcd_get "$key" 2>/dev/null)
    echo "$key: $value" >> "$output_dir/etcd_data.txt"
  done
  
  # 9. Health status
  get_health_status > "$output_dir/health_status.json"
  
  # 10. Kernel logs
  dmesg | grep -i -E 'flannel|vxlan|network|docker' | tail -100 > "$output_dir/kernel_logs.txt"
  
  # 11. Host information
  uname -a > "$output_dir/host_info.txt"
  cat /etc/os-release >> "$output_dir/host_info.txt" 2>/dev/null || true
  
  # 12. Ping tests
  for key in $(etcd_list_keys "${FLANNEL_PREFIX}/subnets/" 2>/dev/null); do
    local subnet_id=$(basename "$key")
    local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
    
    # Get first usable IP for ping test
    local subnet_base=$(echo "$cidr_subnet" | cut -d'/' -f1)
    local test_ip="${subnet_base%.*}.$((${subnet_base##*.} + 1))"
    
    echo "Ping test to $test_ip ($cidr_subnet):" >> "$output_dir/ping_tests.txt"
    ping -c 3 -W 2 "$test_ip" >> "$output_dir/ping_tests.txt" 2>&1 || echo "Failed" >> "$output_dir/ping_tests.txt"
    echo "" >> "$output_dir/ping_tests.txt"
  done
  
  log "INFO" "Diagnostics collected to $output_dir"
  echo "$output_dir"
}

# Function to monitor and respond to network state changes
monitor_network_state() {
  # Run a health check
  run_health_check
  
  # Check health status
  local health_status=$(get_health_status)
  local status=""
  
  if command -v jq &>/dev/null; then
    status=$(echo "$health_status" | jq -r '.status')
  else
    status=$(echo "$health_status" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
  fi
  
  # Respond based on health status
  if [ "$status" = "critical" ]; then
    log "WARNING" "Critical health status detected - initiating recovery"
    
    # Start recovery process
    if [ -f "$MONITORING_STATE_DIR/recovery_in_progress" ]; then
      local recovery_time=$(cat "$MONITORING_STATE_DIR/recovery_in_progress")
      local current_time=$(date +%s)
      
      # Don't trigger another recovery if one is in progress or recent
      if [ $((current_time - recovery_time)) -lt 300 ]; then
        log "WARNING" "Recovery already in progress or recently completed, skipping"
        return
      fi
    fi
    
    # Mark recovery in progress
    date +%s > "$MONITORING_STATE_DIR/recovery_in_progress"
    
    # Run recovery sequence
    run_recovery_sequence
    
    # Clear recovery marker after a short delay
    (sleep 60; rm -f "$MONITORING_STATE_DIR/recovery_in_progress") &
  elif [ "$status" = "degraded" ]; then
    log "WARNING" "Degraded health status detected - checking specific issues"
    
    # Get issues
    local issues=""
    if command -v jq &>/dev/null; then
      issues=$(echo "$health_status" | jq -c '.issues')
    else
      issues=$(echo "$health_status" | grep -o '"issues":\[[^]]*\]' | cut -d':' -f2)
    fi
    
    # Check for specific issue types and address them
    if echo "$issues" | grep -q "interface"; then
      log "INFO" "Interface issues detected - checking and fixing VXLAN"
      check_and_fix_vxlan
    fi
    
    if echo "$issues" | grep -q "routes"; then
      log "INFO" "Route issues detected - verifying and updating routes"
      verify_routes
    fi
    
    if echo "$issues" | grep -q "traffic"; then
      log "INFO" "Traffic issues detected - cycling flannel interface"
      cycle_flannel_interface
    fi
  fi
}

# Function to report status to external systems
report_status() {
  # Only report if endpoint is configured
  if [ -z "$MONITORING_STATUS_ENDPOINT" ]; then
    return 0
  fi
  
  local health_status=$(get_health_status)
  
  # Add hostname and timestamp
  local hostname=$(hostname)
  local timestamp=$(date +%s)
  
  # Create report JSON
  local report_json=""
  if command -v jq &>/dev/null; then
    report_json=$(echo "$health_status" | jq --arg hostname "$hostname" --arg timestamp "$timestamp" '. + {reported_by: $hostname, timestamp: $timestamp|tonumber}')
  else
    # Simple string replacement for hosts without jq
    report_json=$(echo "$health_status" | sed 's/}$/,"reported_by":"'"$hostname"'","timestamp":'"$timestamp"'}/g')
  fi
  
  # Send to endpoint
  curl -s -X POST -H "Content-Type: application/json" -d "$report_json" "$MONITORING_STATUS_ENDPOINT" &>/dev/null || true
}
