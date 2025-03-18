FROM alpine:3.18

ARG VERSION=1.2.0-alpha.18

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    docker-cli \
    iproute2 \
    iptables \
    jq \
    shadow \
    util-linux \
    su-exec

# Create common directories
RUN mkdir -p /usr/local/lib/flannel-registrar /var/run/flannel-registrar

# Create a debug script
RUN echo '#!/bin/bash' > /usr/local/bin/debug-flannel.sh && \
    echo 'echo "Starting diagnostic mode"' >> /usr/local/bin/debug-flannel.sh && \
    echo 'echo "Testing etcd connectivity:"' >> /usr/local/bin/debug-flannel.sh && \
    echo 'curl -s -m 3 $ETCD_ENDPOINT/health || echo "Cannot connect to etcd at $ETCD_ENDPOINT"' >> /usr/local/bin/debug-flannel.sh && \
    echo 'echo "Testing Docker connectivity:"' >> /usr/local/bin/debug-flannel.sh && \
    echo 'docker ps >/dev/null 2>&1 && echo "Docker connection successful" || echo "Cannot connect to Docker"' >> /usr/local/bin/debug-flannel.sh && \
    echo 'echo "Sleeping to keep container running for debugging..."' >> /usr/local/bin/debug-flannel.sh && \
    echo 'sleep 3600' >> /usr/local/bin/debug-flannel.sh && \
    chmod +x /usr/local/bin/debug-flannel.sh

# Copy main script and set execute permissions
COPY register-docker-networks.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/register-docker-networks.sh

# Copy entrypoint script and set execute permissions
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Copy all module files to lib directory
COPY lib/common.sh \
     lib/etcd-lib.sh \
     lib/network-lib.sh \
     lib/routes-core.sh \
     lib/routes-advanced.sh \
     lib/fdb-core.sh \
     lib/fdb-advanced.sh \
     lib/fdb-diagnostics-core.sh \
     lib/connectivity-core.sh \
     lib/connectivity-diagnostics.sh \
     lib/monitoring-core.sh \
     lib/monitoring-network.sh \
     lib/monitoring-reporting.sh \
     lib/monitoring-system.sh \
     lib/recovery-state.sh \
     lib/recovery-core.sh \
     lib/recovery-actions.sh \
     lib/recovery-monitoring.sh \
     lib/recovery-host.sh \
     /usr/local/lib/flannel-registrar/

# Create a non-root user with a temporary GID/UID
RUN addgroup -S docker_user && \
    adduser -S -G docker_user -h /home/docker_user docker_user && \
    chown -R docker_user:docker_user /var/run/flannel-registrar

# Set environment variables
ENV ETCD_ENDPOINT=http://127.0.0.1:2379 \
    FLANNEL_PREFIX=/coreos.com/network \
    FLANNEL_CONFIG_PREFIX=/flannel/network/subnets \
    INTERVAL=60 \
    RUN_AS_ROOT=false \
    HOST_NAME=auto \
    ETCDCTL_API=3 \
    DEBUG=true \
    VERSION=${VERSION}

LABEL version="${VERSION}"

# Set script as entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]

# Default command - will be overridden if specified in docker run
CMD ["register-docker-networks.sh"]

