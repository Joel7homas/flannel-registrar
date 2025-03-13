#!/bin/bash
# recovery-actions.sh
# Specific recovery action implementations for flannel-registrar self-healing
# Part of the minimalist multi-module recovery system

# Module information
MODULE_NAME="recovery-actions"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "recovery-state" "network-lib")

# ==========================================
# Global variables for recovery actions
# ==========================================

# Container-related configuration
FLANNEL_CONTAINER_NAME=${FLANNEL_CONTAINER_NAME:-"flannel"}
DOCKER_RESTART_TIMEOUT=${DOCKER_RESTART_TIMEOUT:-60}  # Maximum seconds to wait for container restart
CONTAINER_HEALTH_TIMEOUT=${CONTAINER_HEALTH_TIMEOUT:-30}  # Seconds to wait for container health check

# Host delegation configuration
HOST_SYSTEMD_SERVICE=${HOST_SYSTEMD_SERVICE:-"flannel-recovery.service"}
HOST_SCRIPT_PATH=${HOST_SCRIPT_PATH:-"/usr/local/bin/flannel-recovery.sh"}
HOST_ACTION_TIMEOUT=${HOST_ACTION_TIMEOUT:-120}  # Maximum seconds to wait for host action

# ==========================================
# Module initialization
# ==========================================

# Initialize recovery actions module
# Usage: init_recovery_actions
# Returns: 0 on success, 1 on failure
init_recovery_actions() {
    # Check dependencies
    for dep in "${MODULE_DEPENDENCIES[@]}"; do
        # Convert module name (with dash) to init function name (with underscore)
        local init_func="init_${dep//-/_}"
        if ! type "$init_func" &>/dev/null; then
            echo "ERROR: Required dependency '$dep' is not loaded. Make sure all dependencies are initialized."
            return 1
        fi
    done
    
    # Check for required commands
    local required_commands=("docker" "grep" "awk" "timeout")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "WARNING" "Command '$cmd' not found. Some recovery actions may not function properly."
        fi
    done
    
    log "INFO" "Initialized recovery-actions module (v${MODULE_VERSION})"
    return 0
}

# ==========================================
# Environment detection functions
# ==========================================

# Check if running in a container environment
# Usage: is_running_in_container
# Returns: 0 if running in container, 1 if running on host
is_running_in_container() {
    # Multiple checks for container detection
    
    # Check for .dockerenv file
    if [ -f "/.dockerenv" ]; then
        return 0
    fi
    
    # Check for docker cgroup
    if grep -q docker /proc/self/cgroup 2>/dev/null; then
        return 0
    fi
    
    # Check for container specific environment variables
    if [ -n "$KUBERNETES_SERVICE_HOST" ] || [ -n "$DOCKER_CONTAINER" ]; then
        return 0
    fi
    
    # Check if hostname matches a container ID format (hex string)
    local hostname=$(hostname)
    if [[ "$hostname" =~ ^[a-f0-9]{12}$ ]] || [[ "$hostname" =~ ^[a-f0-9]{64}$ ]]; then
        return 0
    fi
    
    # Not in a container
    return 1
}

# ==========================================
# Container management functions
# ==========================================

# Find the flannel container ID
# Usage: find_flannel_container
# Returns: Container ID on success, empty string on failure
find_flannel_container() {
    # Find running containers matching the flannel container name pattern
    local container_id=""
    
    # Try exact name match first
    container_id=$(docker ps --filter "name=^/${FLANNEL_CONTAINER_NAME}$" --format "{{.ID}}" 2>/dev/null | head -1)
    
    # If not found, try partial name match
    if [ -z "$container_id" ]; then
        container_id=$(docker ps --filter "name=${FLANNEL_CONTAINER_NAME}" --format "{{.ID}}" 2>/dev/null | head -1)
    fi
    
    # If still not found, look for flannel image
    if [ -z "$container_id" ]; then
        container_id=$(docker ps --filter "ancestor=quay.io/coreos/flannel" --format "{{.ID}}" 2>/dev/null | head -1)
        
        # Check other common flannel repositories
        if [ -z "$container_id" ]; then
            container_id=$(docker ps --filter "ancestor=flannelcni/flannel" --format "{{.ID}}" 2>/dev/null | head -1)
        fi
    fi
    
    # Log the result
    if [ -n "$container_id" ]; then
        log "DEBUG" "Found flannel container: $container_id"
    else
        log "WARNING" "No running flannel container found"
    fi
    
    echo "$container_id"
    return 0
}

