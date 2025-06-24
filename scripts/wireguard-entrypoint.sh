#\!/bin/bash

# WireGuard VPN Kill Switch Entrypoint Script
# ===========================================
# This script implements a comprehensive VPN kill switch with IPv6 support
# Ensures all traffic is routed through VPN or blocked entirely
# Designed for LinuxServer.io WireGuard container

set -euo pipefail

# Configuration
SCRIPT_NAME="wireguard-entrypoint"
LOG_FILE="/config/vpn-killswitch.log"
INTERFACE="wg0"
VPN_SUBNET="10.13.13.0/24"
DOCKER_SUBNET="172.20.0.0/16"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$SCRIPT_NAME] [$level] $message" | tee -a "$LOG_FILE"
}

# Error handler
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Apply VPN kill switch rules
apply_killswitch() {
    log "INFO" "Applying VPN kill switch rules..."
    
    # Flush existing rules
    iptables -F OUTPUT 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true
    ip6tables -F OUTPUT 2>/dev/null || true
    ip6tables -F FORWARD 2>/dev/null || true
    
    # IPv4 Kill Switch Rules
    # Allow loopback
    iptables -A OUTPUT -o lo -j ACCEPT
    
    # Allow Docker internal communication
    iptables -A OUTPUT -d $VPN_SUBNET -j ACCEPT
    iptables -A OUTPUT -d $DOCKER_SUBNET -j ACCEPT
    
    # Allow WireGuard communication
    iptables -A OUTPUT -o $INTERFACE -j ACCEPT
    
    # Allow established connections
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow DNS to specific servers (before VPN is up)
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    
    # Allow WireGuard handshake
    iptables -A OUTPUT -p udp --dport 51820 -j ACCEPT
    
    # Allow local network communication (for container management)
    iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
    iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
    iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
    
    # DROP all other IPv4 traffic
    iptables -A OUTPUT -j DROP
    
    # IPv6 Kill Switch Rules (completely block IPv6 unless explicitly allowed)
    if [ "${DISABLE_IPV6:-1}" \!= "1" ]; then
        # Allow loopback
        ip6tables -A OUTPUT -o lo -j ACCEPT
        
        # Allow established connections
        ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        
        # Allow local IPv6 communication
        ip6tables -A OUTPUT -d fe80::/10 -j ACCEPT
        ip6tables -A OUTPUT -d ::1/128 -j ACCEPT
        
        # DROP all other IPv6 traffic
        ip6tables -A OUTPUT -j DROP
    else
        # Complete IPv6 block
        ip6tables -A OUTPUT -j DROP
    fi
    
    log "INFO" "VPN kill switch rules applied successfully"
}

# Verify VPN connection
verify_vpn_connection() {
    log "INFO" "Verifying VPN connection..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ip addr show $INTERFACE >/dev/null 2>&1; then
            local vpn_ip=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
            if [ -n "$vpn_ip" ]; then
                log "INFO" "VPN interface $INTERFACE is up with IP: $vpn_ip"
                
                # Test external connectivity through VPN
                if timeout 10 curl -s --max-time 5 https://ipinfo.io/ip >/dev/null; then
                    local external_ip=$(timeout 10 curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null || echo "unknown")
                    log "INFO" "VPN connection verified. External IP: $external_ip"
                    return 0
                fi
            fi
        fi
        
        log "INFO" "Attempt $attempt/$max_attempts: VPN not ready, waiting..."
        sleep 5
        ((attempt++))
    done
    
    error_exit "VPN connection verification failed after $max_attempts attempts"
}

# Monitor VPN connection
monitor_vpn() {
    log "INFO" "Starting VPN connection monitor..."
    
    while true; do
        if \! ip addr show $INTERFACE >/dev/null 2>&1; then
            log "WARNING" "VPN interface $INTERFACE is down\! Applying emergency kill switch..."
            apply_killswitch
        else
            # Verify external IP is not local
            local external_ip=$(timeout 10 curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null || echo "unknown")
            if [[ $external_ip =~ ^192\.168\. ]] || [[ $external_ip =~ ^10\. ]] || [[ $external_ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
                log "WARNING" "Detected local IP leak: $external_ip. Reapplying kill switch..."
                apply_killswitch
            fi
        fi
        
        sleep 30
    done
}

# Cleanup function
cleanup() {
    log "INFO" "Cleaning up VPN kill switch..."
    # Note: We don't flush rules here as that would break the kill switch
    # Rules will be cleaned up when container stops
}

# Main execution
main() {
    log "INFO" "Starting VPN kill switch initialization..."
    
    # Set up signal handlers
    trap cleanup EXIT
    trap 'log "INFO" "Received termination signal"; exit 0' TERM INT
    
    # Wait for WireGuard service to initialize
    log "INFO" "Waiting for WireGuard service to initialize..."
    sleep 10
    
    # Apply initial kill switch rules
    apply_killswitch
    
    # Verify VPN connection
    verify_vpn_connection
    
    # Start monitoring (this runs in background)
    monitor_vpn &
    MONITOR_PID=$\!
    
    log "INFO" "VPN kill switch initialization complete. Monitor PID: $MONITOR_PID"
    
    # Keep the script running
    wait $MONITOR_PID
}

# Execute main function if script is run directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
