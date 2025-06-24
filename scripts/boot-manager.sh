#!/bin/bash

# Enhanced Boot Manager Script
# ============================
# Implements staged boot process: Network verification → VPN establishment → Service startup
# Author: Media Server Development Team
# Version: 2.0

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly CONFIG_DIR="$PROJECT_DIR/config"
readonly LOGS_DIR="$PROJECT_DIR/logs"
readonly VPN_CONFIG_DIR="$CONFIG_DIR/wireguard"
readonly LOCK_FILE="/tmp/boot-manager.lock"
readonly LOG_FILE="$LOGS_DIR/boot-manager.log"

# Boot stages
readonly STAGE_NETWORK="network"
readonly STAGE_VPN="vpn"
readonly STAGE_SERVICES="services"

# Timeouts (seconds)
readonly NETWORK_TIMEOUT=300
readonly VPN_TIMEOUT=180
readonly SERVICE_TIMEOUT=300

# Create logs directory if it doesn't exist
mkdir -p "$LOGS_DIR"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    
    # Also log to systemd journal
    if command -v systemd-cat >/dev/null 2>&1; then
        echo "[$level] $message" | systemd-cat -t boot-manager
    fi
}

# Error handling
error_exit() {
    log "ERROR" "$1"
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi
}

# Trap for cleanup
trap cleanup EXIT INT TERM

# Lock mechanism to prevent concurrent runs
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log "ERROR" "Another instance is already running (PID: $lock_pid)"
            exit 1
        else
            log "WARN" "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log "INFO" "Lock acquired"
}

# Network connectivity verification
verify_network_connectivity() {
    local stage="$STAGE_NETWORK"
    local start_time=$(date +%s)
    local timeout=$NETWORK_TIMEOUT
    
    log "INFO" "Starting network connectivity verification"
    
    # Test targets for network verification
    local test_targets=(
        "8.8.8.8"          # Google DNS
        "1.1.1.1"          # Cloudflare DNS
        "208.67.222.222"   # OpenDNS
    )
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $elapsed -gt $timeout ]]; then
            error_exit "Network connectivity verification timed out after ${timeout}s"
        fi
        
        log "INFO" "Testing network connectivity (attempt $((elapsed / 5 + 1)))"
        
        local connected=false
        for target in "${test_targets[@]}"; do
            if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
                log "INFO" "Network connectivity verified with $target"
                connected=true
                break
            fi
        done
        
        if $connected; then
            # Additional DNS resolution test
            if nslookup google.com >/dev/null 2>&1; then
                log "INFO" "DNS resolution verified"
                break
            else
                log "WARN" "DNS resolution failed, retrying"
            fi
        else
            log "WARN" "No network connectivity, waiting 5s before retry"
        fi
        
        sleep 5
    done
    
    log "INFO" "Network connectivity verification completed"
    return 0
}