# Get detailed status of a container
# Usage: get_container_status container_id
# Arguments:
#   container_id - Docker container ID or name
# Returns: Container status information as key-value pairs
get_container_status() {
    local container_id="$1"
    local status_output=""
    
    # Verify container ID provided
    if [ -z "$container_id" ]; then
        log "ERROR" "No container ID provided to get_container_status"
        echo "status:error"
        return 1
    fi
    
    # Check if container exists
    if ! docker inspect "$container_id" &>/dev/null; then
        log "ERROR" "Container $container_id not found"
        echo "status:not_found"
        return 1
    fi
    
    # Get basic container info
    local state=$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null || echo "unknown")
    local running=$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || echo "false")
    local health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || echo "none")
    local restarts=$(docker inspect --format '{{.RestartCount}}' "$container_id" 2>/dev/null || echo "0")
    local start_time=$(docker inspect --format '{{.State.StartedAt}}' "$container_id" 2>/dev/null || echo "unknown")
    
    # Format start time to timestamp if possible
    if [[ "$start_time" != "unknown" ]]; then
        local start_timestamp=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
        local current_time=$(date +%s)
        local uptime=$((current_time - start_timestamp))
        
        status_output+="uptime:$uptime\n"
    fi
    
    # Build status output
    status_output+="state:$state\n"
    status_output+="running:$running\n"
    status_output+="health:$health\n"
    status_output+="restarts:$restarts\n"
    
    # Check if the container has recently restarted (potential flapping)
    if [ "$uptime" -lt 300 ] && [ "$restarts" -gt 2 ]; then
        status_output+="flapping:true\n"
    else
        status_output+="flapping:false\n"
    fi
    
    # Get container's network mode
    local network_mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$container_id" 2>/dev/null || echo "unknown")
    status_output+="network_mode:$network_mode\n"
    
    # Check if container has the expected capabilities (NET_ADMIN for flannel)
    local caps=$(docker inspect --format '{{range .HostConfig.CapAdd}}{{.}} {{end}}' "$container_id" 2>/dev/null || echo "")
    if [[ "$caps" == *"NET_ADMIN"* ]]; then
        status_output+="net_admin:true\n"
    else
        status_output+="net_admin:false\n"
    fi
    
    echo -e "$status_output"
    return 0
}

# Check health status of a container
# Usage: check_container_health container_id
# Arguments:
#   container_id - Docker container ID or name
# Returns: 0 if healthy, 1 if unhealthy
check_container_health() {
    local container_id="$1"
    
    # Verify container ID provided
    if [ -z "$container_id" ]; then
        log "ERROR" "No container ID provided to check_container_health"
        return 1
    fi
    
    # Get container status
    local container_status=$(get_container_status "$container_id")
    
    # Parse status
    local state=$(echo "$container_status" | grep "^state:" | cut -d':' -f2)
    local running=$(echo "$container_status" | grep "^running:" | cut -d':' -f2)
    local health=$(echo "$container_status" | grep "^health:" | cut -d':' -f2)
    local flapping=$(echo "$container_status" | grep "^flapping:" | cut -d':' -f2)
    
    # Check for flapping container
    if [ "$flapping" = "true" ]; then
        log "WARNING" "Container $container_id appears to be flapping (frequent restarts)"
        return 1
    fi
    
    # Basic state check
    if [ "$state" != "running" ] || [ "$running" != "true" ]; then
        log "WARNING" "Container $container_id is not running (state: $state)"
        return 1
    fi
    
    # Health check if available
    if [ "$health" != "none" ] && [ "$health" != "healthy" ]; then
        log "WARNING" "Container $container_id health check: $health"
        return 1
    fi
    
    # Flannel-specific checks
    # 1. Check if flannel interface exists
    if ! ip link show flannel.1 &>/dev/null; then
        log "WARNING" "Flannel interface flannel.1 missing despite running container"
        return 1
    fi
    
    # 2. Check if container responds to basic commands
    if ! timeout 5 docker exec "$container_id" ls /etc/flannel &>/dev/null; then
        log "WARNING" "Container $container_id not responding to basic commands"
        return 1
    fi
    
    # Container is healthy
    log "DEBUG" "Container $container_id is healthy"
    return 0
}

