#\!/bin/bash
# Mediaserver Health Monitor and Auto-Recovery Script

LOGFILE="/home/matthewhans/mediaserver-enhanced/logs/monitor.log"
mkdir -p "$(dirname "$LOGFILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

check_service() {
    local service=$1
    local status=$(docker inspect "$service" --format='{{.State.Status}}' 2>/dev/null || echo "missing")
    local health=$(docker inspect "$service" --format='{{.State.Health.Status}}' 2>/dev/null || echo "no-health")
    echo "$status,$health"
}

restart_dependent_services() {
    log "Restarting transmission and jackett to reconnect through WireGuard"
    docker-compose restart transmission jackett
}

main() {
    log "=== Mediaserver Health Check Started ==="
    
    # Check all critical services
    WG_STATUS=$(check_service "wireguard")
    TRANS_STATUS=$(check_service "transmission")
    JACK_STATUS=$(check_service "jackett")
    
    log "Service Status - WireGuard: $WG_STATUS, Transmission: $TRANS_STATUS, Jackett: $JACK_STATUS"
    
    # Check if WireGuard is unhealthy or missing
    if [[ "$WG_STATUS" != "running,healthy" ]]; then
        log "ALERT: WireGuard is not healthy ($WG_STATUS). Attempting recovery..."
        
        # Stop dependent services first
        docker-compose stop transmission jackett
        
        # Restart WireGuard
        docker-compose stop wireguard
        docker-compose up -d wireguard
        
        # Wait for WireGuard to become healthy
        for i in {1..30}; do
            sleep 2
            WG_STATUS=$(check_service "wireguard")
            if [[ "$WG_STATUS" == "running,healthy" ]]; then
                log "WireGuard recovered successfully"
                restart_dependent_services
                break
            elif [[ $i -eq 30 ]]; then
                log "CRITICAL: WireGuard failed to recover after 60 seconds"
                exit 1
            fi
            log "Waiting for WireGuard recovery... ($i/30)"
        done
    fi
    
    # Check if dependent services are running
    if [[ "$TRANS_STATUS" != "running,healthy" ]] || [[ "$JACK_STATUS" != "running,healthy" ]]; then
        if [[ "$WG_STATUS" == "running,healthy" ]]; then
            log "WireGuard healthy but dependent services unhealthy. Restarting them..."
            restart_dependent_services
        fi
    fi
    
    # Final connectivity test
    sleep 5
    TRANS_TEST=$(curl -s -o /dev/null -w "%{http_code}" http://192.168.2.2:9091 || echo "FAIL")
    JACK_TEST=$(curl -s -o /dev/null -w "%{http_code}" http://192.168.2.2:9117 || echo "FAIL")
    
    log "Connectivity Test - Transmission: $TRANS_TEST, Jackett: $JACK_TEST"
    
    if [[ "$TRANS_TEST" =~ ^[0-9]+$ ]] && [[ "$JACK_TEST" =~ ^[0-9]+$ ]]; then
        log "SUCCESS: All services accessible and healthy"
    else
        log "WARNING: Services not fully accessible"
    fi
    
    log "=== Health Check Complete ==="
}

# Run the main function
cd /home/matthewhans/mediaserver-enhanced
main
EOF < /dev/null