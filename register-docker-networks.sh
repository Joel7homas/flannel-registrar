#!/bin/bash
# register-docker-networks.sh
# Main script for flannel-registrar
# Orchestrates the modular network management system

set -e

# ==========================================
# Configuration variables with defaults
# ==========================================

# Etcd configuration
ETCD_ENDPOINT="${ETCD_ENDPOINT:-http://192.168.4.88:2379}"
FLANNEL_PREFIX="${FLANNEL_PREFIX:-/coreos.com/network}"
FLANNEL_CONFIG_PREFIX="${FLANNEL_CONFIG_PREFIX:-/flannel/network}"
ETCDCTL_API="${ETCDCTL_API:-3}"  # Default to etcd v3 API

# Operation configuration
INTERVAL="${INTERVAL:-60}"  # Default interval in seconds
RUN_AS_ROOT="${RUN_AS_ROOT:-false}"
DEBUG="${DEBUG:-false}"  # Debug mode for verbose logging
VERSION="${VERSION:-1.1.0}"  # Default version if not set

# Network configuration
HOST_GATEWAY_MAP="${HOST_GATEWAY_MAP:-}"  # Format: "host1:gateway1,host2:gateway2,..."
FLANNEL_ROUTES_EXTRA="${FLANNEL_ROUTES_EXTRA:-}"  # Format: "subnet:gateway:interface,subnet:gateway:interface"
FLANNEL_CONTAINER_NAME="${FLANNEL_CONTAINER_NAME:-flannel}"

# Monitoring configuration
MONITORING_INTERVAL="${MONITORING_INTERVAL:-300}"  # Default 5 minutes between health checks
MONITORING_STATUS_ENDPOINT="${MONITORING_STATUS_ENDPOINT:-}"  # Optional HTTP endpoint to POST health updates

# Initialize timing variables
HOST_STATUS_LAST_UPDATE=0

# Global state paths
STATE_DIR="/var/run/flannel-registrar"
MODULE_DIR="/usr/local/lib/flannel-registrar"

# ==========================================
# Global variables and associative arrays
# ==========================================

# Global associative array for host gateway mappings
declare -A HOST_GATEWAYS

# Version of this script
SCRIPT_VERSION="1.1.0"

# ==========================================
# Basic logging function for early init
# Will be replaced by common.log
# ==========================================
_log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

  case $level in
    "DEBUG")
      # Only log DEBUG if debug mode is enabled
      if [ "$DEBUG" = "true" ]; then
        echo -e "[DEBUG] $timestamp - $message"
      fi
      ;;
    "INFO")
      echo -e "[INFO] $timestamp - $message"
      ;;
    "WARNING")
      echo -e "[WARNING] $timestamp - $message"
      ;;
    "ERROR")
      echo -e "[ERROR] $timestamp - $message"
      ;;
    *)
      echo "$timestamp - $message"
      ;;
  esac
}

# ==========================================
# Initialization functions
# ==========================================

migrate_host_status_data() {
    log "INFO" "Checking for host status data migration needs"
    
    # Check old paths
    local old_coreos_path="/coreos.com/network/subnets/_host_status/"
    local old_flannel_path="/flannel/network/subnets/_host_status/"
    local new_path="${FLANNEL_CONFIG_PREFIX}/subnets/_host_status/"
    
    # Skip if paths are the same
    if [ "$old_flannel_path" = "$new_path" ]; then
        log "DEBUG" "No migration needed - paths are identical"
        return 0
    fi
    
    # Migrate from old coreos path if data exists
    local count=0
    while read -r key; do
        if [ -n "$key" ]; then
            local host=$(basename "$key")
            local value=$(etcd_get "$key")
            if [ -n "$value" ]; then
                local new_key="${new_path}${host}"
                etcd_put "$new_key" "$value"
                log "INFO" "Migrated host status from $key to $new_key"
                count=$((count + 1))
            fi
        fi
    done < <(etcd_list_keys "$old_coreos_path" 2>/dev/null)
    
    # Migrate from old flannel path if data exists
    while read -r key; do
        if [ -n "$key" ]; then
            local host=$(basename "$key")
            local value=$(etcd_get "$key")
            if [ -n "$value" ]; then
                local new_key="${new_path}${host}"
                etcd_put "$new_key" "$value"
                log "INFO" "Migrated host status from $key to $new_key"
                count=$((count + 1))
            fi
        fi
    done < <(etcd_list_keys "$old_flannel_path" 2>/dev/null)
    
    if [ $count -gt 0 ]; then
        log "INFO" "Completed migration of $count host status entries"
    else
        log "DEBUG" "No host status entries needed migration"
    fi
}