# Restart the flannel container
# Usage: restart_flannel_container
# Returns: 0 on success, 1 on failure
restart_flannel_container() {
    # Find flannel container
    local container_id=$(find_flannel_container)
    
    if [ -z "$container_id" ]; then
        log "ERROR" "Cannot restart flannel container: no container found"
        return 1
    fi
    
    log "INFO" "Restarting flannel container: $container_id"
    
    # Get current container status before restart for comparison
    local pre_restart_status=$(get_container_status "$container_id")
    
    # Restart the container with timeout
    if ! timeout $DOCKER_RESTART_TIMEOUT docker restart "$container_id"; then
        log "ERROR" "Failed to restart container $container_id: timeout after $DOCKER_RESTART_TIMEOUT seconds"
        return 1
    fi
    
    # Wait for container to start
    log "INFO" "Waiting for container to start and stabilize"
    sleep 5
    
    # Check if container is running
    if ! docker ps -q --filter "id=$container_id" | grep -q .; then
        log "ERROR" "Container $container_id failed to start after restart"
        return 1
    fi
    
    # Wait for container to become healthy
    local health_check_attempts=0
    local max_attempts=$((CONTAINER_HEALTH_TIMEOUT / 5))  # Check every 5 seconds
    
    while [ $health_check_attempts -lt $max_attempts ]; do
        if check_container_health "$container_id"; then
            # Update cooldown timestamp via recovery-state.sh
            if ! update_cooldown_timestamp "recovery_${RECOVERY_LEVEL_CONTAINER}"; then
                log "WARNING" "Failed to update cooldown timestamp for container recovery"
            fi
            
            # Container is healthy, collect diagnostics for verification
            local diag=$(collect_action_diagnostics "container_restart" "$container_id")
            log "INFO" "Successfully restarted container $container_id"
            log "DEBUG" "Post-restart diagnostics:\n$diag"
            
            # Record the success in recovery state
            if ! save_recovery_attempt "container" "restart" "success" "Container $container_id restarted successfully"; then
                log "WARNING" "Failed to save recovery attempt state, continuing anyway"
            fi
            
            return 0
        fi
        
        health_check_attempts=$((health_check_attempts + 1))
        sleep 5
    done
    
    # Container did not become healthy in time
    log "ERROR" "Container $container_id not healthy after restart (timeout: $CONTAINER_HEALTH_TIMEOUT seconds)"
    
    # Record the failure in recovery state
    if ! save_recovery_attempt "container" "restart" "failure" "Container $container_id failed to become healthy after restart"; then
        log "WARNING" "Failed to save recovery attempt state, continuing anyway"
    fi
    
    return 1
}

# ==========================================
# Host delegation and service management
# ==========================================

