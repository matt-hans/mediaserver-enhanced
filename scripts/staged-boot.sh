#!/bin/bash

# Staged Boot Manager for Enhanced Media Server
# =============================================
# Implements robust, staged boot process to handle Raspberry Pi timing issues
# Stage 1: Network verification and Docker preparation
# Stage 2: VPN establishment with extended timeouts
# Stage 3: Service startup with dependency management

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly LOGS_DIR="$PROJECT_DIR/logs"
readonly LOG_FILE="$LOGS_DIR/staged-boot.log"
readonly LOCK_FILE="/tmp/staged-boot.lock"
readonly PID_FILE="/var/run/mediaserver-enhanced.pid"

# Boot stage timeouts (seconds) - Extended for Pi
readonly NETWORK_TIMEOUT=300
readonly VPN_TIMEOUT=240
readonly SERVICE_TIMEOUT=360
readonly HEALTH_TIMEOUT=180

# Service management
readonly COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
readonly COMPOSE_PROJECT="mediaserver"

# Create logs directory
mkdir -p "$LOGS_DIR"

# Enhanced logging with rotation
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Rotate log if too large (>5MB)
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 5242880 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null || true
    fi
    
    local log_entry="[$timestamp] [staged-boot] [$level] $message"
    echo "$log_entry" | tee -a "$LOG_FILE"
    
    # Send to systemd journal
    if command -v systemd-cat >/dev/null 2>&1; then
        echo "[$level] $message" | systemd-cat -t mediaserver-enhanced
    fi
}

# Error handling with cleanup
error_exit() {
    log "ERROR" "$1"
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    log "INFO" "Performing cleanup..."
    
    # Remove lock file
    rm -f "$LOCK_FILE"
    
    # Clean up stale containers if needed
    docker container prune -f 2>/dev/null || true
}

# Lock management
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            error_exit "Another instance is already running (PID: $lock_pid)"
        fi
        log "INFO" "Removing stale lock file"
        rm -f "$LOCK_FILE"
    fi
    
    echo $$ > "$LOCK_FILE"
    log "INFO" "Lock acquired (PID: $$)"
}

# Signal handling
setup_signal_handlers() {
    trap 'log "INFO" "Received TERM signal"; stop_services; exit 0' TERM
    trap 'log "INFO" "Received INT signal"; stop_services; exit 0' INT
    trap 'cleanup' EXIT
}

# Stage 1: Network and system verification
stage_network_verification() {
    log "INFO" "Stage 1: Network and system verification"
    
    local start_time=$(date +%s)
    local timeout_time=$((start_time + NETWORK_TIMEOUT))
    
    # Check Docker service
    log "INFO" "Verifying Docker service..."
    if ! systemctl is-active --quiet docker; then
        log "INFO" "Starting Docker service..."
        systemctl start docker || error_exit "Failed to start Docker service"
        sleep 10
    fi
    
    # Wait for Docker socket
    while [ $(date +%s) -lt $timeout_time ]; do
        if docker info >/dev/null 2>&1; then
            log "INFO" "Docker service is ready"
            break
        fi
        log "DEBUG" "Waiting for Docker service..."
        sleep 5
    done
    
    # Verify network connectivity
    log "INFO" "Verifying network connectivity..."
    local network_ready=false
    
    while [ $(date +%s) -lt $timeout_time ]; do
        if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
            log "INFO" "Network connectivity verified"
            network_ready=true
            break
        fi
        log "DEBUG" "Waiting for network connectivity..."
        sleep 10
    done
    
    if ! $network_ready; then
        error_exit "Network connectivity verification failed"
    fi
    
    # System resource check
    log "INFO" "Checking system resources..."
    local free_mem=$(free -m | awk 'NR==2{printf "%.0f", $7}')
    local free_disk=$(df -h "$PROJECT_DIR" | awk 'NR==2{print $4}' | sed 's/G//')
    
    log "INFO" "Available memory: ${free_mem}MB"
    log "INFO" "Available disk space: ${free_disk}GB"
    
    if [ "$free_mem" -lt 100 ]; then
        log "WARNING" "Low memory available: ${free_mem}MB"
    fi
    
    log "INFO" "Stage 1 completed successfully"
}

