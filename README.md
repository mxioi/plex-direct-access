# Plex Direct Access - Bypass Remote Streaming Restrictions

A solution for accessing your own Plex server as "local" when connecting through a separate network segment, bypassing Plex's remote streaming restrictions without requiring Plex Pass.

## The Problem

Plex has increasingly restricted remote streaming, requiring a Plex Pass subscription even for accessing your own content. When using a reverse proxy (like nginx) to access Plex from another network segment, Plex detects the proxy and treats the connection as "remote" - even if both networks are technically local.

**Typical setup that triggers "remote" detection:**
```
Family Network (<ADD-IP-ADDRESS>/24)
        |
    [Reverse Proxy / Bridge Server]
        |
Server Network (<ADD-IP-ADDRESS>/24)
        |
    [Plex Server]
```

When nginx proxies Plex traffic, Plex sees:
- HTTP proxy headers
- Connection from proxy IP, not client IP
- Result: "Remote streaming requires Plex Pass"

## The Solution

Instead of HTTP proxying, use:
1. **DNS override** - Resolve Plex domain to bridge server IP
2. **TCP NAT forwarding** - Forward port 32400 directly (Layer 4, not Layer 7)
3. **nginx redirect** - Redirect HTTPS requests to direct connection

**New flow:**
```
Family Device → DNS (bridge) → resolves to bridge IP
             → HTTPS request to bridge:443
             → nginx 302 redirect to bridge:32400
             → NAT forwards to Plex:32400
             → Plex sees bridge IP as source (in allowedNetworks)
             → Treated as LOCAL
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Family Network                              │
│                     (<ADD-IP-ADDRESS>/24)                            │
│                                                                  │
│  ┌──────────┐                                                   │
│  │  Phone/  │─────┐                                             │
│  │  Laptop  │     │                                             │
│  └──────────┘     │                                             │
│                   ▼                                             │
│            ┌─────────────────────────────────────┐              │
│            │     Bridge Server (Raspberry Pi)    │              │
│            │         <ADD-IP-ADDRESS> (wlan0)        │              │
│            │                                     │              │
│            │  • dnsmasq (DNS override)           │              │
│            │  • iptables (NAT forwarding)        │              │
│            │  • nginx (HTTPS → HTTP redirect)    │              │
│            │                                     │              │
│            │         <ADD-IP-ADDRESS> (eth0)         │              │
│            └──────────────┬──────────────────────┘              │
└───────────────────────────┼─────────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────┐
│                           │      Server Network                  │
│                           │     (<ADD-IP-ADDRESS>/24)                │
│                           ▼                                      │
│                    ┌─────────────┐                              │
│                    │ Plex Server │                              │
│                    │ <ADD-IP-ADDRESS> │                              │
│                    │   :32400    │                              │
│                    └─────────────┘                              │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Bridge server (Raspberry Pi or similar) with two network interfaces
  - One connected to family network (wlan0)
  - One connected to server network (eth0)
- Plex server accessible from bridge server
- Domain name pointing to bridge server (optional, for HTTPS)

## Installation

### 1. Enable IP Forwarding

```bash
# Check if enabled
cat /proc/sys/net/ipv4/ip_forward

# Enable permanently
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-ip-forward.conf
sudo sysctl -p /etc/sysctl.d/99-ip-forward.conf
```

### 2. Configure Firewall Rules

```bash
# Allow outbound to Plex
sudo ufw allow out to <PLEX_SERVER_IP> port 32400 proto tcp

# Allow inbound on family network interface
sudo ufw allow in on wlan0 to any port 32400 proto tcp
sudo ufw allow in on wlan0 to any port 53 comment 'DNS'
```

### 3. Set Up NAT Rules

```bash
# DNAT - Redirect incoming connections to Plex
sudo iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 32400 \
    -j DNAT --to-destination <PLEX_SERVER_IP>:32400

# MASQUERADE - Ensure return traffic comes back
sudo iptables -t nat -A POSTROUTING -d <PLEX_SERVER_IP> -p tcp --dport 32400 \
    -j MASQUERADE

# FORWARD rules (add to DOCKER-USER if using Docker, otherwise FORWARD)
sudo iptables -I DOCKER-USER -i wlan0 -o eth0 -d <PLEX_SERVER_IP> -p tcp --dport 32400 -j ACCEPT
sudo iptables -I DOCKER-USER -i eth0 -o wlan0 -s <PLEX_SERVER_IP> -p tcp --sport 32400 \
    -m state --state ESTABLISHED,RELATED -j ACCEPT
```

### 4. Configure dnsmasq

Create `/etc/dnsmasq.d/plex-direct.conf`:

```conf
# Listen only on family network interface
interface=wlan0
bind-interfaces

# Don't use /etc/resolv.conf
no-resolv

# Upstream DNS servers
server=<HOME_GATEWAY_IP>
server=1.1.1.1

# Override Plex domain to point to bridge
address=/plex.example.com/<BRIDGE_FAMILY_IP>

# Port
port=53
```

Start dnsmasq:
```bash
sudo /usr/sbin/dnsmasq --conf-file=/etc/dnsmasq.d/plex-direct.conf \
    --pid-file=/var/run/dnsmasq-plex.pid
