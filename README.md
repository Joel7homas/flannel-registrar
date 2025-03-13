# Flannel Network Registrar

A containerized solution for automatically registering, synchronizing, and routing Docker networks across hosts running Flannel for multi-host container networking.

## Purpose

This utility solves a common issue when using Flannel with Docker networks: enabling automatic routing between custom Docker networks across multiple hosts. By default, Flannel only manages its own subnet per host, making cross-host communication between multiple custom Docker networks challenging.

The Flannel Network Registrar discovers all Docker networks on a host, registers them with etcd so Flannel can be aware of them, manages routes between these networks, and enables proper communication across hosts.

## Problem Solved

When running Docker with Flannel across multiple hosts:

1.  Containers can communicate with containers in the default Flannel network on other hosts
2.  Containers cannot normally communicate with containers in custom Docker networks on other hosts
3.  Hosts with multiple Docker networks need proper route management for cross-host communication

This solution bridges these gaps without requiring a complete network restructuring or implementing a full Kubernetes cluster.

## How It Works

1.  **Network Discovery**: The container automatically discovers all Docker networks on each host and extracts their subnet information.

2.  **Registration with etcd**: It registers each network subnet in etcd under a custom prefix (`/flannel/network/subnets`), using a key that includes the hostname and network name.

3.  **Backend Registration**: The script also registers the necessary backend data (similar to what Flannel does) under the standard Flannel prefix, which includes VxLAN information.

4.  **Route Management**: The container ensures routes exist to all registered subnets, maintaining connectivity between all Docker networks across all hosts.

5.  **Flannel Integration**: The container notifies the Flannel daemon to update its routes when possible.

6.  **Periodic Updates**: When run in daemon mode, the script periodically updates this information, ensuring new networks are registered and routes are maintained.

7.  **Dynamic User Management**: The container automatically adapts to the Docker socket's group ID on each host, allowing it to run with just enough permissions.

8.  **Cleanup of Problematic Entries**: The container automatically cleans up any localhost (127.0.0.1) entries in etcd that would prevent proper routing.

9.  **Self-Healing**: The container detects network issues and automatically recovers from them, ensuring persistent connectivity.

10. **Complex Network Topology Support**: Handles indirect routing through gateways for hosts that cannot directly communicate.

## Components

- **register-docker-networks.sh**: Main script that orchestrates all network management modules
- **docker-entrypoint.sh**: Handles dynamic user creation to match Docker socket permissions
- **Dockerfile**: Builds the container image with necessary dependencies
- **docker-compose.yml**: Simplifies deployment across hosts
- **systemd services**: Optional host-level services for critical recovery operations

## Architecture
```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     Host 1      │     │     Host 2      │     │     Host 3      │
│ ┌─────────────┐ │     │ ┌─────────────┐ │     │ ┌─────────────┐ │
│ │   Flannel   │ │     │ │   Flannel   │ │     │ │   Flannel   │ │
│ └─────────────┘ │     │ └─────────────┘ │     │ └─────────────┘ │
│ ┌─────────────┐ │     │ ┌─────────────┐ │     │ ┌─────────────┐ │
│ │  Registrar  │◄┼─────┼─┤    etcd     │◄┼─────┼─┤  Registrar  │ │
│ └─────────────┘ │     │ └─────────────┘ │     │ └─────────────┘ │
│                 │     │                 │     │                 │
│ ┌─────┐ ┌─────┐ │     │ ┌─────┐ ┌─────┐ │     │ ┌─────┐ ┌─────┐ │
│ │Net 1│ │Net 2│ │     │ │Net 3│ │Net 4│ │     │ │Net 5│ │Net 6│ │
│ └─────┘ └─────┘ │     │ └─────┘ └─────┘ │     │ └─────┘ └─────┘ │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

The registrar containers on each host communicate with a central etcd instance to register their local Docker networks and maintain routes. Flannel uses the VxLAN overlay to transport traffic between networks across hosts.

## Security Considerations

- The container requires NET_ADMIN capabilities and host network mode to manage routes
- It automatically adapts to different Docker socket group IDs across hosts
- For proper route management, it must run with root privileges

## Setup Instructions

1.  Build the image on a host with Docker:

    ```bash
    docker build -t flannel-registrar .
    ```

2.  Deploy using docker-compose:
```yaml
version: '3.8'

services:
  flannel-registrar:
    image: flannel-registrar:1.1.0
    container_name: flannel-registrar-hostname
    restart: unless-stopped
    network_mode: "host"  # Required for route management
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /etc/hostname:/etc/hostname:ro
    environment:
      - ETCD_ENDPOINT=http://192.168.4.88:2379
      - FLANNEL_PREFIX=/coreos.com/network
      - FLANNEL_CONFIG_PREFIX=/flannel/network/subnets
      - HOST_NAME=auto  # Will be determined by reading /etc/hostname
      - INTERVAL=120    # Update interval in seconds
      - RUN_AS_ROOT=true
      - FLANNELD_PUBLIC_IP=192.168.4.X  # Replace with host's IP address
      - HOST_GATEWAY_MAP=172.24.90.1:172.24.90.6  # Optional indirect routing config
    cap_add:
      - NET_ADMIN  # Required for route management
