#\!/bin/bash

# Enhanced Media Server Deployment Script
# =======================================
# Automates deployment of the enhanced mediaserver configuration
# Handles backup, testing, and rollback procedures

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly BACKUP_DIR="$PROJECT_DIR/backups/deployment-$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="$PROJECT_DIR/logs/deployment.log"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Color coding
    local color="$NC"
    case $level in
        "ERROR") color="$RED" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARNING") color="$YELLOW" ;;
        "INFO") color="$BLUE" ;;
    esac
    
    echo -e "${color}[$timestamp] [$level] $message${NC}" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    log "ERROR" "$1"
    log "ERROR" "Deployment failed\! Check logs: $LOG_FILE"
    exit 1
}

# Create backup of current configuration
create_backup() {
    log "INFO" "Creating backup of current configuration..."
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup key files
    local files_to_backup=(
        "docker-compose.yml"
        "systemd/mediaserver.service"
        ".env"
    )
    
    for file in "${files_to_backup[@]}"; do
        if [ -f "$PROJECT_DIR/$file" ]; then
            cp "$PROJECT_DIR/$file" "$BACKUP_DIR/"
            log "INFO" "Backed up: $file"
        fi
    done
    
    # Backup entire scripts directory
    if [ -d "$PROJECT_DIR/scripts" ]; then
        cp -r "$PROJECT_DIR/scripts" "$BACKUP_DIR/scripts-original"
        log "INFO" "Backed up scripts directory"
    fi
    
    log "SUCCESS" "Backup created: $BACKUP_DIR"
}

# Stop current services
stop_current_services() {
    log "INFO" "Stopping current services..."
    
    # Stop systemd service if running
    if systemctl is-active --quiet mediaserver.service 2>/dev/null; then
        log "INFO" "Stopping mediaserver systemd service..."
        sudo systemctl stop mediaserver.service
    fi
    
    # Stop docker-compose services
    if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
        cd "$PROJECT_DIR"
        docker-compose down --timeout 30 || log "WARNING" "Some containers may not have stopped cleanly"
    fi
    
    # Clean up containers
    docker container prune -f 2>/dev/null || true
    
    log "SUCCESS" "Current services stopped"
}

# Deploy enhanced configuration
deploy_enhanced_config() {
    log "INFO" "Deploying enhanced configuration..."
    
    cd "$PROJECT_DIR"
    
    # Deploy docker-compose configuration
    if [ -f "docker-compose-enhanced.yml" ]; then
        log "INFO" "Deploying enhanced docker-compose configuration..."
        cp "docker-compose-enhanced.yml" "docker-compose.yml"
        log "SUCCESS" "Docker compose configuration deployed"
    else
        error_exit "Enhanced docker-compose.yml not found"
    fi
    
    # Deploy systemd service
    if [ -f "systemd/mediaserver-enhanced.service" ]; then
        log "INFO" "Deploying enhanced systemd service..."
        sudo cp "systemd/mediaserver-enhanced.service" "/etc/systemd/system/"
        sudo systemctl daemon-reload
        
        # Disable old service and enable new one
        sudo systemctl disable mediaserver.service 2>/dev/null || true
        sudo systemctl enable mediaserver-enhanced.service
        log "SUCCESS" "Systemd service deployed and enabled"
    else
        error_exit "Enhanced systemd service not found"
    fi
    
    log "SUCCESS" "Enhanced configuration deployed"
}