```

### 5. Configure nginx Redirect

If using nginx-proxy-manager or similar, modify the Plex proxy host to redirect instead of proxy:

```nginx
server {
    listen 443 ssl;
    server_name plex.example.com;

    # SSL configuration...

    # Redirect root to Plex web interface
    location = / {
        return 302 http://<BRIDGE_FAMILY_IP>:32400/web/;
    }

    # Redirect all other requests
    location / {
        return 302 http://<BRIDGE_FAMILY_IP>:32400$request_uri;
    }
}
```

### 6. Update Plex Settings

Add the bridge server's server-network IP to Plex's allowed networks:

**In Plex Preferences.xml:**
```xml
allowedNetworks="<ADD-IP-ADDRESS>/24,<BRIDGE_SERVER_IP>/32"
```

**Or via Plex Web UI:**
Settings → Network → "LAN Networks" → Add bridge server IP

**Set Custom Connection URL:**
```xml
customConnections="http://<BRIDGE_FAMILY_IP>:32400"
```

This tells Plex apps to connect via the bridge.

### 7. Restart Plex

```bash
docker restart plex
# or
sudo systemctl restart plexmediaserver
```

## Making Changes Persistent

### iptables Persistence

Create `/etc/network/if-up.d/plex-nat`:

```bash
#!/bin/bash
if [ "$IFACE" = "wlan0" ]; then
    # DNAT rules
    iptables -t nat -C PREROUTING -i wlan0 -p tcp --dport 32400 \
        -j DNAT --to-destination <PLEX_SERVER_IP>:32400 2>/dev/null || \
        iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 32400 \
            -j DNAT --to-destination <PLEX_SERVER_IP>:32400

    # MASQUERADE
    iptables -t nat -C POSTROUTING -d <PLEX_SERVER_IP> -p tcp --dport 32400 \
        -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -d <PLEX_SERVER_IP> -p tcp --dport 32400 \
            -j MASQUERADE

    # FORWARD rules
    iptables -C DOCKER-USER -i wlan0 -o eth0 -d <PLEX_SERVER_IP> -p tcp --dport 32400 \
        -j ACCEPT 2>/dev/null || \
        iptables -I DOCKER-USER -i wlan0 -o eth0 -d <PLEX_SERVER_IP> -p tcp --dport 32400 \
            -j ACCEPT
fi
```

```bash
sudo chmod +x /etc/network/if-up.d/plex-nat
```

### dnsmasq Systemd Service

Create `/etc/systemd/system/dnsmasq-plex.service`:

```ini
[Unit]
Description=DNS for Plex direct access
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/sbin/dnsmasq --conf-file=/etc/dnsmasq.d/plex-direct.conf --pid-file=/var/run/dnsmasq-plex.pid
ExecStop=/bin/kill -TERM $MAINPID
PIDFile=/var/run/dnsmasq-plex.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable dnsmasq-plex
sudo systemctl start dnsmasq-plex
```

## Testing

1. **Test DNS resolution:**
   ```bash
   nslookup plex.example.com <BRIDGE_FAMILY_IP>
   # Should return bridge IP
   ```

2. **Test direct connection:**
   ```bash
   curl -I http://<BRIDGE_FAMILY_IP>:32400/web/
   # Should return 200 OK
   ```

3. **Test NAT (check packet counts):**
   ```bash
   sudo iptables -t nat -L PREROUTING -n -v | grep 32400
   # Packet count should increase when accessing Plex
   ```

4. **Test from family device:**
   - Set device DNS to bridge IP (or use DHCP)
   - Access `https://plex.example.com`
   - Should redirect to `http://<BRIDGE_FAMILY_IP>:32400/web/`
   - Plex should show as LOCAL (no Plex Pass required)

## Troubleshooting

### "Remote streaming requires Plex Pass" still appears

- Verify NAT rules have packet hits: `sudo iptables -t nat -L -v | grep 32400`
- Check Plex logs for source IP
- Ensure bridge IP is in Plex's `allowedNetworks`
- Restart Plex after changing settings

### Connection refused on port 32400

- Check firewall allows outbound: `sudo ufw status`
- Test direct connectivity: `nc -zv <PLEX_IP> 32400`
- Verify FORWARD rules are before DROP rules

### DNS not resolving

- Check dnsmasq is running: `ss -tlnp | grep :53`
- Test DNS query: `nslookup plex.example.com <BRIDGE_IP>`
- Check device is using bridge as DNS server

### nginx redirect not working

- Check nginx config: `nginx -t`
- View nginx logs: `tail -f /var/log/nginx/error.log`
- Ensure redirect is `302` not proxy

## Extending to Other Services

This same approach works for other services. Add to dnsmasq config:

```conf
address=/photos.example.com/<BRIDGE_FAMILY_IP>
```

Add NAT rules for the service port:

```bash
sudo iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport <SERVICE_PORT> \
    -j DNAT --to-destination <SERVER_IP>:<SERVICE_PORT>
```

## Security Considerations

- This setup only allows specific ports (32400) through the bridge
- All other traffic between networks remains blocked
- The bridge acts as a controlled gateway
- Consider additional firewall rules to restrict source IPs if needed

## License

MIT License - See LICENSE file
