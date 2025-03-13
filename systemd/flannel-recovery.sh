#!/bin/bash
# flannel-recovery.sh
# Host-level recovery script for flannel networking issues
# Designed to run as a systemd service

set -e

# Logging function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
  logger -t flannel-recovery "$@"
}

# Configuration
STATE_DIR="/var/lib/flannel-recovery"
LOCK_FILE="$STATE_DIR/recovery.lock"
RECOVERY_HISTORY_FILE="$STATE_DIR/recovery_history.log"
MAX_RECOVERY_ATTEMPTS=3
RECOVERY_COOLDOWN=1800  # 30 minutes between recovery attempts
FLANNEL_INTERFACE="flannel.1"
FLANNEL_CONTAINER_NAME="flannel"
FLANNEL_REGISTRAR_CONTAINER_NAME="flannel-registrar"
DOCKER_MTU=1370
ETCD_ENDPOINT=${ETCD_ENDPOINT:-"http://192.168.4.88:2379"}
HOST_GATEWAY_MAP=${HOST_GATEWAY_MAP:-""}  # Format: "host1:gateway1,host2:gateway2,..."

# Create state directory
mkdir -p "$STATE_DIR"

# Function to check if recovery is needed
check_recovery_needed() {
  log "Checking if flannel recovery is needed"
  
  # Check 1: Docker service status
  if ! systemctl is-active --quiet docker; then
    log "Docker service is not running"
    return 0
  fi
  
  # Check 2: Flannel interface exists
  if ! ip link show "$FLANNEL_INTERFACE" &>/dev/null; then
    log "Flannel interface $FLANNEL_INTERFACE is missing"
    return 0
  fi
  
  # Check 3: Flannel container is running
  if ! docker ps --filter name="$FLANNEL_CONTAINER_NAME" | grep -q "$FLANNEL_CONTAINER_NAME"; then
    log "Flannel container is not running"
    return 0
  fi
  
  # Check 4: Connectivity to other hosts
  log "Checking connectivity to other flannel hosts"
  
  # Get a list of subnets from etcd
  local etcd_output=$(curl -s "$ETCD_ENDPOINT/v3/kv/range" -X POST -d '{"key":"L2NvcmVvcy5jb20vbmV0d29yay9zdWJuZXRz"}' | jq -r 2>/dev/null || echo "")
  
  if [ -z "$etcd_output" ]; then
    log "Could not get subnet information from etcd"
    # Don't trigger recovery just because etcd is unavailable
    return 1
  fi
  
  local connectivity_issues=0
  local subnets_tested=0
  
  # Parse subnet keys and test connectivity
  echo "$etcd_output" | grep -o '"key":"[^"]*"' | cut -d'"' -f4 | while read -r key_b64; do
    if [ -z "$key_b64" ]; then
      continue
    fi
    
    local subnet_key=$(echo "$key_b64" | base64 -d 2>/dev/null)
    if [[ "$subnet_key" == *"subnets"* ]]; then
      local subnet_id=$(basename "$subnet_key")
      local cidr_subnet=$(echo "$subnet_id" | sed 's/-/\//g')
      
      # Skip our own subnet
      if ip route show | grep -q "$cidr_subnet.*dev $FLANNEL_INTERFACE"; then
        continue
      fi
      
      # Get the first usable IP in the subnet for testing
      local subnet_base=$(echo "$cidr_subnet" | cut -d'/' -f1)
      local test_ip="${subnet_base%.*}.$((${subnet_base##*.} + 1))"
      
      subnets_tested=$((subnets_tested + 1))
      
      # Test ping with short timeout
      if ! ping -c 1 -W 2 "$test_ip" &>/dev/null; then
        log "Cannot reach flannel subnet $cidr_subnet (test IP: $test_ip)"
        connectivity_issues=$((connectivity_issues + 1))
      fi
    fi
  done
  
  if [ $subnets_tested -gt 0 ] && [ $connectivity_issues -eq $subnets_tested ]; then
    log "All flannel subnets ($subnets_tested) are unreachable"
    return 0
  fi
  
  # If we get here, recovery is not needed
  log "Recovery is not needed - flannel appears to be functioning"
  return 1
}

# Function to check if recovery is allowed (cooldown and attempt limits)
recovery_allowed() {
  # Check for lock file
  if [ -f "$LOCK_FILE" ]; then
    local last_recovery=$(cat "$LOCK_FILE")
    local current_time=$(date +%s)
    local time_since_recovery=$((current_time - last_recovery))
    
    if [ $time_since_recovery -lt $RECOVERY_COOLDOWN ]; then
      log "Recovery cooldown period still active ($(($RECOVERY_COOLDOWN - time_since_recovery)) seconds remaining)"
      return 1
    fi
  fi
  
  # Check number of recent recovery attempts
  local today=$(date +%Y-%m-%d)
  local today_attempts=0
  
  if [ -f "$RECOVERY_HISTORY_FILE" ]; then
    today_attempts=$(grep "$today" "$RECOVERY_HISTORY_FILE" | wc -l)
  fi
  
  if [ $today_attempts -ge $MAX_RECOVERY_ATTEMPTS ]; then
    log "Maximum recovery attempts ($MAX_RECOVERY_ATTEMPTS) for today already reached"
    return 1
  fi
  
  return 0
}
