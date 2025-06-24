#\!/bin/bash
# Master Media Server Startup Script
# Agent 3 Implementation - Network-Agnostic Boot System

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/tmp/media-server-startup.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [STARTUP] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

# Wait for network connectivity
wait_for_network() {
    log "Waiting for network connectivity..."
    local max_wait=60
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
            log "Network connectivity established"
            return 0
        fi
        sleep 2
        ((waited+=2))
    done
    
    error_exit "Network connectivity timeout after ${max_wait}s"
}

# Stop existing containers safely
stop_existing_containers() {
    log "Stopping existing containers..."
    cd "$PROJECT_DIR"
    
    # Stop containers in reverse dependency order
    for container in watchtower autoheal jellyfin transmission jackett wireguard; do
        if docker ps -q -f name="$container" | grep -q .; then
            log "Stopping $container..."
            docker stop "$container" || log "Warning: Failed to stop $container"
        fi
    done
    
    # Remove stopped containers
    docker container prune -f >/dev/null 2>&1 || true
}

# Start services in dependency order
start_services() {
    log "Starting services in dependency order..."
    cd "$PROJECT_DIR"
    
    # 1. Start WireGuard VPN first
    log "Starting WireGuard VPN..."
    docker-compose up -d wireguard
    
    # 2. Wait for VPN to establish connection
    log "Waiting for VPN connection..."
    local max_wait=120
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if docker exec wireguard wg show wg0 2>/dev/null | grep -q "latest handshake"; then
            log "VPN connection established"
            break
        fi
        sleep 3
        ((waited+=3))
    done
    
    if [ $waited -ge $max_wait ]; then
        log "Warning: VPN connection timeout, continuing anyway..."
    fi
    
    # 3. Start VPN-dependent services
    log "Starting Transmission and Jackett..."
    docker-compose up -d transmission jackett
    
    # 4. Start media server
    log "Starting Jellyfin..."
    docker-compose up -d jellyfin
    
    # 5. Start monitoring services
    log "Starting monitoring services..."
    docker-compose up -d autoheal watchtower
}

# Verify all services are running
verify_services() {
    log "Verifying service status..."
    local failed_services=()
    
    for service in wireguard transmission jackett jellyfin autoheal watchtower; do
        if \! docker ps --format "table {{.Names}}" | grep -q "^$service$"; then
            failed_services+=("$service")
        fi
    done
    
    if [ ${#failed_services[@]} -eq 0 ]; then
        log "All services started successfully"
        return 0
    else
        log "Failed services: ${failed_services[*]}"
        return 1
    fi
}

# Main startup sequence
main() {
    log "=== Media Server Startup Initiated ==="
    log "Project Directory: $PROJECT_DIR"
    
    # 1. Network connectivity check
    wait_for_network
    
    # 2. Network detection and configuration
    log "Running network detection..."
    if [ -f "$SCRIPT_DIR/network-detect.sh" ]; then
        bash "$SCRIPT_DIR/network-detect.sh" || log "Warning: Network detection failed"
    else
        log "Warning: Network detection script not found"
    fi
    
    # 3. Stop existing containers
    stop_existing_containers
    
    # 4. Start services
    start_services
    
    # 5. Verify startup
    sleep 15  # Allow services to initialize
    if verify_services; then
        log "=== Media Server Startup Complete ==="
        
        # 6. Run health check
        if [ -f "$SCRIPT_DIR/healthcheck.sh" ]; then
            log "Running initial health check..."
            bash "$SCRIPT_DIR/healthcheck.sh" || log "Warning: Health check failed"
        fi
        
        log "Media server is ready\!"
        log "Jellyfin: http://$(hostname -I | awk '{print $1}'):8096"
        log "Transmission: http://$(hostname -I | awk '{print $1}'):9091"
        log "Jackett: http://$(hostname -I | awk '{print $1}'):9117"
        
    else
        error_exit "Service verification failed"
    fi
}

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
