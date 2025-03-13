#!/bin/bash
# monitoring-system.sh
# System-level health checks for flannel-registrar monitoring
# Part of the minimalist multi-module monitoring system

# Module information
MODULE_NAME="monitoring-system"
MODULE_VERSION="1.0.0"
MODULE_DEPENDENCIES=("common" "etcd-lib" "monitoring-core")

# Import status constants if not exported from monitoring-core.sh
if [ -z "$MONITORING_STATUS_HEALTHY" ]; then
    MONITORING_STATUS_HEALTHY="healthy"
    MONITORING_STATUS_DEGRADED="degraded"
    MONITORING_STATUS_CRITICAL="critical"
    MONITORING_STATUS_UNKNOWN="unknown"
fi

# Environment variables for configurable thresholds
DISK_DEGRADED_THRESHOLD=${DISK_DEGRADED_THRESHOLD:-20}  # %
DISK_CRITICAL_THRESHOLD=${DISK_CRITICAL_THRESHOLD:-5}   # %
MEMORY_DEGRADED_THRESHOLD=${MEMORY_DEGRADED_THRESHOLD:-80}  # %
MEMORY_CRITICAL_THRESHOLD=${MEMORY_CRITICAL_THRESHOLD:-95}  # %
CRITICAL_PROCESSES=${CRITICAL_PROCESSES:-"flannel,dockerd,flannel-registrar,etcd"}
SYSTEMD_SERVICES=${SYSTEMD_SERVICES:-"flannel-recovery.service,flannel-boot.service,docker.service"}

# Initialize system monitoring
# Usage: init_monitoring_system
# Returns: 0 on success, 1 on failure
init_monitoring_system() {
    # Check dependencies
    for dep in log update_component_status get_component_status; do
        if ! type "$dep" &>/dev/null; then
            echo "ERROR: Required function '$dep' not found"
            return 1
        fi
    done

    # Set default initial status for system components
    update_component_status "system.flannel" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "system.docker" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "system.disk" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "system.memory" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "system.cpu" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "system.processes" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"
    update_component_status "system.services" "$MONITORING_STATUS_UNKNOWN" "Not checked yet"

    log "INFO" "Initialized monitoring-system module (v${MODULE_VERSION})"
    return 0
}