# ==========================================
# Module management functions
# ==========================================

# Load a module by name
# Returns 0 if successful, 1 otherwise
load_module() {
  local module_name="$1"
  local module_path="${MODULE_DIR}/${module_name}.sh"
  
  _log "INFO" "Loading module: $module_name from $module_path"
  
  if [ -f "$module_path" ]; then
    # Source the module
    source "$module_path" || {
      _log "ERROR" "Failed to load module: $module_name"
      return 1
    }
    
    # Call module initialization function if it exists
    local init_func="init_${module_name//-/_}"
    if type "$init_func" &>/dev/null; then
      "$init_func" || {
        _log "ERROR" "Failed to initialize module: $module_name"
        return 1
      }
    fi
    
    _log "INFO" "Successfully loaded module: $module_name"
    return 0
  else
    _log "ERROR" "Module not found: $module_path"
    return 1
  fi
}

# Check if module dependencies are satisfied
# Returns 0 if all dependencies are loaded, 1 otherwise
check_module_dependencies() {
  local module_name="$1"
  local module_path="${MODULE_DIR}/${module_name}.sh"
  
  # Extract module dependencies
  if [ -f "$module_path" ]; then
    local dependencies=$(grep -o 'MODULE_DEPENDENCIES=([^)]*' "$module_path" | sed 's/MODULE_DEPENDENCIES=(//' | tr -d '"' | tr -d "'")
    
    if [ -n "$dependencies" ]; then
      for dep in $dependencies; do
        # Check if dependency init function exists
        local dep_init="init_${dep//-/_}"
        if ! type "$dep_init" &>/dev/null; then
          _log "ERROR" "Module $module_name requires $dep but it's not loaded"
          return 1
        fi
      done
    fi
  fi
  
  return 0
}

# ==========================================
# Basic host information functions
# ==========================================

# Determine hostname for this host
get_hostname() {
  if [[ "${HOST_NAME}" == "auto" || -z "${HOST_NAME}" ]]; then
    # Try to get hostname from mounted /etc/hostname first
    if [[ -f /etc/hostname ]]; then
      HOST_NAME=$(cat /etc/hostname | tr -d '\n')
      _log "INFO" "Using hostname from /etc/hostname: $HOST_NAME"
    else
      # Fallback to container's hostname
      HOST_NAME=$(hostname)
      _log "INFO" "Using container's hostname: $HOST_NAME"
    fi
  else
    _log "INFO" "Using provided hostname: $HOST_NAME"
  fi
  
  export HOST_NAME
}

# ==========================================
# Main application functions
# ==========================================

# Function to check dependencies
check_dependencies() {
  local missing=false
  
  for cmd in curl docker; do
    if ! command -v $cmd &> /dev/null; then
      _log "ERROR" "$cmd is required but not installed."
      missing=true
    fi
  done
  
  if $missing; then
    return 1
  fi

  # Check if we can access the Docker API
  if ! docker info &>/dev/null; then
    _log "WARNING" "Cannot access Docker API. Ensure the container has access to the Docker socket and appropriate permissions."
    _log "WARNING" "If running as non-root, ensure the user is in the docker group and the socket permissions are correct."
  fi
  
  return 0
}

# Function to get Docker networks information
get_docker_networks() {
  # First get all networks in JSON format
  local networks_json=$(get_networks_json)

  if [[ -z "$networks_json" ]]; then
    log "WARNING" "Could not list Docker networks. Check permissions."
    return 1
  fi

  # Create a temporary file for storing network information
  local tmp_file
  tmp_file=$(mktemp)

  # Process the JSON with jq to extract network names and subnets more reliably
  # If jq is not available, fall back to a simpler approach
  if command -v jq &>/dev/null; then
    echo "$networks_json" | jq -r '.[] |
      select(.Name != "bridge" and .Name != "host" and .Name != "none") |
      select(.IPAM.Config != null) |
      .Name as $name |
      .IPAM.Config[0].Subnet as $subnet |
      if $subnet then "'$HOST_NAME'/\($name)\t\($subnet)" else empty end' > "$tmp_file"
  else
    # Parse JSON manually (less reliable but doesn't require jq)
    while read -r line; do
      if [[ "$line" == *"\"Name\":"* ]]; then
        # Extract name
        name=$(echo "$line" | sed 's/.*"Name": *"\([^"]*\)".*/\1/')

        # Skip default networks
        if [[ "$name" == "bridge" || "$name" == "host" || "$name" == "none" ]]; then
          name=""
          continue
        fi
      fi

      if [[ -n "$name" && "$line" == *"\"Subnet\":"* ]]; then
        # Extract subnet
        subnet=$(echo "$line" | sed 's/.*"Subnet": *"\([^"]*\)".*/\1/')
        if [[ -n "$subnet" ]]; then
          # Write to temp file
          echo "${HOST_NAME}/${name}    ${subnet}" >> "$tmp_file"
          name=""
        fi
      fi
    done <<< "$(echo "$networks_json" | grep -E '("Name"|"Subnet")')"
  fi

  # Count networks
  local network_count
  network_count=$(wc -l < "$tmp_file")
  log "INFO" "Discovered $network_count Docker networks on $HOST_NAME"

  # Output the collected results
  cat "$tmp_file"
  rm -f "$tmp_file"
  
  return 0
}