# Delegate an action to the host system
# Usage: delegate_host_action action [args...]
# Arguments:
#   action - Action to delegate (restart_service, reload_config, etc.)
#   args - Additional arguments for the action
# Returns: 0 on success, 1 on failure
delegate_host_action() {
    local action="$1"
    shift  # Remove action from arguments, leaving remaining args
    
    # Check if running in a container
    if ! is_running_in_container; then
        log "INFO" "Not running in a container, executing action directly"
        
        # Execute the action directly based on the action type
        case "$action" in
            "restart_service")
                local service_name="$1"
                log "INFO" "Directly restarting service: $service_name"
                
                if command -v systemctl &>/dev/null; then
                    if ! systemctl restart "$service_name"; then
                        log "ERROR" "Failed to restart service $service_name"
                        return 1
                    fi
                else
                    log "ERROR" "systemctl command not available"
                    return 1
                fi
                ;;
                
            "reload_config")
                log "INFO" "Directly reloading configuration"
                
                if command -v systemctl &>/dev/null; then
                    systemctl daemon-reload
                    log "INFO" "Configuration reloaded"
                else
                    log "ERROR" "systemctl command not available"
                    return 1
                fi
                ;;
                
            *)
                log "ERROR" "Unknown host action: $action"
                return 1
                ;;
        esac
        
        return 0
    fi
    
    log "INFO" "Running in a container, delegating host action: $action"
    
    # Method 1: Use systemd service if available
    if [ -n "$HOST_SYSTEMD_SERVICE" ]; then
        log "INFO" "Attempting to use systemd service for delegation: $HOST_SYSTEMD_SERVICE"
        
        # Check if host path is accessible via volume mount
        if [ -e "/host/bin/systemctl" ]; then
            log "INFO" "Using host systemctl via volume mount"
            
            if ! /host/bin/systemctl start "$HOST_SYSTEMD_SERVICE" "--" "$action" "$@"; then
                log "WARNING" "Failed to delegate via host systemctl"
            else
                log "INFO" "Successfully delegated action via host systemctl"
                return 0
            fi
        fi
        
        # Try nsenter if available
        if command -v nsenter &>/dev/null; then
            log "INFO" "Attempting to use nsenter for host delegation"
            
            if ! nsenter -m -u -i -n -p -t 1 systemctl start "$HOST_SYSTEMD_SERVICE" "--" "$action" "$@"; then
                log "WARNING" "Failed to delegate via nsenter"
            else
                log "INFO" "Successfully delegated action via nsenter"
                return 0
            fi
        fi
    fi
    
    # Method 2: Use Docker to run a privileged container that can access the host
    log "INFO" "Falling back to privileged container for host delegation"
    
    local docker_cmd="docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest"
    local host_cmd=""
    
    case "$action" in
        "restart_service")
            local service_name="$1"
            host_cmd="chroot /host /bin/sh -c 'systemctl restart $service_name'"
            ;;
            
        "reload_config")
            host_cmd="chroot /host /bin/sh -c 'systemctl daemon-reload'"
            ;;
            
        *)
            log "ERROR" "Unknown host action for container delegation: $action"
            return 1
            ;;
    esac
    
    if [ -n "$host_cmd" ]; then
        if ! eval "$docker_cmd $host_cmd"; then
            log "ERROR" "Failed to execute host action via privileged container"
            return 1
        fi
        
        log "INFO" "Successfully executed host action via privileged container"
        return 0
    fi
    
    log "ERROR" "All delegation methods failed for action: $action"
    return 1
}

# Restart Docker service
# Usage: restart_docker_service
# Returns: 0 on success, 1 on failure
restart_docker_service() {
    log "WARNING" "Docker service restart is a disruptive operation"
    
    # Record the attempt in recovery state
    if ! save_recovery_attempt "service" "restart_docker" "attempted" "Docker service restart attempted"; then
        log "WARNING" "Failed to save recovery attempt state, continuing anyway"
    fi
    
    # Get list of running containers before restart for comparison
    local containers_before=""
    if command -v docker &>/dev/null; then
        containers_before=$(docker ps -q 2>/dev/null || echo "")
    fi
    
    # If running in a container, must delegate to host
    if is_running_in_container; then
        log "INFO" "Attempting to restart Docker service via host delegation"
        
        if ! delegate_host_action "restart_service" "docker"; then
            log "ERROR" "Failed to restart Docker service via host delegation"
            
            # Record the failure in recovery state
            if ! save_recovery_attempt "service" "restart_docker" "failure" "Failed to restart Docker service via host delegation"; then
                log "WARNING" "Failed to save recovery attempt state, continuing anyway"
            fi
            
            return 1
        fi
    else
        # Direct restart on host
        log "INFO" "Directly restarting Docker service"
        
        if command -v systemctl &>/dev/null; then
            # First try systemd
            if ! systemctl restart docker; then
                log "ERROR" "Failed to restart Docker service with systemctl"
                
                # Record the failure in recovery state
                if ! save_recovery_attempt "service" "restart_docker" "failure" "Failed to restart Docker service with systemctl"; then
                    log "WARNING" "Failed to save recovery attempt state, continuing anyway"
                fi
                
                return 1
            fi
        elif command -v service &>/dev/null; then
            # Try service command as fallback
            if ! service docker restart; then
                log "ERROR" "Failed to restart Docker service with service command"
                
                # Record the failure in recovery state
                if ! save_recovery_attempt "service" "restart_docker" "failure" "Failed to restart Docker service with service command"; then
                    log "WARNING" "Failed to save recovery attempt state, continuing anyway"
                fi
                
                return 1
            fi
        else
            log "ERROR" "No method available to restart Docker service"
            
            # Record the failure in recovery state
            if ! save_recovery_attempt "service" "restart_docker" "failure" "No method available to restart Docker service"; then
                log "WARNING" "Failed to save recovery attempt state, continuing anyway"
            fi
            
            return 1
        fi
    fi
    
    # Wait for Docker to become available
    log "INFO" "Waiting for Docker service to become available"
    local wait_time=0
    local max_wait=120  # Maximum 2 minutes wait
    
    while [ $wait_time -lt $max_wait ]; do
        if docker info &>/dev/null; then
            log "INFO" "Docker service is now available"
            break
        fi
        
        sleep 5
        wait_time=$((wait_time + 5))
    done
    
    if [ $wait_time -ge $max_wait ]; then
        log "ERROR" "Docker service did not become available after restart within timeout"
        
        # Record the failure in recovery state
        if ! save_recovery_attempt "service" "restart_docker" "failure" "Docker service did not become available after restart"; then
            log "WARNING" "Failed to save recovery attempt state, continuing anyway"
        fi
        
        return 1
    fi
    
    # Verify that containers are running again
    if [ -n "$containers_before" ]; then
        log "INFO" "Waiting for containers to restart"
        sleep 10  # Give containers time to start
        
        local containers_after=$(docker ps -q 2>/dev/null || echo "")
        local before_count=$(echo "$containers_before" | wc -l)
        local after_count=$(echo "$containers_after" | wc -l)
        
        if [ $after_count -lt $((before_count / 2)) ]; then
            log "WARNING" "Fewer than half of the containers restarted ($after_count vs $before_count)"
        else 
            log "INFO" "$after_count containers running after Docker restart"
        fi
    fi
    
    # Update cooldown timestamp
    if ! update_cooldown_timestamp "recovery_${RECOVERY_LEVEL_SERVICE}"; then
        log "WARNING" "Failed to update cooldown timestamp for service recovery"
    fi
    
    # Record the success in recovery state
    if ! save_recovery_attempt "service" "restart_docker" "success" "Docker service restarted successfully"; then
        log "WARNING" "Failed to save recovery attempt state, continuing anyway"
    fi
    
    log "INFO" "Docker service restarted successfully"
    return 0
}

