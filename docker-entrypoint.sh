#!/bin/bash
# Docker entrypoint script that dynamically creates a user with the appropriate GID

set -e

# Log function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Determine the GID of the Docker socket
DOCKER_SOCKET_GID=$(stat -c "%g" /var/run/docker.sock 2>/dev/null || echo "0")
log "Docker socket has GID: $DOCKER_SOCKET_GID"

# Ensure we're passing through the daemon argument
CMD_ARGS="$@"
if [[ -z "$CMD_ARGS" ]]; then
  CMD_ARGS="--daemon"  # Ensure daemon mode is the default
  log "No arguments provided, defaulting to daemon mode"
fi

# If we can't determine GID or it's 0 (root), handle differently
if [ "$DOCKER_SOCKET_GID" = "0" ]; then
    log "Warning: Docker socket is owned by root or couldn't determine GID."
    # If running as root is requested, we'll just use root
    if [ "$RUN_AS_ROOT" = "true" ]; then
        log "Running as root as requested."
        exec /usr/local/bin/register-docker-networks.sh $CMD_ARGS
        exit 0
    else
        log "Falling back to default docker group setup."
        # Try to create a default docker group and user
        groupadd -g 1001 dockeraccess 2>/dev/null || true
        useradd -u 1000 -g 1001 -m -s /bin/bash flannel 2>/dev/null || true
    fi
else
    # If running as root is requested, we'll just use root
    if [ "$RUN_AS_ROOT" = "true" ]; then
        log "Running as root as requested."
        exec /usr/local/bin/register-docker-networks.sh $CMD_ARGS
        exit 0
    fi

    # Check if a group with this GID already exists
    GROUP_NAME=$(getent group "$DOCKER_SOCKET_GID" | cut -d: -f1 || echo "")

    if [ -n "$GROUP_NAME" ]; then
        log "Group with GID $DOCKER_SOCKET_GID already exists as '$GROUP_NAME'"
        # Create a non-root user and add it to the existing group
        useradd -u 1000 -g "$DOCKER_SOCKET_GID" -m -s /bin/bash flannel 2>/dev/null || true
        log "Added user 'flannel' to existing group '$GROUP_NAME' (GID: $DOCKER_SOCKET_GID)"
    else
        # Create a group with the same GID as the Docker socket
        groupadd -g "$DOCKER_SOCKET_GID" dockeraccess 2>/dev/null || true

        # Create a non-root user and add it to the docker group
        useradd -u 1000 -g "$DOCKER_SOCKET_GID" -m -s /bin/bash flannel 2>/dev/null || true

        log "Created user 'flannel' with group 'dockeraccess' (GID: $DOCKER_SOCKET_GID)"
    fi
fi

log "Running command: /usr/local/bin/register-docker-networks.sh $CMD_ARGS"

# Switch to the non-root user and run the main script
if [ "$RUN_AS_ROOT" != "true" ]; then
    log "Switching to non-root user 'flannel'"
    exec su-exec flannel /usr/local/bin/register-docker-networks.sh $CMD_ARGS
else
    exec /usr/local/bin/register-docker-networks.sh $CMD_ARGS
fi

# This should never execute due to the exec above
log "ERROR: Script exited unexpectedly"
exit 1