# Stage 2: VPN establishment
stage_vpn_establishment() {
    log "INFO" "Stage 2: VPN establishment"
    
    # Clean up any existing WireGuard containers
    log "INFO" "Cleaning up existing WireGuard instances..."
    docker stop wireguard 2>/dev/null || true
    docker rm wireguard 2>/dev/null || true
    
    # Start WireGuard container
    log "INFO" "Starting WireGuard container..."
    cd "$PROJECT_DIR"
    docker-compose -f "$COMPOSE_FILE" up -d wireguard
    
    # Extended wait for VPN establishment
    log "INFO" "Waiting for VPN establishment (timeout: ${VPN_TIMEOUT}s)..."
    local start_time=$(date +%s)
    local timeout_time=$((start_time + VPN_TIMEOUT))
    local vpn_ready=false
    
    while [ $(date +%s) -lt $timeout_time ]; do
        # Check if container is running
        if ! docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -q wireguard; then
            log "WARNING" "WireGuard container not running, restarting..."
            docker-compose -f "$COMPOSE_FILE" up -d wireguard
            sleep 10
            continue
        fi
        
        # Test VPN connectivity using health check
        if docker exec wireguard /config/wireguard-health-check.sh quick 2>/dev/null; then
            log "INFO" "VPN connection established and verified"
            vpn_ready=true
            break
        fi
        
        local elapsed=$((($(date +%s) - start_time)))
        log "DEBUG" "VPN establishment attempt: ${elapsed}s elapsed"
        sleep 15
    done
    
    if ! $vpn_ready; then
        log "ERROR" "VPN establishment failed after ${VPN_TIMEOUT}s"
        # Try one more time with container restart
        log "INFO" "Attempting VPN recovery..."
        docker-compose -f "$COMPOSE_FILE" restart wireguard
        sleep 30
        
        if docker exec wireguard /config/wireguard-health-check.sh quick 2>/dev/null; then
            log "INFO" "VPN recovery successful"
        else
            error_exit "VPN establishment failed after recovery attempt"
        fi
    fi
    
    log "INFO" "Stage 2 completed successfully"
}

# Stage 3: Service startup
stage_service_startup() {
    log "INFO" "Stage 3: Service startup"
    
    cd "$PROJECT_DIR"
    
    # Start remaining services with staggered approach
    local services=("jellyfin" "autoheal" "watchtower" "transmission" "jackett")
    
    for service in "${services[@]}"; do
        log "INFO" "Starting service: $service"
        docker-compose -f "$COMPOSE_FILE" up -d "$service"
        
        # Brief wait between services
        sleep 10
        
        # Check if service started
        if docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -q "$service"; then
            log "INFO" "Service $service started successfully"
        else
            log "WARNING" "Service $service may have failed to start"
        fi
    done
    
    # Wait for all services to become healthy
    log "INFO" "Waiting for services to become healthy..."
    local start_time=$(date +%s)
    local timeout_time=$((start_time + HEALTH_TIMEOUT))
    
    while [ $(date +%s) -lt $timeout_time ]; do
        local unhealthy_count=$(docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -c 'unhealthy' || echo 0)
        local starting_count=$(docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -c 'health: starting' || echo 0)
        
        if [ "$unhealthy_count" -eq 0 ] && [ "$starting_count" -eq 0 ]; then
            log "INFO" "All services are healthy"
            break
        fi
        
        log "DEBUG" "Waiting for services: $starting_count starting, $unhealthy_count unhealthy"
        sleep 15
    done
    
    log "INFO" "Stage 3 completed successfully"
}

# Start all services
start_services() {
    log "INFO" "Starting enhanced media server with staged boot process"
    
    acquire_lock
    setup_signal_handlers
    
    # Execute boot stages
    stage_network_verification
    stage_vpn_establishment  
    stage_service_startup
    
    # Save PID for systemd
    echo $$ > "$PID_FILE"
    
    log "INFO" "Enhanced media server startup completed successfully"
    
    # Keep running for systemd Type=forking
    while true; do
        sleep 60
        # Basic health monitoring
        if ! docker ps | grep -q wireguard; then
            log "WARNING" "WireGuard container not running - attempting restart"
            cd "$PROJECT_DIR"
            docker-compose -f "$COMPOSE_FILE" up -d wireguard
        fi
    done
}

# Stop all services
stop_services() {
    log "INFO" "Stopping enhanced media server"
    
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$PROJECT_DIR"
        docker-compose -f "$COMPOSE_FILE" down --timeout 30
        log "INFO" "All services stopped"
    fi
    
    rm -f "$PID_FILE"
}

# Reload services (for updates)
reload_services() {
    log "INFO" "Reloading enhanced media server"
    
    cd "$PROJECT_DIR"
    docker-compose -f "$COMPOSE_FILE" pull --quiet
    docker-compose -f "$COMPOSE_FILE" up -d --remove-orphans
    
    log "INFO" "Services reloaded"
}

# Main function
main() {
    local command="${1:-start}"
    
    case $command in
        "start")
            start_services
            ;;
        "stop")
            stop_services
            ;;
        "reload"|"restart")
            reload_services
            ;;
        "status")
            cd "$PROJECT_DIR"
            docker-compose -f "$COMPOSE_FILE" ps
            ;;
        *)
            echo "Usage: $0 {start|stop|reload|restart|status}"
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
