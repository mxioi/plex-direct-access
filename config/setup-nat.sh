#!/bin/bash
# Setup NAT rules for Plex direct access
# Run with sudo

set -e

# Configuration - UPDATE THESE VALUES
PLEX_SERVER_IP="<ADD-IP-ADDRESS>"
PLEX_PORT="32400"
FAMILY_INTERFACE="wlan0"
SERVER_INTERFACE="eth0"

# Optional: Additional services
PHOTOPRISM_PORT="2342"

echo "Setting up NAT rules for Plex direct access..."

# DNAT - Redirect incoming connections to Plex
iptables -t nat -C PREROUTING -i "$FAMILY_INTERFACE" -p tcp --dport "$PLEX_PORT" \
    -j DNAT --to-destination "$PLEX_SERVER_IP:$PLEX_PORT" 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$FAMILY_INTERFACE" -p tcp --dport "$PLEX_PORT" \
        -j DNAT --to-destination "$PLEX_SERVER_IP:$PLEX_PORT"
echo "  Added DNAT rule for Plex"

# MASQUERADE - Ensure return traffic comes back through bridge
iptables -t nat -C POSTROUTING -d "$PLEX_SERVER_IP" -p tcp --dport "$PLEX_PORT" \
    -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -d "$PLEX_SERVER_IP" -p tcp --dport "$PLEX_PORT" \
        -j MASQUERADE
echo "  Added MASQUERADE rule for Plex"

# FORWARD rules - Use DOCKER-USER if Docker is present, otherwise FORWARD
if iptables -L DOCKER-USER -n &>/dev/null; then
    FORWARD_CHAIN="DOCKER-USER"
else
    FORWARD_CHAIN="FORWARD"
fi

iptables -C "$FORWARD_CHAIN" -i "$FAMILY_INTERFACE" -o "$SERVER_INTERFACE" \
    -d "$PLEX_SERVER_IP" -p tcp --dport "$PLEX_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I "$FORWARD_CHAIN" -i "$FAMILY_INTERFACE" -o "$SERVER_INTERFACE" \
        -d "$PLEX_SERVER_IP" -p tcp --dport "$PLEX_PORT" -j ACCEPT
echo "  Added FORWARD rule (inbound) to $FORWARD_CHAIN"

iptables -C "$FORWARD_CHAIN" -i "$SERVER_INTERFACE" -o "$FAMILY_INTERFACE" \
    -s "$PLEX_SERVER_IP" -p tcp --sport "$PLEX_PORT" \
    -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I "$FORWARD_CHAIN" -i "$SERVER_INTERFACE" -o "$FAMILY_INTERFACE" \
        -s "$PLEX_SERVER_IP" -p tcp --sport "$PLEX_PORT" \
        -m state --state ESTABLISHED,RELATED -j ACCEPT
echo "  Added FORWARD rule (return traffic) to $FORWARD_CHAIN"

# Optional: Add PhotoPrism rules
if [ -n "$PHOTOPRISM_PORT" ]; then
    iptables -t nat -C PREROUTING -i "$FAMILY_INTERFACE" -p tcp --dport "$PHOTOPRISM_PORT" \
        -j DNAT --to-destination "$PLEX_SERVER_IP:$PHOTOPRISM_PORT" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$FAMILY_INTERFACE" -p tcp --dport "$PHOTOPRISM_PORT" \
            -j DNAT --to-destination "$PLEX_SERVER_IP:$PHOTOPRISM_PORT"

    iptables -t nat -C POSTROUTING -d "$PLEX_SERVER_IP" -p tcp --dport "$PHOTOPRISM_PORT" \
        -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -d "$PLEX_SERVER_IP" -p tcp --dport "$PHOTOPRISM_PORT" \
            -j MASQUERADE

    iptables -C "$FORWARD_CHAIN" -i "$FAMILY_INTERFACE" -o "$SERVER_INTERFACE" \
        -d "$PLEX_SERVER_IP" -p tcp --dport "$PHOTOPRISM_PORT" -j ACCEPT 2>/dev/null || \
        iptables -I "$FORWARD_CHAIN" -i "$FAMILY_INTERFACE" -o "$SERVER_INTERFACE" \
            -d "$PLEX_SERVER_IP" -p tcp --dport "$PHOTOPRISM_PORT" -j ACCEPT

    echo "  Added PhotoPrism NAT rules"
fi

echo ""
echo "NAT rules configured successfully!"
echo ""
echo "Verify with:"
echo "  sudo iptables -t nat -L PREROUTING -n -v | grep $PLEX_PORT"
echo "  sudo iptables -L $FORWARD_CHAIN -n -v | grep $PLEX_PORT"
