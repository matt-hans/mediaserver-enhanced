#!/bin/bash
# Media Server Health Monitoring Script
# =====================================
# Monitors VPN connectivity, container health, disk space, and performs recovery actions

set -euo pipefail

# Configuration
LOG_FILE="/var/log/mediaserver-health.log"
NOTIFICATION_SENT="/tmp/mediaserver-notification-sent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Notification management
send_notification() {
    local message=$1
    if [ ! -f "$NOTIFICATION_SENT" ]; then
        # Send notification via your preferred method
        echo "$message" | mail -s "Media Server Alert" admin@example.com 2>/dev/null || true
        # Alternative: webhook notification
        # curl -X POST -H 'Content-Type: application/json' \
        #      -d "{\"text\":\"$message\"}" \
        #      "$WEBHOOK_URL" 2>/dev/null || true
        touch "$NOTIFICATION_SENT"
        log "NOTIFICATION: $message"
    fi
}

clear_notification() {
    rm -f "$NOTIFICATION_SENT"
}

# VPN connectivity checks
check_vpn() {
    log "Checking VPN connectivity..."
    
    # Check if WireGuard container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^wireguard$"; then
        log "ERROR: WireGuard container is not running"
        return 1
    fi
    
    # Check VPN tunnel connectivity
    if ! docker exec wireguard ping -c1 -W3 8.8.8.8 &>/dev/null; then
        log "ERROR: VPN tunnel connectivity failed"
        send_notification "VPN tunnel connectivity failed on media server"
        return 1
    fi
    
    # Check if we're exposing our real IP (critical security check)
    local real_ip vpn_ip
    real_ip=$(curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null || echo "unknown")
    vpn_ip=$(docker exec wireguard curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null || echo "unknown")
    
    if [ "$real_ip" != "unknown" ] && [ "$vpn_ip" != "unknown" ] && [ "$real_ip" = "$vpn_ip" ]; then
        log "CRITICAL: VPN is not masking IP address! Real IP exposed: $real_ip"
        send_notification "CRITICAL: VPN failure - Real IP exposed on media server"
        
        # Emergency stop torrenting services
        docker-compose -f "$COMPOSE_DIR/docker-compose.yml" stop transmission jackett
        
        # Restart VPN and dependent services
        docker-compose -f "$COMPOSE_DIR/docker-compose.yml" restart wireguard
        sleep 30
        docker-compose -f "$COMPOSE_DIR/docker-compose.yml" start transmission jackett
        
        return 1
    fi
    
    log "VPN connectivity OK (External IP: $vpn_ip)"
    return 0
}

# Container health checks
check_container() {
    local container=$1
    local service=$2
    
    log "Checking container: $container"
    
    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log "ERROR: Container $container is not running"
        docker-compose -f "$COMPOSE_DIR/docker-compose.yml" up -d "$service"
        return 1
    fi
    
    # Check container health status
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
    
    case "$health" in
        "healthy")
            log "Container $container is healthy"
            return 0
            ;;
        "unhealthy")
            log "WARNING: Container $container is unhealthy - restarting"
            docker-compose -f "$COMPOSE_DIR/docker-compose.yml" restart "$service"
            return 1
            ;;
        "starting")
            log "INFO: Container $container is still starting"
            return 0
            ;;
        "none")
            log "INFO: Container $container has no health check configured"
            return 0
            ;;
        *)
            log "WARNING: Container $container has unknown health status: $health"
            return 1
            ;;
    esac
}