# ==========================================
# Diagnostics and verification functions
# ==========================================

# Collect diagnostic information after an action
# Usage: collect_action_diagnostics action_type subject
# Arguments:
#   action_type - Type of action performed (container_restart, service_restart)
#   subject - ID or name of the object the action was performed on
# Returns: Diagnostic information as formatted text
collect_action_diagnostics() {
    local action_type="$1"
    local subject="$2"
    local diagnostics=""
    
    diagnostics+="timestamp:$(date +%s)\n"
    diagnostics+="action_type:$action_type\n"
    diagnostics+="subject:$subject\n"
    
    case "$action_type" in
        "container_restart")
            # Container-specific diagnostics
            if docker ps -q --filter "id=$subject" | grep -q .; then
                # Container exists, collect data
                diagnostics+="container_running:true\n"
                
                # Container status
                local status=$(get_container_status "$subject" 2>/dev/null)
                if [ -n "$status" ]; then
                    diagnostics+="$status\n"
                fi
                
                # Last few log lines
                local logs=$(docker logs --tail 10 "$subject" 2>&1 | sed 's/^/log: /')
                if [ -n "$logs" ]; then
                    diagnostics+="container_logs:\n$logs\n"
                fi
                
                # Container network settings
                local network_settings=$(docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}},{{end}}' "$subject" 2>/dev/null)
                diagnostics+="container_networks:$network_settings\n"
                
                # Check if flannel interface exists
                if ip link show flannel.1 &>/dev/null; then
                    diagnostics+="flannel_interface:present\n"
                    
                    # Get interface details
                    local interface_details=$(ip -d link show flannel.1 | grep -v 'link/ether' | tr -d '\n')
                    diagnostics+="flannel_interface_details:$interface_details\n"
                else 
                    diagnostics+="flannel_interface:missing\n"
                fi
                
                # Check routes through flannel
                local flannel_routes=$(ip route show | grep flannel.1 | sed 's/^/route: /')
                if [ -n "$flannel_routes" ]; then
                    diagnostics+="flannel_routes:\n$flannel_routes\n"
                else 
                    diagnostics+="flannel_routes:none\n"
                fi
            else 
                diagnostics+="container_running:false\n"
                diagnostics+="error:container_not_found\n"
            fi
            ;;
            
        "service_restart")
            # Service-specific diagnostics
            if [ "$subject" = "docker" ]; then
                # Docker service diagnostics
                if docker info &>/dev/null; then
                    diagnostics+="docker_service:running\n"
                    
                    # Docker version
                    local version=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
                    diagnostics+="docker_version:$version\n"
                    
                    # Running containers count
                    local container_count=$(docker ps -q 2>/dev/null | wc -l)
                    diagnostics+="running_containers:$container_count\n"
                    
                    # Docker daemon info (simplified)
                    local info=$(docker info --format '{{.ServerVersion}},{{.Driver}},{{.KernelVersion}}' 2>/dev/null)
                    diagnostics+="docker_info:$info\n"
                else 
                    diagnostics+="docker_service:not_running\n"
                    diagnostics+="error:docker_service_unavailable\n"
                fi
                
                # Check systemd status in a way that works in a container
                if is_running_in_container; then
                    diagnostics+="in_container:true\n"
                else 
                    local systemd_status=""
                    if command -v systemctl &>/dev/null; then
                        systemd_status=$(systemctl status docker | grep "Active:" | sed 's/\s\+/ /g')
                    fi
                    diagnostics+="in_container:false\n"
                    diagnostics+="systemd_status:$systemd_status\n"
                fi
            fi
            ;;
            
        *)
            diagnostics+="error:unknown_action_type\n"
            ;;
    esac
    
    # Check for system-wide issues
    local load=$(uptime | sed 's/.*load average: //' | tr -d ',')
    diagnostics+="system_load:$load\n"
    
    # Memory usage
    if command -v free &>/dev/null; then
        local memory=$(free -m | grep "Mem:" | awk '{printf "%d/%d MB (%.1f%%)", $3, $2, ($3/$2)*100}')
        diagnostics+="memory_usage:$memory\n"
    fi
    
    # Disk usage for Docker directory
    if command -v df &>/dev/null; then
        local disk=$(df -h /var/lib/docker 2>/dev/null | tail -1 | awk '{printf "%s/%s (%s)", $3, $2, $5}')
        if [ -n "$disk" ]; then
            diagnostics+="docker_disk_usage:$disk\n"
        fi
    fi
    
    echo -e "$diagnostics"
    return 0
}