# Function to get networks directly from docker
get_networks_json() {
  # Get all networks as JSON (no risk of log lines being included)
  docker network ls --format '{{.ID}}' | while read -r id; do
    docker network inspect "$id" 2>/dev/null
  done
}

# Stub function for parse_host_gateway_map
# Will be implemented in network-lib.sh
parse_host_gateway_map() {
  log "INFO" "Parsing host gateway map: $HOST_GATEWAY_MAP"
  
  if [ -n "$HOST_GATEWAY_MAP" ]; then
    # Split by comma
    IFS=',' read -ra MAPPINGS <<< "$HOST_GATEWAY_MAP"
    
    for mapping in "${MAPPINGS[@]}"; do
      # Split by colon
      IFS=':' read -r host gateway <<< "$mapping"
      
      if [ -n "$host" ] && [ -n "$gateway" ]; then
        HOST_GATEWAYS["$host"]="$gateway"
        log "INFO" "Added gateway mapping: $host via $gateway"
      fi
    done
  fi
  
  return 0
}

# Stub function for check_vxlan_interfaces
# Will be implemented in fdb-management.sh
check_vxlan_interfaces() {
  log "INFO" "Checking VXLAN interfaces..."
  return 0
}

# Stub function for ensure_flannel_iptables
# Will be implemented in routes.sh
ensure_flannel_iptables() {
  log "INFO" "Ensuring flannel iptables rules..."
  return 0
}

# Stub function for test_flannel_connectivity
# Will be implemented in connectivity.sh
test_flannel_connectivity() {
  local subnet="$1"
  local test_ip="$2"
  
  log "INFO" "Testing flannel connectivity to $subnet (via $test_ip)..."
  return 0
}

# Stub function for ensure_flannel_routes
# Will be implemented in routes.sh
ensure_flannel_routes() {
  log "INFO" "Ensuring flannel routes..."
  return 0
}

# Stub function for run_health_check
# Will be implemented in monitoring.sh
run_health_check() {
  log "INFO" "Running health check..."
  return 0
}

# Stub function for run_recovery_sequence
# Will be implemented in recovery.sh
run_recovery_sequence() {
  log "INFO" "Running recovery sequence..."
  return 0
}

# Stub function for update_fdb_entries_from_etcd
# Will be implemented in fdb-management.sh
update_fdb_entries_from_etcd() {
  log "INFO" "Updating FDB entries from etcd..."
  return 0
}

# ==========================================
# Main execution function
# ==========================================

