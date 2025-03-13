#!/bin/bash
# flannel-boot.sh
# Host-level setup script for flannel networking on system boot
# Designed to run as a systemd service before Docker starts

set -e

# Logging function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
  logger -t flannel-boot "$@"
}

# Configuration
FLANNEL_MTU=1370
FLANNEL_INTERFACE="flannel.1"
STATE_DIR="/var/lib/flannel-boot"
BOOT_TIMESTAMP_FILE="$STATE_DIR/boot_timestamp"
HOST_GATEWAY_MAP=${HOST_GATEWAY_MAP:-""}  # Format: "host1:gateway1,host2:gateway2,..."
FLANNEL_ROUTES_EXTRA=${FLANNEL_ROUTES_EXTRA:-""}  # Format: "subnet:gateway:interface,subnet:gateway:interface"

# Create state directory
mkdir -p "$STATE_DIR"

# Record boot timestamp
date +%s > "$BOOT_TIMESTAMP_FILE"

# Function to prepare network environment for flannel
prepare_network() {
  log "Preparing network environment for flannel"
  
  # Step 1: Enable IP forwarding
  log "Enabling IP forwarding"
  sysctl -w net.ipv4.ip_forward=1
  echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ip-forward.conf
  
  # Step 2: Disable reverse path filtering
  log "Disabling reverse path filtering"
  sysctl -w net.ipv4.conf.all.rp_filter=0
  sysctl -w net.ipv4.conf.default.rp_filter=0
  echo "net.ipv4.conf.all.rp_filter = 0" > /etc/sysctl.d/99-rp-filter.conf
  echo "net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.d/99-rp-filter.conf
  
  # Step 3: Clean up stale ARP entries 
  log "Cleaning up stale ARP entries"
  ip neigh flush all
  
  # Step 4: Add base iptables rules if none exist
  if ! iptables -L FLANNEL-FWD &>/dev/null; then
    log "Setting up base iptables rules for flannel"
    iptables -N FLANNEL-FWD 2>/dev/null || true
    iptables -A FLANNEL-FWD -s 10.5.0.0/16 -j ACCEPT
    iptables -A FLANNEL-FWD -d 10.5.0.0/16 -j ACCEPT
    
    # Add to FORWARD chain if not already there
    if ! iptables -L FORWARD | grep -q "FLANNEL-FWD"; then
      iptables -A FORWARD -j FLANNEL-FWD
    fi
    
    # Add masquerade rule
    if ! iptables -t nat -L POSTROUTING | grep -q "10.5.0.0/16"; then
      iptables -t nat -A POSTROUTING -s 10.5.0.0/16 ! -d 10.5.0.0/16 -j MASQUERADE
    fi
  fi
  
  # Step D: Ensure WireGuard routes are set up if needed
  set_up_wireguard_routes
}

# Function to set up WireGuard routes if needed
set_up_wireguard_routes() {
  log "Setting up WireGuard routes if needed"
  
  # Check if any wireguard interfaces exist
  local wg_interfaces=$(ip link show | grep -o 'wg[0-9]*')
  
  if [ -z "$wg_interfaces" ]; then
    log "No WireGuard interfaces found"
    return
  fi
  
  log "Found WireGuard interfaces: $wg_interfaces"
  
  # Set up routes for 172.24.90.0/24 network via WireGuard
  local wg_ip=$(ip addr show | grep -o 'inet 172\.24\.90\.[0-9]*/[0-9]*')
  
  if [ -n "$wg_ip" ]; then
    local our_wg_ip=$(echo "$wg_ip" | cut -d'/' -f1 | cut -d' ' -f2)
    log "Found WireGuard IP: $our_wg_ip"
    
    # Set up routes based on HOST_GATEWAY_MAP
    if [ -n "$HOST_GATEWAY_MAP" ]; then
      log "Setting up routes from HOST_GATEWAY_MAP: $HOST_GATEWAY_MAP"
      
      # Split by comma
      IFS=',' read -ra MAPPINGS <<< "$HOST_GATEWAY_MAP"
      
      for mapping in "${MAPPINGS[@]}"; do
        # Split by colon
        IFS=':' read -r host gateway <<< "$mapping"
        
        if [ -n "$host" ] && [ -n "$gateway" ]; then
          # Add host route
          log "Adding route: $host via $gateway"
          ip route replace "$host" via "$gateway"
        fi
      done
    fi
  fi
  
  # Add extra routes if specified
  if [ -n "$FLANNEL_ROUTES_EXTRA" ]; then
    log "Adding extra routes: $FLANNEL_ROUTES_EXTRA"
    
    # Split by comma
    IFS=',' read -ra ROUTES <<< "$FLANNEL_ROUTES_EXTRA"
    
    for route in "${ROUTES[@]}"; do
      # Split by colon
      IFS=':' read -r subnet gateway interface <<< "$route"
      
      if [ -n "$subnet" ] && [ -n "$gateway" ]; then
        if [ -n "$interface" ]; then
          log "Adding route: $subnet via $gateway dev $interface"
          ip route replace "$subnet" via "$gateway" dev "$interface" || true
        else
          log "Adding route: $subnet via $gateway"
          ip route replace "$subnet" via "$gateway" || true
        fi
      fi
    done
  fi
}

# Function to clean up stale network state
clean_stale_network_state() {
  log "Cleaning up stale network state"
  
  # Step 1: Remove any stale flannel interface
  if ip link show | grep -q flannel; then
    log "Removing stale flannel interfaces"
    ip link show | grep -o 'flannel[^ ]*' | while read -r iface; do
      ip link delete "$iface" 2>/dev/null || true
    done
  fi
  
  # Step 2: Clean up Docker bridge networks that might conflict
  if command -v docker &>/dev/null && systemctl is-active --quiet docker; then
    log "Checking for conflicting Docker bridge networks"
    
    docker network ls --format '{{.Name}}' | grep -v 'host\|none' | while read -r network; do
      local subnet=$(docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
      
      if [[ "$subnet" == 10.5.* ]]; then
        log "Found potentially conflicting Docker network: $network ($subnet)"
        # Note: We're just logging but not removing these networks, as that would be disruptive
      fi
    done
  fi
  
  # Step 3: Clean up stale routes
  log "Cleaning up stale 10.5.0.0/16 routes"
  ip route show | grep '^10\.5\.' | while read -r route; do
    log "Removing stale route: $route"
    ip route del $(echo "$route" | awk '{print $1}') 2>/dev/null || true
  done
}

# Main function
main() {
  log "Starting flannel boot setup"
  
  # Clean up stale network state first
  clean_stale_network_state
  
  # Prepare network environment
  prepare_network
  
  log "Flannel boot setup completed"
}

# Run main function
main "$@"
exit 0