```


3.  Initialize etcd directories (one-time setup):
```bash
# Connect to etcd container
docker exec -it <etcd-container-name> sh

# Create required directories
etcdctl mkdir /flannel/network
etcdctl mkdir /flannel/network/subnets
```

4. (Optional) Install system services for recovery:
```bash
# Copy service files
sudo cp flannel-recovery.service /etc/systemd/system/
sudo cp flannel-boot.service /etc/systemd/system/

# Copy scripts
sudo cp flannel-recovery.sh /usr/local/bin/
sudo cp flannel-boot.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/flannel-*.sh

# Enable and start services
sudo systemctl daemon-reload
sudo systemctl enable flannel-boot.service flannel-recovery.service
sudo systemctl start flannel-boot.service
```

## Configuration Options

| Environment Variable | Description | Default |
| --- | --- | --- |
| ETCD_ENDPOINT | URL of the etcd server | http://192.168.4.88:2379 |
| FLANNEL_PREFIX | Standard Flannel prefix in etcd | /coreos.com/network |
| FLANNEL_CONFIG_PREFIX | Custom prefix for network configuration | /flannel/network/subnets |
| HOST_NAME | Host identifier | $(hostname) |
| INTERVAL | Update interval in seconds | 60  |
| RUN_AS_ROOT | Whether to run as root | false |
| FLANNELD_PUBLIC_IP | Host's public IP for cross-host communication | (auto-detected) |
| HOST_GATEWAY_MAP | Map of hosts to their gateways for indirect routing | "" |
| FLANNEL_ROUTES_EXTRA | Extra routes to configure | "" |
| FLANNEL_CONTAINER_NAME | Name of the flannel container | flannel |
| DEBUG | Enable verbose debug logging | false |

## Advanced Features

- [Indirect Routing](./flannel-indirect-routing-docs.md) - Configure flannel for complex network topologies with gateway routing
- **Self-Healing** - Automatically detects and recovers from network issues
- **FDB Management** - Automatically keeps VXLAN FDB entries in sync
- **Health Monitoring** - Continuously monitors network health and connectivity
- **Interface Management** - Detects and fixes issues with VXLAN interfaces

## Troubleshooting

- **Permission Issues**: Ensure the container is running with `RUN_AS_ROOT=true`, `network_mode: "host"`, and the `NET_ADMIN` capability.

- **Network Registration**: Verify networks are registered in etcd with correct PublicIPs:

    `etcdctl --endpoints=http://192.168.4.88:2379 get --prefix /coreos.com/network/subnets`

- **Route Verification**: Check if routes to remote subnets exist:

    `ip route | grep 10.5`

- **Connectivity Testing**: Test container connectivity across hosts:

    `docker run --rm -it --net=network_name alpine ping <container-ip-on-other-host>`

- **Common Issues**:

    - If routes show "Network unreachable", check that hosts can reach each other directly
    - If VXLAN shows errors, check that UDP port 8472 is not blocked between hosts
    - Verify IP forwarding is enabled: `cat /proc/sys/net/ipv4/ip_forward` should return 1

## Advanced Configuration

### Multiple Network Isolation

By default, the registrar enables communication between all Docker networks across all hosts. For production environments, you may want to isolate specific networks:

1.  Add iptables rules to block traffic between networks:
```bash
sudo iptables -I FORWARD -s 10.5.35.0/24 -d 10.5.40.0/24 -j DROP
sudo iptables -I FORWARD -s 10.5.40.0/24 -d 10.5.35.0/24 -j DROP
```

2.  Make these rules persistent with iptables-persistent or similar tool.

### Indirect Routing Configuration

For complex network topologies where some hosts cannot directly communicate with each other but must go through a gateway:

```yaml
environment:
  # Format: "host_ip:gateway_ip,host_ip2:gateway_ip2"
  - HOST_GATEWAY_MAP=172.24.90.1:172.24.90.6
```

This example configures traffic destined for 172.24.90.1 to be routed through 172.24.90.6.

## System Requirements

- Docker 20.10 or newer
- Linux kernel with VXLAN support (3.12+)
- etcd v3.x
- iptables/nftables
- flannel 0.19.0 or newer
- Hosts with IP connectivity between them (direct or indirect)

## Maintenance

The solution is designed for low maintenance. It automatically adapts to changes in your Docker network configuration and manages routes dynamically. Periodic image updates may be required for security patches.