# Verify a specific action was successful
# Usage: verify_action_success action_type subject [timeout]
# Arguments:
#   action_type - Type of action performed (container_restart, service_restart)
#   subject - ID or name of the object the action was performed on
#   timeout - Optional timeout in seconds (default: 60)
# Returns: 0 if successful, 1 if failed
verify_action_success() {
    local action_type="$1"
    local subject="$2"
    local timeout="${3:-60}"
    
    log "INFO" "Verifying success of $action_type on $subject (timeout: ${timeout}s)"
    
    # Get current time for timeout calculation
    local start_time=$(date +%s)
    local end_time=$((start_time + timeout))
    
    # Loop until timeout reached
    while [ $(date +%s) -lt $end_time ]; do
        case "$action_type" in
            "container_restart")
                # Check if container is running and healthy
                if check_container_health "$subject"; then
                    log "INFO" "Container $subject is running and healthy"
                    return 0
                fi
                ;;
                
            "service_restart")
                if [ "$subject" = "docker" ]; then
                    # Check if Docker service is running
                    if docker info &>/dev/null; then
                        # Check if flannel container is also running
                        local flannel_id=$(find_flannel_container)
                        if [ -n "$flannel_id" ]; then
                            log "INFO" "Docker service is running and flannel container is available"
                            return 0
                        else 
                            log "WARNING" "Docker service is running but flannel container is not available"
                        fi
                     else 
                        log "WARNING" "Docker service is not running or not responding"
                    fi
                else 
                    log "WARNING" "Unsupported service verification: $subject"
                    return 1
                fi
                ;;
                
            *)
                log "ERROR" "Unknown action type for verification: $action_type"
                return 1
                ;;
        esac
        
        # Wait before next check
        sleep 5
    done
    
    log "ERROR" "Verification failed for $action_type on $subject (timeout: ${timeout}s)"
    return 1
}

# Export necessary functions and variables
export -f init_recovery_actions
export -f is_running_in_container
export -f restart_flannel_container
export -f restart_docker_service
export -f find_flannel_container
export -f check_container_health
export -f delegate_host_action
export -f verify_action_success
export -f collect_action_diagnostics
export -f get_container_status