# Detect container environment
# Usage: is_running_in_container
# Returns: 0 if in container, 1 if not
is_running_in_container() {
    if [ -f "/.dockerenv" ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check flannel container health
# Usage: check_flannel_container
# Returns: 0 if healthy, 1 if issues detected
check_flannel_container() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="Flannel container is running properly"
    
    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        update_component_status "system.flannel" "$MONITORING_STATUS_UNKNOWN" \
            "Docker command not available"
        return 1
    fi

    # Find flannel container (using common names)
    local container_id=$(docker ps --filter name="flannel" --format '{{.ID}}' 2>/dev/null | head -1)
    
    if [ -z "$container_id" ]; then
        update_component_status "system.flannel" "$MONITORING_STATUS_CRITICAL" \
            "Flannel container not found"
        return 1
    fi
    
    # Check container status
    local container_status=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null)
    
    if [ "$container_status" != "running" ]; then
        status="$MONITORING_STATUS_CRITICAL"
        message="Flannel container status: $container_status"
    else
        # Check for container restarts
        local restart_count=$(docker inspect --format='{{.RestartCount}}' "$container_id" 2>/dev/null)
        if [ "$restart_count" -gt 5 ]; then
            status="$MONITORING_STATUS_DEGRADED"
            message="Flannel container has restarted $restart_count times"
        fi
    fi
    
    update_component_status "system.flannel" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Check Docker service health
# Usage: check_docker_service
# Returns: 0 if healthy, 1 if issues detected
check_docker_service() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="Docker service is running properly"
    
    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        update_component_status "system.docker" "$MONITORING_STATUS_CRITICAL" \
            "Docker command not available"
        return 1
    fi
    
    # Check Docker service status
    if ! docker info &>/dev/null; then
        update_component_status "system.docker" "$MONITORING_STATUS_CRITICAL" \
            "Docker service not running"
        return 1
    fi
    
    # Check Docker container count
    local container_count=$(docker ps -q | wc -l)
    
    # Get info about Docker data usage
    if docker info 2>/dev/null | grep -q "Docker Root Dir"; then
        local disk_info=$(docker info 2>/dev/null | grep "Data Space")
        if echo "$disk_info" | grep -q "90%"; then
            status="$MONITORING_STATUS_DEGRADED"
            message="Docker disk usage high: $disk_info"
        fi
    fi
    
    update_component_status "system.docker" "$status" "$message (containers: $container_count)"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Check available disk space
# Usage: check_disk_space
# Returns: 0 if healthy, 1 if issues detected
check_disk_space() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="Disk space is sufficient"
    
    # Check if df command is available
    if ! command -v df &>/dev/null; then
        update_component_status "system.disk" "$MONITORING_STATUS_UNKNOWN" \
            "df command not available"
        return 1
    fi
    
    # Get disk space for relevant paths
    local docker_dir="/var/lib/docker"
    if is_running_in_container; then
        docker_dir="/"  # In container, check root filesystem
    fi
    
    local disk_usage=$(df -h "$docker_dir" | grep -v "Filesystem" | awk '{print $5}' | tr -d '%')
    local available=$(df -h "$docker_dir" | grep -v "Filesystem" | awk '{print $4}')
    
    if [ "$disk_usage" -gt $((100 - DISK_CRITICAL_THRESHOLD)) ]; then
        status="$MONITORING_STATUS_CRITICAL"
        message="Critical disk space: $disk_usage% used, $available available"
    elif [ "$disk_usage" -gt $((100 - DISK_DEGRADED_THRESHOLD)) ]; then
        status="$MONITORING_STATUS_DEGRADED"
        message="Low disk space: $disk_usage% used, $available available"
    else
        message="Disk space okay: $disk_usage% used, $available available"
    fi
    
    update_component_status "system.disk" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Check system memory usage
# Usage: check_memory_usage
# Returns: 0 if healthy, 1 if issues detected
check_memory_usage() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="Memory usage is within normal range"
    
    # Check if free command is available
    if ! command -v free &>/dev/null; then
        update_component_status "system.memory" "$MONITORING_STATUS_UNKNOWN" \
            "free command not available"
        return 1
    fi
    
    # Get memory usage
    local mem_info=$(free -m | grep "Mem:")
    local total_mem=$(echo "$mem_info" | awk '{print $2}')
    local used_mem=$(echo "$mem_info" | awk '{print $3}')
    local usage_percent=$((used_mem * 100 / total_mem))
    
    if [ "$usage_percent" -gt "$MEMORY_CRITICAL_THRESHOLD" ]; then
        status="$MONITORING_STATUS_CRITICAL"
        message="Critical memory usage: $usage_percent% ($used_mem MB of $total_mem MB)"
    elif [ "$usage_percent" -gt "$MEMORY_DEGRADED_THRESHOLD" ]; then
        status="$MONITORING_STATUS_DEGRADED"
        message="High memory usage: $usage_percent% ($used_mem MB of $total_mem MB)"
    else
        message="Memory usage normal: $usage_percent% ($used_mem MB of $total_mem MB)"
    fi
    
    update_component_status "system.memory" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Check system CPU load
# Usage: check_cpu_load
# Returns: 0 if healthy, 1 if issues detected
check_cpu_load() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="CPU load is within normal range"
    
    # Get CPU count
    local cpu_count=1
    if [ -f /proc/cpuinfo ]; then
        cpu_count=$(grep -c "processor" /proc/cpuinfo || echo 1)
    fi
    
    # Get load average
    if [ -f /proc/loadavg ]; then
        local load_avg=$(cat /proc/loadavg | awk '{print $1}')
        local load_avg_float=$(echo "$load_avg" | sed 's/,/./g')  # Handle locales
        
        # Compare with thresholds (using integer comparison by multiplying by 100)
        local load_int=$(echo "$load_avg_float * 100" | bc -l | cut -d. -f1)
        local cpu_threshold_degraded=$((cpu_count * 100))
        local cpu_threshold_critical=$((cpu_count * 200))
        
        if [ "$load_int" -gt "$cpu_threshold_critical" ]; then
            status="$MONITORING_STATUS_CRITICAL"
            message="Critical CPU load: $load_avg (threshold: $(echo "scale=2; $cpu_threshold_critical/100" | bc -l))"
        elif [ "$load_int" -gt "$cpu_threshold_degraded" ]; then
            status="$MONITORING_STATUS_DEGRADED"
            message="High CPU load: $load_avg (threshold: $(echo "scale=2; $cpu_threshold_degraded/100" | bc -l))"
        else
            message="CPU load normal: $load_avg (threshold: $(echo "scale=2; $cpu_threshold_degraded/100" | bc -l))"
        fi
    else
        status="$MONITORING_STATUS_UNKNOWN"
        message="Cannot determine CPU load"
    fi
    
    update_component_status "system.cpu" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Check if critical processes are running
# Usage: check_process_existence
# Returns: 0 if all processes running, 1 if issues detected
check_process_existence() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="All critical processes are running"
    local missing_processes=""
    local missing_count=0
    
    IFS=',' read -ra PROCS <<< "$CRITICAL_PROCESSES"
    
    for proc in "${PROCS[@]}"; do
        # Trim whitespace
        proc=$(echo "$proc" | tr -d ' ')
        
        # Skip empty process names
        [ -z "$proc" ] && continue
        
        # Check if process is running
        if ! pgrep -f "$proc" >/dev/null 2>&1; then
            missing_count=$((missing_count + 1))
            if [ -z "$missing_processes" ]; then
                missing_processes="$proc"
            else
                missing_processes="$missing_processes, $proc"
            fi
        fi
    done
    
    if [ "$missing_count" -gt 0 ]; then
        if [ "$missing_count" -ge ${#PROCS[@]} ]; then
            status="$MONITORING_STATUS_CRITICAL"
            message="All critical processes are missing: $missing_processes"
        else
            status="$MONITORING_STATUS_DEGRADED"
            message="Some critical processes are missing: $missing_processes"
        fi
    fi
    
    update_component_status "system.processes" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Check status of flannel-related systemd services
# Usage: check_systemd_services
# Returns: 0 if all services running, 1 if issues detected
check_systemd_services() {
    local status="$MONITORING_STATUS_HEALTHY"
    local message="All systemd services are running"
    local failed_services=""
    local failed_count=0
    
    # Skip in container environment
    if is_running_in_container; then
        update_component_status "system.services" "$MONITORING_STATUS_UNKNOWN" \
            "Running in container, systemd services not available"
        return 0
    fi
    
    # Check if systemctl command is available
    if ! command -v systemctl &>/dev/null; then
        update_component_status "system.services" "$MONITORING_STATUS_UNKNOWN" \
            "systemctl command not available"
        return 0
    fi
    
    IFS=',' read -ra SERVICES <<< "$SYSTEMD_SERVICES"
    
    for service in "${SERVICES[@]}"; do
        # Trim whitespace
        service=$(echo "$service" | tr -d ' ')
        
        # Skip empty service names
        [ -z "$service" ] && continue
        
        # Check if service is running
        if ! systemctl is-active --quiet "$service" 2>/dev/null; then
            failed_count=$((failed_count + 1))
            if [ -z "$failed_services" ]; then
                failed_services="$service"
            else
                failed_services="$failed_services, $service"
            fi
        fi
    done
    
    if [ "$failed_count" -gt 0 ]; then
        if [ "$failed_count" -ge ${#SERVICES[@]} ]; then
            status="$MONITORING_STATUS_CRITICAL"
            message="All systemd services are failed: $failed_services"
        else
            status="$MONITORING_STATUS_DEGRADED"
            message="Some systemd services are failed: $failed_services"
        fi
    fi
    
    update_component_status "system.services" "$status" "$message"
    return $([ "$status" = "$MONITORING_STATUS_HEALTHY" ] && echo 0 || echo 1)
}

# Run all system health checks and update status
# Usage: run_system_health_check
# Returns: 0 if all healthy, 1 if issues detected
run_system_health_check() {
    log "INFO" "Running system health checks"
    local issues=0

    # Run all individual checks
    check_flannel_container || issues=$((issues + 1))
    check_docker_service || issues=$((issues + 1))
    check_disk_space || issues=$((issues + 1))
    check_memory_usage || issues=$((issues + 1))
    check_cpu_load || issues=$((issues + 1))
    check_process_existence || issues=$((issues + 1))
    check_systemd_services || issues=$((issues + 1))

    # Log summary
    log "INFO" "System health checks completed with $issues issues detected"

    return $([ $issues -eq 0 ] && echo 0 || echo 1)
}

# Get basic diagnostic information for troubleshooting
# Usage: get_system_diagnostics
# Returns: Tab-delimited diagnostic information
get_system_diagnostics() {
    local diag="time:$(date +%s)\thost:$(hostname)\n"

    # System information
    diag+="kernel:$(uname -r)\tuptime:$(uptime | cut -d' ' -f4-)\n"
    if [ -f /etc/os-release ]; then
        diag+="os:$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')\n"
    fi

    # Docker information
    if command -v docker &>/dev/null; then
        diag+="docker_version:$(docker --version | cut -d' ' -f3 | tr -d ',')\n"
        diag+="container_count:$(docker ps -q | wc -l)\n"
    else
        diag+="docker:unavailable\n"
    fi

    # Resource usage
    if command -v free &>/dev/null; then
        local mem_info=$(free -m | grep "Mem:")
        local total_mem=$(echo "$mem_info" | awk '{print $2}')
        local used_mem=$(echo "$mem_info" | awk '{print $3}')
        local usage_percent=$((used_mem * 100 / total_mem))
        diag+="memory_usage:$usage_percent%\tmemory_total:${total_mem}MB\n"
    fi

    if [ -f /proc/loadavg ]; then
        diag+="load_avg:$(cat /proc/loadavg | awk '{print $1,$2,$3}')\n"
    fi

    if command -v df &>/dev/null; then
        local disk_usage=$(df -h / | grep -v "Filesystem" | awk '{print $5}')
        diag+="disk_usage:$disk_usage\n"
    fi

    # Container info
    if is_running_in_container; then
        diag+="environment:container\n"
    else
        diag+="environment:host\n"
    fi

    # Component status summary
    diag+="status_flannel:$(get_component_status "system.flannel" | cut -d':' -f1)\n"
    diag+="status_docker:$(get_component_status "system.docker" | cut -d':' -f1)\n"
    diag+="status_disk:$(get_component_status "system.disk" | cut -d':' -f1)\n"
    diag+="status_memory:$(get_component_status "system.memory" | cut -d':' -f1)\n"
    diag+="status_cpu:$(get_component_status "system.cpu" | cut -d':' -f1)\n"
    diag+="status_processes:$(get_component_status "system.processes" | cut -d':' -f1)\n"
    diag+="status_services:$(get_component_status "system.services" | cut -d':' -f1)\n"

    echo -e "$diag"
    return 0
}

# Export necessary functions
export -f init_monitoring_system
export -f is_running_in_container
export -f check_flannel_container
export -f check_docker_service
export -f check_disk_space
export -f check_memory_usage
export -f check_cpu_load
export -f check_process_existence
export -f check_systemd_services
export -f run_system_health_check
export -f get_system_diagnostics
