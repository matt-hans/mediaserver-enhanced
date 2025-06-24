#\!/bin/bash
# Bulletproof Mediaserver Failsafe Monitor

LOGFILE="/home/matthewhans/mediaserver-enhanced/logs/failsafe.log"
mkdir -p "$(dirname "$LOGFILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [FAILSAFE] $1" | tee -a "$LOGFILE"
}

check_containers() {
    local wg_exists=$(docker ps --filter "name=wireguard" --format "{{.Names}}" | wc -l)
    local wg_healthy=$(docker inspect wireguard --format='{{.State.Health.Status}}' 2>/dev/null || echo "missing")
    local trans_exists=$(docker ps --filter "name=transmission" --format "{{.Names}}" | wc -l)
    local jack_exists=$(docker ps --filter "name=jackett" --format "{{.Names}}" | wc -l)
    
    echo "$wg_exists,$wg_healthy,$trans_exists,$jack_exists"
}

test_connectivity() {
    local trans_code=$(curl -s -o /dev/null -w "%{http_code}" http://192.168.2.2:9091 2>/dev/null || echo "FAIL")
    local jack_code=$(curl -s -o /dev/null -w "%{http_code}" http://192.168.2.2:9117 2>/dev/null || echo "FAIL")
    echo "$trans_code,$jack_code"
}

emergency_recovery() {
    log "EMERGENCY: Performing full service recovery"
    
    # Stop everything cleanly
    docker-compose down
    sleep 5
    
    # Clean up orphaned resources
    docker system prune -f >/dev/null 2>&1
    
    # Start fresh
    docker-compose up -d --remove-orphans
    
    # Wait for WireGuard
    for i in {1..60}; do
        if docker inspect wireguard --format='{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
            log "WireGuard recovered after $i attempts"
            break
        elif [[ $i -eq 60 ]]; then
            log "CRITICAL: WireGuard recovery failed"
            return 1
        fi
        sleep 2
    done
    
    # Restart dependent services
    docker-compose stop transmission jackett
    sleep 3
    docker-compose up -d transmission jackett
    
    log "Emergency recovery completed"
}

main() {
    cd /home/matthewhans/mediaserver-enhanced
    
    # Check container status
    STATUS=$(check_containers)
    WG_EXISTS=$(echo $STATUS | cut -d',' -f1)
    WG_HEALTH=$(echo $STATUS | cut -d',' -f2)
    TRANS_EXISTS=$(echo $STATUS | cut -d',' -f3)
    JACK_EXISTS=$(echo $STATUS | cut -d',' -f4)
    
    log "Container Status - WG:$WG_EXISTS/$WG_HEALTH, Trans:$TRANS_EXISTS, Jack:$JACK_EXISTS"
    
    # Critical failure detection
    if [[ "$WG_EXISTS" == "0" ]] || [[ "$WG_HEALTH" != "healthy" ]] || [[ "$TRANS_EXISTS" == "0" ]] || [[ "$JACK_EXISTS" == "0" ]]; then
        log "ALERT: Critical service failure detected"
        emergency_recovery
        return $?
    fi
    
    # Connectivity test
    CONNECTIVITY=$(test_connectivity)
    TRANS_CODE=$(echo $CONNECTIVITY | cut -d',' -f1)
    JACK_CODE=$(echo $CONNECTIVITY | cut -d',' -f2)
    
    if [[ "$TRANS_CODE" == "FAIL" ]] || [[ "$JACK_CODE" == "FAIL" ]]; then
        log "ALERT: Connectivity failure - Trans:$TRANS_CODE, Jack:$JACK_CODE"
        
        # Try simple restart first
        log "Attempting service restart"
        docker-compose restart transmission jackett
        sleep 10
        
        # Re-test
        RETRY_CONNECTIVITY=$(test_connectivity)
        RETRY_TRANS=$(echo $RETRY_CONNECTIVITY | cut -d',' -f1)
        RETRY_JACK=$(echo $RETRY_CONNECTIVITY | cut -d',' -f2)
        
        if [[ "$RETRY_TRANS" == "FAIL" ]] || [[ "$RETRY_JACK" == "FAIL" ]]; then
            log "Simple restart failed. Initiating emergency recovery"
            emergency_recovery
        else
            log "Service restart successful - Trans:$RETRY_TRANS, Jack:$RETRY_JACK"
        fi
    else
        log "All services healthy - Trans:$TRANS_CODE, Jack:$JACK_CODE"
    fi
}

main "$@"
EOF < /dev/null