# Main function to orchestrate flannel registration process
main() {
  _log "INFO" "Starting flannel-registrar v$SCRIPT_VERSION"
  _log "INFO" "Debug mode: $DEBUG"
  
  # Create state directory
  mkdir -p "$STATE_DIR" || {
    _log "ERROR" "Failed to create state directory: $STATE_DIR"
    exit 1
  }
  
  # Determine hostname
  get_hostname
  
  # Check dependencies
  check_dependencies || {
    _log "ERROR" "Failed dependency check"
    exit 1
  }
  
  # Load and initialize required modules
  _log "INFO" "Loading modules..."
  
  # Load modules in dependency order
  load_module "common" || exit 1
  load_module "etcd-lib" || exit 1
  
  # From here on, we can use the standardized logging from common.sh
  log "INFO" "Core modules loaded successfully"
  
  # Load remaining modules
  if [ -f "${MODULE_DIR}/network-lib.sh" ]; then
      load_module "network-lib" || exit 1
  else
      log "WARNING" "network-lib.sh not found, using stub functions"
      # Ensure host gateway map is parsed
      parse_host_gateway_map
  fi
  
  if [ -f "${MODULE_DIR}/recovery-host.sh" ]; then
      load_module "recovery-host" || exit 1
  else
      log "WARNING" "recovery-host.sh not found, using stub functions"
  fi

  log "INFO" "Loading remaining modules"
  
  # Load modules in dependency order
  # Routes modules
  if [ -f "${MODULE_DIR}/routes-core.sh" ]; then
      load_module "routes-core" || log "WARNING" "Failed to load routes-core module"
      
      if [ -f "${MODULE_DIR}/routes-advanced.sh" ]; then
          load_module "routes-advanced" || log "WARNING" "Failed to load routes-advanced module"
      fi
  fi
  
  # FDB management modules
  if [ -f "${MODULE_DIR}/fdb-core.sh" ]; then
      load_module "fdb-core" || log "WARNING" "Failed to load fdb-core module"
      
      if [ -f "${MODULE_DIR}/fdb-advanced.sh" ]; then
          load_module "fdb-advanced" || log "WARNING" "Failed to load fdb-advanced module"
      fi
      
      if [ -f "${MODULE_DIR}/fdb-diagnostics-core.sh" ]; then
          load_module "fdb-diagnostics-core" || log "WARNING" "Failed to load fdb-diagnostics-core module"
      fi
  fi
  
  # Connectivity modules
  if [ -f "${MODULE_DIR}/connectivity-core.sh" ]; then
      load_module "connectivity-core" || log "WARNING" "Failed to load connectivity-core module"
      
      if [ -f "${MODULE_DIR}/connectivity-diagnostics.sh" ]; then
          load_module "connectivity-diagnostics" || log "WARNING" "Failed to load connectivity-diagnostics module"
      fi
  fi
  
  # Monitoring modules
  if [ -f "${MODULE_DIR}/monitoring-core.sh" ]; then
      load_module "monitoring-core" || log "WARNING" "Failed to load monitoring-core module"
      
      if [ -f "${MODULE_DIR}/monitoring-network.sh" ]; then
          load_module "monitoring-network" || log "WARNING" "Failed to load monitoring-network module"
      fi
      
      if [ -f "${MODULE_DIR}/monitoring-reporting.sh" ]; then
          load_module "monitoring-reporting" || log "WARNING" "Failed to load monitoring-reporting module"
      fi
      
      if [ -f "${MODULE_DIR}/monitoring-system.sh" ]; then
          load_module "monitoring-system" || log "WARNING" "Failed to load monitoring-system module"
      fi
  fi
  
  # Recovery modules
  if [ -f "${MODULE_DIR}/recovery-state.sh" ]; then
      load_module "recovery-state" || log "WARNING" "Failed to load recovery-state module"
      
      if [ -f "${MODULE_DIR}/recovery-core.sh" ]; then
          load_module "recovery-core" || log "WARNING" "Failed to load recovery-core module"
          
          if [ -f "${MODULE_DIR}/recovery-actions.sh" ]; then
              load_module "recovery-actions" || log "WARNING" "Failed to load recovery-actions module"
          fi
          
          if [ -f "${MODULE_DIR}/recovery-monitoring.sh" ]; then
              load_module "recovery-monitoring" || log "WARNING" "Failed to load recovery-monitoring module"
          fi
      fi
  fi
  
  # Initialize etcd structure
  log "INFO" "Initializing etcd structure"
  initialize_etcd || {
    log "ERROR" "Failed to initialize etcd structure"
    exit 1
  }

  # Add migration call
  log "INFO" "Checking for subnet format migration"
  if type migrate_subnet_entries &>/dev/null; then
    migrate_subnet_entries || log "WARNING" "Subnet migration encountered issues"
  else
    log "WARNING" "migrate_subnet_entries function not available"
  fi

  # Register host status with VTEP MAC information in etcd
  log "INFO" "Registering host status in etcd"
  if type register_host_as_active &>/dev/null; then
      register_host_as_active || log "WARNING" "Failed to register host status, will retry later"
  elif type register_host_status &>/dev/null; then
      register_host_status || log "WARNING" "Failed to register host status"
  else
      log "ERROR" "Host status registration functions not available"
  fi
  
  # Clean up localhost entries in etcd
  log "INFO" "Cleaning up problematic etcd entries"
  log "DEBUG" "Calling cleanup_localhost_entries"
  cleanup_localhost_entries
  log "DEBUG" "Completed cleanup_localhost_entries"
  
  # Get Docker networks
  log "INFO" "Discovering Docker networks on $HOST_NAME"
  NETWORKS_OUTPUT=$(get_docker_networks)
  
  if [ -z "$NETWORKS_OUTPUT" ]; then
    log "WARNING" "No Docker networks found or could not access Docker API"
  else
    log "INFO" "Found Docker networks:\n$NETWORKS_OUTPUT"
    
    # Register networks in etcd
    log "INFO" "Registering Docker networks in etcd"
    
    echo "$NETWORKS_OUTPUT" | while read -r line; do
      if [ -n "$line" ]; then
        network_name=$(echo "$line" | awk '{print $1}')
        subnet=$(echo "$line" | awk '{print $2}')
        
        log "INFO" "Registering network $network_name with subnet $subnet"
        
        # Convert subnet to etcd key format (replace / with -)
        subnet_key=$(echo "$subnet" | sed 's/\//-/g')
        
        # Create backend data for the subnet
        public_ip="${FLANNELD_PUBLIC_IP:-$(hostname -I | awk '{print $1}')}"
        vtep_mac=$(cat /sys/class/net/flannel.1/address 2>/dev/null || echo "unknown")

        ### Format change required to correct connectivity ###
        #backend_data="{\"PublicIP\":\"$public_ip\",\"backend\":{\"type\":\"vxlan\",\"vtepMAC\":\"$vtep_mac\"},\"hostname\":\"$HOST_NAME\"}"
        backend_data="{\"PublicIP\":\"$public_ip\",\"PublicIPv6\":null,\"BackendType\":\"vxlan\",\"BackendData\":{\"VNI\":1,\"VtepMAC\":\"$vtep_mac\"}}"

        
        log "DEBUG" "Backend data: $backend_data"
        
        # Register in both prefixes

        # Only register flannel networks (10.5.x.x) in flannel's namespace
        if [[ "$subnet" =~ ^10\.5\. ]]; then
            log "INFO" "Registering flannel subnet $subnet in flannel namespace"
            etcd_put "${FLANNEL_PREFIX}/subnets/${subnet_key}" "$backend_data" || \
                log "ERROR" "Failed to register flannel subnet in ${FLANNEL_PREFIX}"
        else
            log "INFO" "Skipping registration of Docker network $subnet in flannel namespace"
        fi

        # Always register in our own namespace
        etcd_put "${FLANNEL_CONFIG_PREFIX}/subnets/${network_name}" "$subnet" || \
            log "ERROR" "Failed to register in ${FLANNEL_CONFIG_PREFIX}"

      fi
    done
    
    # Verify registered subnets
    log "INFO" "Verifying registered subnets in etcd"
    local registered_subnets=()
    while read -r key; do
        if [ -n "$key" ]; then
            registered_subnets+=("$key")
        fi
    done < <(etcd_list_keys "${FLANNEL_PREFIX}/subnets/")
    
    if [ ${#registered_subnets[@]} -gt 0 ]; then
        log "INFO" "Subnets registered in etcd: ${#registered_subnets[@]}"
    else
        log "WARNING" "No subnets found in etcd"
    fi
  fi

  migrate_host_status_data
  
  # Add routes for all subnets
  log "INFO" "Setting up routes to flannel subnets"
  ensure_flannel_routes || log "WARNING" "Failed to ensure all flannel routes"
  
  # Set up VXLAN FDB entries
  log "INFO" "Setting up VXLAN FDB entries"
  update_fdb_entries_from_etcd || log "WARNING" "Failed to update FDB entries"
  
  # Check flannel interface status
  log "INFO" "Checking flannel interface status"
  check_vxlan_interfaces || log "WARNING" "Issues detected with VXLAN interfaces"
  
  # Ensure iptables rules for flannel
  log "INFO" "Ensuring iptables rules for flannel"
  ensure_flannel_iptables || log "WARNING" "Failed to ensure flannel iptables rules"
  
  # Run initial health check
  log "INFO" "Running initial health check"
  run_health_check || log "WARNING" "Health check detected issues"
  
  # If not running in daemon mode, exit here
  if [ "$1" == "--once" ]; then
    log "INFO" "Running in one-shot mode, exiting"
    exit 0
  fi
  
  # Main loop for daemon mode
  log "INFO" "Entering daemon mode with interval ${INTERVAL}s"
  while true; do
    log "DEBUG" "Starting iteration of main loop"
    
    # Periodically update host status
    HOST_STATUS_UPDATE_INTERVAL=${HOST_STATUS_UPDATE_INTERVAL:-300} # 5 minutes default
    HOST_STATUS_LAST_UPDATE=${HOST_STATUS_LAST_UPDATE:-0}
    current_time=$(date +%s)

    if [ $((current_time - HOST_STATUS_LAST_UPDATE)) -gt $HOST_STATUS_UPDATE_INTERVAL ]; then
        log "DEBUG" "Updating host status registration"
        if type register_host_status &>/dev/null; then
            register_host_status
            HOST_STATUS_LAST_UPDATE=$current_time
        fi
    fi

    # Update routes for all subnets
    ensure_flannel_routes || log "WARNING" "Failed to update flannel routes"
    
    # Update FDB entries
    update_fdb_entries_from_etcd || log "WARNING" "Failed to update FDB entries"
    
    # Run health check
    run_health_check || {
      log "WARNING" "Health check detected issues, attempting recovery"
      run_recovery_sequence
    }
    
    # Periodically update host status
    HOST_STATUS_UPDATE_INTERVAL=${HOST_STATUS_UPDATE_INTERVAL:-300} # 5 minutes default
    HOST_STATUS_LAST_UPDATE=${HOST_STATUS_LAST_UPDATE:-0}
    current_time=$(date +%s)
    
    if [ $((current_time - HOST_STATUS_LAST_UPDATE)) -gt $HOST_STATUS_UPDATE_INTERVAL ]; then
        log "DEBUG" "Updating host status registration"
        if type refresh_host_status &>/dev/null; then
            refresh_host_status && HOST_STATUS_LAST_UPDATE=$current_time
        elif type register_host_status &>/dev/null; then
            register_host_status && HOST_STATUS_LAST_UPDATE=$current_time
        fi
    fi

    log "DEBUG" "Sleeping for ${INTERVAL} seconds"
    sleep $INTERVAL
  done
}

# ==========================================
# Diagnostic mode function
# ==========================================

run_diagnostics() {
  _log "INFO" "Running diagnostics for flannel-registrar"
  
  # Basic system information
  echo "=== System Information ==="
  echo "Hostname: $(hostname)"
  echo "Host IP: $(hostname -I)"
  echo "Kernel: $(uname -r)"
  echo ""
  
  # Check Docker
  echo "=== Docker Status ==="
  if command -v docker &>/dev/null; then
    echo "Docker installed: Yes"
    if docker info &>/dev/null; then
      echo "Docker running: Yes"
      echo "Docker networks:"
      docker network ls
    else
      echo "Docker running: No"
    fi
  else
    echo "Docker installed: No"
  fi
  echo ""
  
  # Check etcd
  echo "=== Etcd Status ==="
  echo "Etcd endpoint: $ETCD_ENDPOINT"
  if curl -s "${ETCD_ENDPOINT}/health" | grep -q "true"; then
    echo "Etcd accessible: Yes"
  else
    echo "Etcd accessible: No"
  fi
  echo ""
  
  # Check network interfaces
  echo "=== Network Interfaces ==="
  ip addr show
  echo ""
  
  # Check routes
  echo "=== Routing Table ==="
  ip route show
  echo ""
  
  # Check flannel interface
  echo "=== Flannel Interface ==="
  if ip link show flannel.1 &>/dev/null; then
    echo "Flannel interface exists: Yes"
    ip link show flannel.1
    echo "FDB entries:"
    bridge fdb show dev flannel.1
  else
    echo "Flannel interface exists: No"
  fi
  echo ""
  
  # Check for flannel container
  echo "=== Flannel Container ==="
  if docker ps --filter name="$FLANNEL_CONTAINER_NAME" | grep -q "$FLANNEL_CONTAINER_NAME"; then
    echo "Flannel container running: Yes"
    docker ps --filter name="$FLANNEL_CONTAINER_NAME"
  else
    echo "Flannel container running: No"
  fi
  echo ""
  
  # Exit diagnostics mode
  _log "INFO" "Diagnostics completed"
  exit 0
}

# ==========================================
# Script execution with argument handling
# ==========================================

# Check for command line arguments
if [ "$1" = "--help" ]; then
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  --once          Run once and exit"
  echo "  --diagnose      Run diagnostics and exit"
  echo "  --help          Show this help message"
  exit 0
fi

if [ "$1" = "--diagnose" ]; then
  run_diagnostics
fi

# Main execution entry point
main "$@"
