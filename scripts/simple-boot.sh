#\!/bin/bash
# Simple Boot Script for Media Server
# Ensures WireGuard starts first with proper network readiness

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$PROJECT_DIR/logs/simple-boot.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Wait for network to be fully ready
wait_for_network() {
    log "Waiting for network readiness..."
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            log "Network is ready"
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 5
    done
    log "Network readiness timeout"
    return 1
}

# Ensure WireGuard kernel module is loaded
ensure_wireguard_module() {
    log "Checking WireGuard kernel module..."
    if \! lsmod | grep -q wireguard; then
        log "Loading WireGuard kernel module..."
        modprobe wireguard || log "Failed to load WireGuard module"
    fi
    log "WireGuard module ready"
}

# Start services with proper ordering
start_services() {
    cd "$PROJECT_DIR"
    
    # Clean up any stale containers
    log "Cleaning up stale containers..."
    docker-compose down --remove-orphans 2>/dev/null || true
    
    # Start WireGuard first and wait for it to be healthy
    log "Starting WireGuard..."
    docker-compose up -d wireguard
    
    # Wait for WireGuard to be healthy
    local attempts=0
    while [ $attempts -lt 24 ]; do
        if docker-compose ps wireguard | grep -q "healthy"; then
            log "WireGuard is healthy"
            break
        fi
        attempts=$((attempts + 1))
        sleep 10
        log "Waiting for WireGuard health check ($attempts/24)..."
    done
    
    # Start remaining services
    log "Starting remaining services..."
    docker-compose up -d
    
    log "All services started"
}

# Main execution
main() {
    mkdir -p "$PROJECT_DIR/logs"
    log "=== Simple boot script starting ==="
    
    wait_for_network || exit 1
    ensure_wireguard_module
    start_services
    
    log "=== Boot completed ==="
}

main
