FROM alpine:3.18

LABEL version="1.1.1"

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    docker-cli \
    shadow \
    su-exec \
    iptables \
    ip6tables \
    iproute2 \
    bridge-utils \
    tcpdump \
    iputils

# Create directories
RUN mkdir -p /usr/local/lib/flannel-registrar \
    && mkdir -p /var/run/flannel-registrar

# Copy scripts
COPY register-docker-networks.sh /usr/local/bin/
COPY docker-entrypoint.sh /usr/local/bin/

# Copy library modules
COPY lib/etcd-lib.sh /usr/local/lib/flannel-registrar/
COPY lib/connectivity.sh /usr/local/lib/flannel-registrar/
COPY lib/recovery.sh /usr/local/lib/flannel-registrar/
COPY lib/fdb-management.sh /usr/local/lib/flannel-registrar/
COPY lib/routes.sh /usr/local/lib/flannel-registrar/
COPY lib/monitoring.sh /usr/local/lib/flannel-registrar/

# Make scripts executable
RUN chmod +x /usr/local/bin/register-docker-networks.sh \
    /usr/local/bin/docker-entrypoint.sh \
    /usr/local/lib/flannel-registrar/*.sh

# Set environment variables with defaults
ENV ETCD_ENDPOINT="http://192.168.4.88:2379" \
    FLANNEL_PREFIX="/coreos.com/network" \
    FLANNEL_CONFIG_PREFIX="/flannel/network/subnets" \
    INTERVAL="60" \
    HOST_NAME="auto" \
    RUN_AS_ROOT="false" \
    ETCDCTL_API="3" \
    HOST_GATEWAY_MAP="" \
    FLANNEL_ROUTES_EXTRA="" \
    FLANNEL_CONTAINER_NAME="flannel" \
    DEBUG="false" \
    VERSION="1.1.0"

# Use the entrypoint script to handle dynamic group creation
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

