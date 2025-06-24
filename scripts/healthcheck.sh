#\!/bin/bash
# Comprehensive Health Check Script
# Agent 3 Implementation

set -euo pipefail

LOG_FILE="/tmp/healthcheck.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HEALTHCHECK] $1" | tee -a "$LOG_FILE"
}

# Check VPN connectivity by comparing IPs
check_vpn_connectivity() {
    log "Checking VPN connectivity..."
    
    # Get IP through VPN
    local vpn_ip=$(timeout 10 docker exec wireguard curl -s https://ipinfo.io/ip 2>/dev/null || echo "unknown")
    
    # Get direct IP (bypass VPN)
    local direct_ip=$(timeout 10 curl -s https://ipinfo.io/ip 2>/dev/null || echo "unknown")
    
    if [[ "$vpn_ip" \!= "unknown" ]] && [[ "$direct_ip" \!= "unknown" ]] && [[ "$vpn_ip" \!= "$direct_ip" ]]; then
        log "VPN Connected: $vpn_ip (Direct: $direct_ip)"
        return 0
    else
        log "VPN Check Failed: VPN=$vpn_ip, Direct=$direct_ip"
        return 1
    fi
}

# Check service accessibility
check_service_accessibility() {
    local failed=0
    
    log "Checking service accessibility..."
    
    # Check Jellyfin
    if \! timeout 10 curl -sf http://localhost:8096/health &>/dev/null; then
        log "Jellyfin unreachable"
        ((failed++))
    else
        log "Jellyfin accessible"
    fi
    
    # Check Jackett (through VPN)
    if \! timeout 10 curl -sf http://localhost:9117 &>/dev/null; then
        log "Jackett unreachable"
        ((failed++))
    else
        log "Jackett accessible"
    fi
    
    # Check Transmission (through VPN)
    if \! timeout 10 curl -sf http://localhost:9091/transmission/web/ &>/dev/null; then
        log "Transmission unreachable"
        ((failed++))
    else
        log "Transmission accessible"
    fi
    
    return $failed
}

# Main health check
main() {
    log "Starting comprehensive health check..."
    
    local exit_code=0
    
    # Check VPN connectivity
    if \! check_vpn_connectivity; then
        exit_code=1
    fi
    
    # Check service accessibility
    if \! check_service_accessibility; then
        exit_code=1
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        log "All systems operational"
    else
        log "Health check failed - some issues detected"
    fi
    
    return $exit_code
}

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