# Disk space monitoring
check_disk_space() {
    log "Checking disk space..."
    
    local threshold=90
    local critical_threshold=95
    local downloads_path="$COMPOSE_DIR/storage/downloads"
    
    # Check if downloads directory exists
    if [ ! -d "$downloads_path" ]; then
        log "WARNING: Downloads directory does not exist: $downloads_path"
        return 0
    fi
    
    local usage
    usage=$(df -h "$downloads_path" | awk 'NR==2 {print $5}' | sed 's/%//' || echo "0")
    
    if [ "$usage" -gt "$threshold" ]; then
        log "WARNING: Disk space usage is at ${usage}%"
        send_notification "Media server disk space is at ${usage}%"
        
        # Critical space - pause all torrents
        if [ "$usage" -gt "$critical_threshold" ]; then
            log "CRITICAL: Disk space critically low (${usage}%) - pausing all torrents"
            
            # Get transmission credentials from env file
            source "$COMPOSE_DIR/.env" 2>/dev/null || true
            docker exec transmission transmission-remote \
                -n "${TRANSMISSION_USER:-admin}:${TRANSMISSION_PASS:-password}" \
                --torrent all --stop 2>/dev/null || true
            
            send_notification "CRITICAL: All torrents paused due to low disk space (${usage}%)"
        fi
    else
        log "Disk space OK (${usage}% used)"
    fi
}

# Service connectivity tests
check_service_connectivity() {
    log "Checking inter-service connectivity..."
    
    # Test if Transmission can reach Jackett through VPN
    if docker exec transmission curl -sf --max-time 10 http://localhost:9117/UI/Login &>/dev/null; then
        log "Transmission -> Jackett connectivity OK"
    else
        log "ERROR: Transmission cannot reach Jackett"
        docker-compose -f "$COMPOSE_DIR/docker-compose.yml" restart transmission jackett
        return 1
    fi
    
    # Test if Jellyfin can access media files
    if docker exec jellyfin test -r /media &>/dev/null; then
        log "Jellyfin media access OK"
    else
        log "WARNING: Jellyfin cannot access media directory"
        return 1
    fi
    
    return 0
}

# Performance monitoring
check_performance() {
    log "Checking system performance..."
    
    # Check system load
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    
    # For Raspberry Pi, load > 3.0 is concerning
    if (( $(echo "$load_avg > 3.0" | bc -l 2>/dev/null || echo 0) )); then
        log "WARNING: High system load: $load_avg"
    else
        log "System load OK: $load_avg"
    fi
    
    # Check memory usage
    local mem_usage
    mem_usage=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}')
    
    if [ "$mem_usage" -gt 90 ]; then
        log "WARNING: High memory usage: ${mem_usage}%"
        # Restart memory-heavy services if critically high
        if [ "$mem_usage" -gt 95 ]; then
            log "CRITICAL: Restarting services due to memory pressure"
            docker-compose -f "$COMPOSE_DIR/docker-compose.yml" restart jellyfin
        fi
    else
        log "Memory usage OK: ${mem_usage}%"
    fi
}

# Main health check routine
main() {
    log "=== Starting Media Server Health Check ==="
    
    local all_healthy=true
    local failed_checks=()
    
    # VPN Check (critical)
    if ! check_vpn; then
        all_healthy=false
        failed_checks+=("VPN")
    fi
    
    # Container Health Checks
    for container in wireguard transmission jackett jellyfin autoheal watchtower; do
        if ! check_container "$container" "$container"; then
            all_healthy=false
            failed_checks+=("$container")
        fi
    done
    
    # System Resource Checks
    check_disk_space
    check_performance
    
    # Service Connectivity Checks
    if ! check_service_connectivity; then
        all_healthy=false
        failed_checks+=("connectivity")
    fi
    
    # Summary
    if [ "$all_healthy" = true ]; then
        log "=== All services healthy ==="
        clear_notification
    else
        local failed_list
        failed_list=$(IFS=', '; echo "${failed_checks[*]}")
        log "=== Health check completed with issues: $failed_list ==="
        send_notification "Media server health issues detected: $failed_list"
    fi
    
    log "=== Health check complete ==="
    echo ""  # Add blank line for log readability
}

# Error handling
trap 'log "ERROR: Health check script failed at line $LINENO"' ERR

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Run main function
main "$@"