# VPN establishment with failover
establish_vpn_connection() {
    local stage="$STAGE_VPN"
    local start_time=$(date +%s)
    local timeout=$VPN_TIMEOUT
    
    log "INFO" "Starting VPN establishment"
    
    # Check if VPN manager script exists
    local vpn_manager="$SCRIPT_DIR/vpn-manager.sh"
    if [[ ! -x "$vpn_manager" ]]; then
        error_exit "VPN manager script not found or not executable: $vpn_manager"
    fi
    
    # Call VPN manager to establish connection
    if "$vpn_manager" connect; then
        log "INFO" "VPN connection established successfully"
    else
        error_exit "Failed to establish VPN connection"
    fi
    
    # Verify VPN is working by checking IP change
    local original_ip
    local vpn_ip
    
    # Get current IP (should be VPN IP now)
    vpn_ip=$(curl -s --max-time 10 https://api.ipify.org || echo "")
    
    if [[ -n "$vpn_ip" ]]; then
        log "INFO" "VPN IP confirmed: $vpn_ip"
    else
        log "WARN" "Could not verify VPN IP, but connection appears established"
    fi
    
    return 0
}

# Service startup with dependency management
start_services() {
    local stage="$STAGE_SERVICES"
    local start_time=$(date +%s)
    local timeout=$SERVICE_TIMEOUT
    
    log "INFO" "Starting services"
    
    # Change to project directory
    cd "$PROJECT_DIR"
    
    # Check if docker-compose is available
    if ! command -v docker-compose >/dev/null 2>&1; then
        error_exit "docker-compose not found"
    fi
    
    # Check if docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        error_exit "Docker daemon is not running"
    fi
    
    # Cleanup any existing containers from previous failed starts
    log "INFO" "Cleaning up any existing containers"
    docker-compose down --remove-orphans 2>/dev/null || true
    
    # Remove any dangling containers that might conflict
    docker container prune -f >/dev/null 2>&1 || true
    
    # Pull latest images if network allows
    log "INFO" "Pulling latest container images"
    if docker-compose pull --quiet; then
        log "INFO" "Container images updated"
    else
        log "WARN" "Failed to pull images, using local versions"
    fi
    
    # Start services with proper dependency order
    log "INFO" "Starting Docker Compose stack"
    if docker-compose up -d --remove-orphans; then
        log "INFO" "Services started successfully"
    else
        error_exit "Failed to start services"
    fi
    
    # Wait for services to become healthy
    log "INFO" "Waiting for services to become healthy"
    local max_wait=60
    local wait_count=0
    
    while [[ $wait_count -lt $max_wait ]]; do
        local unhealthy_services
        unhealthy_services=$(docker-compose ps --services --filter "health=unhealthy" 2>/dev/null || echo "")
        
        if [[ -z "$unhealthy_services" ]]; then
            log "INFO" "All services are healthy"
            break
        else
            log "INFO" "Waiting for services to become healthy: $unhealthy_services"
            sleep 5
            ((wait_count += 5))
        fi
    done
    
    # Final status check
    docker-compose ps
    
    return 0
}

# Service health verification
verify_service_health() {
    log "INFO" "Verifying service health"
    
    cd "$PROJECT_DIR"
    
    # Get service status
    local services_status
    services_status=$(docker-compose ps --format "table {{.Name}}\t{{.State}}\t{{.Status}}")
    
    log "INFO" "Service status:"
    echo "$services_status" | tee -a "$LOG_FILE"
    
    # Check for any failed services
    if docker-compose ps --services --filter "health=unhealthy" | grep -q .; then
        log "WARN" "Some services are unhealthy"
        return 1
    fi
    
    if docker-compose ps --services --filter "status=exited" | grep -q .; then
        log "WARN" "Some services have exited"
        return 1
    fi
    
    log "INFO" "All services verified as healthy"
    return 0
}

# Main boot process
main() {
    log "INFO" "Starting enhanced boot manager v2.0"
    log "INFO" "Project directory: $PROJECT_DIR"
    
    # Acquire lock
    acquire_lock
    
    # Stage 1: Network verification
    log "INFO" "Stage 1: Network verification"
    verify_network_connectivity
    
    # Stage 2: VPN establishment
    log "INFO" "Stage 2: VPN establishment"
    establish_vpn_connection
    
    # Stage 3: Service startup
    log "INFO" "Stage 3: Service startup"
    start_services
    
    # Stage 4: Health verification
    log "INFO" "Stage 4: Health verification"
    if verify_service_health; then
        log "INFO" "Boot process completed successfully"
    else
        log "WARN" "Boot process completed with some issues"
    fi
    
    log "INFO" "Boot manager finished"
}

# Command line interface
case "${1:-}" in
    "start"|"boot"|"")
        main
        ;;
    "network")
        verify_network_connectivity
        ;;
    "vpn")
        establish_vpn_connection
        ;;
    "services")
        start_services
        ;;
    "health")
        verify_service_health
        ;;
    "help"|"--help")
        echo "Usage: $0 [start|network|vpn|services|health|help]"
        echo "  start    - Run complete boot process (default)"
        echo "  network  - Verify network connectivity only"
        echo "  vpn      - Establish VPN connection only"
        echo "  services - Start services only"
        echo "  health   - Check service health only"
        echo "  help     - Show this help message"
        ;;
    *)
        echo "Unknown command: $1" >&2
        echo "Use '$0 help' for usage information" >&2
        exit 1
        ;;
esac