# Test enhanced configuration
test_enhanced_config() {
    log "INFO" "Testing enhanced configuration..."
    
    cd "$PROJECT_DIR"
    
    # Validate docker-compose file
    log "INFO" "Validating docker-compose configuration..."
    if \! docker-compose config >/dev/null 2>&1; then
        error_exit "Docker-compose configuration validation failed"
    fi
    log "SUCCESS" "Docker-compose configuration is valid"
    
    # Test script permissions
    local scripts=(
        "scripts/staged-boot.sh"
        "scripts/wireguard-entrypoint.sh"
        "scripts/wireguard-health-check.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [ \! -x "$PROJECT_DIR/$script" ]; then
            log "WARNING" "Making $script executable"
            chmod +x "$PROJECT_DIR/$script"
        fi
    done
    
    log "SUCCESS" "Enhanced configuration tests passed"
}

# Start enhanced services
start_enhanced_services() {
    log "INFO" "Starting enhanced services..."
    
    # Start systemd service
    log "INFO" "Starting mediaserver-enhanced systemd service..."
    sudo systemctl start mediaserver-enhanced.service
    
    # Wait a bit for startup
    sleep 15
    
    # Check service status
    if systemctl is-active --quiet mediaserver-enhanced.service; then
        log "SUCCESS" "Enhanced mediaserver service is running"
    else
        error_exit "Enhanced mediaserver service failed to start"
    fi
    
    log "SUCCESS" "Enhanced services started successfully"
}

# Monitor deployment
monitor_deployment() {
    log "INFO" "Monitoring deployment for 120 seconds..."
    
    local start_time=$(date +%s)
    local timeout_time=$((start_time + 120))
    local all_healthy=false
    
    while [ $(date +%s) -lt $timeout_time ]; do
        # Check container status
        local container_status=$(docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || echo "No containers")
        log "INFO" "Container status:"
        echo "$container_status" | tee -a "$LOG_FILE"
        
        # Check for unhealthy containers
        local unhealthy_count=$(echo "$container_status" | grep -c 'unhealthy' || echo 0)
        local starting_count=$(echo "$container_status" | grep -c 'health: starting' || echo 0)
        
        if [ "$unhealthy_count" -eq 0 ] && [ "$starting_count" -eq 0 ]; then
            # Check if we have the expected containers running
            local running_containers=$(docker ps --format '{{.Names}}' | sort | tr '\n' ' ')
            if [[ $running_containers == *"wireguard"* ]] && [[ $running_containers == *"jellyfin"* ]]; then
                log "SUCCESS" "All services appear healthy"
                all_healthy=true
                break
            fi
        fi
        
        log "INFO" "Waiting for services to stabilize... ($starting_count starting, $unhealthy_count unhealthy)"
        sleep 15
    done
    
    if \! $all_healthy; then
        log "WARNING" "Some services may not be fully healthy yet"
        log "INFO" "Check service status with: sudo systemctl status mediaserver-enhanced.service"
        log "INFO" "Check logs with: sudo journalctl -u mediaserver-enhanced.service -f"
    fi
}

# Rollback function
rollback_deployment() {
    log "WARNING" "Rolling back deployment..."
    
    # Stop enhanced service
    sudo systemctl stop mediaserver-enhanced.service 2>/dev/null || true
    sudo systemctl disable mediaserver-enhanced.service 2>/dev/null || true
    
    # Restore backup files
    if [ -d "$BACKUP_DIR" ]; then
        cp "$BACKUP_DIR/docker-compose.yml" "$PROJECT_DIR/" 2>/dev/null || true
        cp "$BACKUP_DIR/mediaserver.service" "$PROJECT_DIR/systemd/" 2>/dev/null || true
        sudo cp "$PROJECT_DIR/systemd/mediaserver.service" "/etc/systemd/system/" 2>/dev/null || true
        
        sudo systemctl daemon-reload
        sudo systemctl enable mediaserver.service 2>/dev/null || true
        sudo systemctl start mediaserver.service 2>/dev/null || true
        
        log "SUCCESS" "Rollback completed"
    else
        log "ERROR" "Backup directory not found - manual recovery required"
    fi
}

# Main deployment function
deploy() {
    log "INFO" "Starting enhanced media server deployment"
    
    # Pre-deployment checks
    if [ \! -f "$PROJECT_DIR/docker-compose-enhanced.yml" ]; then
        error_exit "Enhanced docker-compose.yml not found"
    fi
    
    if [ \! -f "$PROJECT_DIR/systemd/mediaserver-enhanced.service" ]; then 
        error_exit "Enhanced systemd service not found"
    fi
    
    # Create logs directory
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Execute deployment steps
    create_backup
    stop_current_services
    deploy_enhanced_config
    test_enhanced_config
    start_enhanced_services
    monitor_deployment
    
    log "SUCCESS" "Enhanced media server deployment completed successfully\!"
    log "INFO" ""
    log "INFO" "Next steps:"
    log "INFO" "1. Monitor logs: sudo journalctl -u mediaserver-enhanced.service -f"
    log "INFO" "2. Check status: sudo systemctl status mediaserver-enhanced.service"
    log "INFO" "3. View containers: docker ps"
    log "INFO" "4. Access services:"
    log "INFO" "   - Jellyfin: http://localhost:8096"
    log "INFO" "   - Transmission: http://localhost:9091"
    log "INFO" "   - Jackett: http://localhost:9117"
    log "INFO" ""
    log "INFO" "Backup location: $BACKUP_DIR"
}

# Main function
main() {
    local command="${1:-deploy}"
    
    case $command in
        "deploy"|"install")
            deploy
            ;;
        "rollback")
            rollback_deployment
            ;;
        "test")
            test_enhanced_config
            ;;
        *)
            echo "Usage: $0 {deploy|rollback|test}"
            echo "  deploy  - Deploy enhanced configuration"
            echo "  rollback - Rollback to previous configuration"  
            echo "  test    - Test configuration without deploying"
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
