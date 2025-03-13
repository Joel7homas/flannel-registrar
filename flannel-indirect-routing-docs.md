# Flannel Indirect Routing Guide

This guide explains how to configure flannel-registrar to handle complex network topologies with indirect routing requirements, such as when hosts need to communicate through a gateway rather than directly.

## Problem Statement

In a complex network topology with hosts connected through WireGuard tunnels:

- `culvert` (VPS) announces its WireGuard IP (172.24.90.1) to etcd as its PublicIP
- `babka` and `pita` need to reach `culvert` through `lavash` (172.24.90.6) rather than directly
- When a host reboots, flannel tries to create direct VXLAN tunnels, which causes connectivity failures

The standard flannel implementation doesn't account for such indirect routing requirements, causing problems when hosts reboot or networks change.

## Solution

The flannel-registrar resolves this by:

1. Adding a `HOST_GATEWAY_MAP` environment variable to specify routing overrides
2. Modifying the route management code to use these gateway mappings
3. Configuring VTEP (VXLAN Tunnel Endpoint) destinations to point to gateways
4. Automatically detecting network topology where possible
5. Implementing self-healing mechanisms to recover from network issues

## Configuration

### Host Gateway Map Format

The `HOST_GATEWAY_MAP` environment variable uses the following format:

```
host1:gateway1,host2:gateway2,subnet/mask:gateway3
```

Where:
- `host1`, `host2` are IP addresses of hosts that need indirect routing
- `gateway1`, `gateway2` are IP addresses of the gateways to use
- `subnet/mask` can be used to specify routing for an entire subnet

### Example Docker Compose Configuration

```yaml
# For babka (TrueNAS)
environment:
  - HOST_GATEWAY_MAP=172.24.90.1:172.24.90.6
  - FLANNELD_PUBLIC_IP=192.168.4.88

# For culvert (VPS)
environment:
  # No HOST_GATEWAY_MAP needed as it has direct access
  - FLANNELD_PUBLIC_IP=172.24.90.1

# For pita (VM)
environment:
  - HOST_GATEWAY_MAP=172.24.90.1:172.24.90.6
  - FLANNELD_PUBLIC_IP=192.168.4.99
```

## How It Works

### 1. Route Configuration

When routes are created, flannel-registrar:

1. Checks if a host's IP matches an entry in `HOST_GATEWAY_MAP`
2. If a match is found, creates a route through the specified gateway instead of directly to the host
3. Otherwise, uses direct routing

For example, with `HOST_GATEWAY_MAP=172.24.90.1:172.24.90.6`, a subnet behind 172.24.90.1 gets routed like:
```
ip route add 10.5.8.0/24 via 172.24.90.6
```
Instead of the default:
```
ip route add 10.5.8.0/24 via 172.24.90.1
```

### 2. VXLAN Configuration

VXLAN tunnels require proper FDB (Forwarding Database) entries pointing to the right destination. With indirect routing:

1. The system modifies FDB entries to point VTEP MAC addresses to the gateway rather than the actual host
2. This ensures that VXLAN encapsulated packets are properly routed through the gateway
3. These FDB entries are regularly updated to ensure they stay current

For example, when updating FDB entries for a host behind a gateway:
```
bridge fdb add 12:34:56:78:9a:bc dev flannel.1 dst 172.24.90.6
```
Instead of:
```
bridge fdb add 12:34:56:78:9a:bc dev flannel.1 dst 172.24.90.1
```

### 3. Network Topology Detection

If `HOST_GATEWAY_MAP` is not specified, flannel-registrar attempts to detect the topology:

1. Tests direct connectivity to hosts
2. Checks for WireGuard interfaces and routes
3. Identifies potential gateway patterns
4. Adds appropriate routes if indirect routing is detected

### 4. Recovery Mechanisms

The system implements several recovery mechanisms:

1. **Interface Cycling**: Automatically cycles the flannel interface when connectivity issues are detected
2. **FDB Cleanup**: Removes stale FDB entries after host reboots
3. **Route Verification**: Regularly verifies and updates routes
4. **Systemd Services**: Optional host-level services provide deep recovery capabilities
5. **Boot-time Setup**: Ensures proper network configuration on system startup

## Advanced Options

### Multi-Level Routing

You can configure multiple levels of routing for complex topologies:

```yaml
environment:
  - HOST_GATEWAY_MAP=172.24.90.1:172.24.90.6,172.24.90.2:172.24.90.6,10.8.0.0/24:192.168.1.1
```

### Extra Routes

For additional custom routes:

```yaml
environment:
  - FLANNEL_ROUTES_EXTRA=10.5.8.0/24:192.168.4.1:enp7s0,10.5.30.0/24:192.168.4.99:eth0
```

Format: `subnet:gateway[:interface],subnet:gateway[:interface],...`

### Debug Mode

Enable verbose logging for troubleshooting:

```yaml
environment:
  - DEBUG=true
```

## Testing Indirect Routing

You can verify your configuration with:

1. Check routes:
   ```bash
   ip route | grep 10.5
   ```

2. Examine FDB entries:
   ```bash
   bridge fdb show dev flannel.1
   ```

3. Test container connectivity:
   ```bash
   docker run --rm --network caddy-public-net alpine ping 10.5.8.2
   ```

4. Validate that traffic is flowing through the gateway:
   ```bash
   # On lavash (gateway)
   tcpdump -i any -n 'port 8472'
   ```

## Troubleshooting

### Common Issues

1. **VTEPs pointing to wrong destination**:
   
   Check and fix FDB entries:
   ```bash
   bridge fdb del 00:11:22:33:44:55 dev flannel.1
   bridge fdb add 00:11:22:33:44:55 dev flannel.1 dst 172.24.90.6
   ```

2. **Routes not updating after reboot**:
   
   Force route updates:
   ```bash
   docker restart flannel-registrar
   ```

3. **One-way communication**:
   
   Check for asymmetric routing issues:
   ```bash
   # Test bidirectional connectivity
   docker exec container1 ping container2_ip
   docker exec container2 ping container1_ip
   ```

### Diagnostic Tools

The flannel-registrar provides built-in diagnostic capabilities:

1. Container logs:
   ```bash
   docker logs flannel-registrar
   ```

2. Health check:
   ```bash
   docker exec flannel-registrar cat /var/run/flannel-registrar/health_status.json
   ```

3. Diagnostic collection:
   ```bash
   docker exec flannel-registrar /usr/local/bin/register-docker-networks.sh --diagnose
   ```

### Recovery Scripts

For severe issues, you can use the recovery service:
```bash
sudo systemctl start flannel-recovery.service
```

## Best Practices

1. Always specify accurate `FLANNELD_PUBLIC_IP` values
2. Set appropriate `INTERVAL` values (120-300 seconds recommended)
3. Enable `DEBUG` during initial setup and troubleshooting
4. Use consistent versions across all hosts
5. Test recovery by rebooting hosts one at a time
6. Document your network topology and gateway mappings
7. Regularly check container logs for warnings or errors
8. Consider using the systemd services for critical environments
