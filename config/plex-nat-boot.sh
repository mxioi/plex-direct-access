#!/bin/bash
# /etc/network/if-up.d/plex-nat
# Restore Plex/PhotoPrism NAT rules on network interface up
# Make executable: chmod +x /etc/network/if-up.d/plex-nat

# Configuration - UPDATE THESE VALUES
PLEX_SERVER_IP="<ADD-IP-ADDRESS>"
FAMILY_INTERFACE="wlan0"
SERVER_INTERFACE="eth0"

if [ "$IFACE" = "$FAMILY_INTERFACE" ]; then
    # Plex DNAT
    iptables -t nat -C PREROUTING -i "$FAMILY_INTERFACE" -p tcp --dport 32400 \
        -j DNAT --to-destination "$PLEX_SERVER_IP:32400" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$FAMILY_INTERFACE" -p tcp --dport 32400 \
            -j DNAT --to-destination "$PLEX_SERVER_IP:32400"

    # PhotoPrism DNAT
    iptables -t nat -C PREROUTING -i "$FAMILY_INTERFACE" -p tcp --dport 2342 \
        -j DNAT --to-destination "$PLEX_SERVER_IP:2342" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$FAMILY_INTERFACE" -p tcp --dport 2342 \
            -j DNAT --to-destination "$PLEX_SERVER_IP:2342"

    # MASQUERADE rules
    iptables -t nat -C POSTROUTING -d "$PLEX_SERVER_IP" -p tcp --dport 32400 \
        -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -d "$PLEX_SERVER_IP" -p tcp --dport 32400 \
            -j MASQUERADE

    iptables -t nat -C POSTROUTING -d "$PLEX_SERVER_IP" -p tcp --dport 2342 \
        -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -d "$PLEX_SERVER_IP" -p tcp --dport 2342 \
            -j MASQUERADE

    # DOCKER-USER forward rules (use FORWARD if Docker not present)
    if iptables -L DOCKER-USER -n &>/dev/null; then
        iptables -C DOCKER-USER -i "$FAMILY_INTERFACE" -o "$SERVER_INTERFACE" \
            -d "$PLEX_SERVER_IP" -p tcp --dport 32400 -j ACCEPT 2>/dev/null || \
            iptables -I DOCKER-USER -i "$FAMILY_INTERFACE" -o "$SERVER_INTERFACE" \
                -d "$PLEX_SERVER_IP" -p tcp --dport 32400 -j ACCEPT

        iptables -C DOCKER-USER -i "$FAMILY_INTERFACE" -o "$SERVER_INTERFACE" \
            -d "$PLEX_SERVER_IP" -p tcp --dport 2342 -j ACCEPT 2>/dev/null || \
            iptables -I DOCKER-USER -i "$FAMILY_INTERFACE" -o "$SERVER_INTERFACE" \
                -d "$PLEX_SERVER_IP" -p tcp --dport 2342 -j ACCEPT
    fi
fi
