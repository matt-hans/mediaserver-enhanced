#!/bin/bash
# Media Server Configuration Backup Script
# =========================================
# Creates backups of all important configuration files and settings

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEDIASERVER_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_BASE_DIR="/var/backups/mediaserver"
LOG_FILE="/var/log/mediaserver-backup.log"
RETENTION_DAYS=30

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Create backup directory structure
create_backup_dirs() {
    local backup_date
    backup_date=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_dir="$BACKUP_BASE_DIR/$backup_date"
    
    log "Creating backup directory: $backup_dir"
    
    mkdir -p "$backup_dir"/{config,scripts,systemd,docker,logs}
    echo "$backup_dir"
}

# Backup configuration files
backup_configs() {
    local backup_dir="$1"
    
    log "Backing up configuration files..."
    
    # Docker Compose and environment
    if [ -f "$MEDIASERVER_DIR/docker-compose.yml" ]; then
        cp "$MEDIASERVER_DIR/docker-compose.yml" "$backup_dir/docker/"
        log "Backed up: docker-compose.yml"
    fi
    
    if [ -f "$MEDIASERVER_DIR/.env" ]; then
        # Create sanitized copy (remove sensitive data)
        cp "$MEDIASERVER_DIR/.env" "$backup_dir/docker/.env.full"
        
        # Create sanitized version with passwords masked
        sed 's/\(PASS\|KEY\|SECRET\|TOKEN\)=.*/\1=REDACTED/g' \
            "$MEDIASERVER_DIR/.env" > "$backup_dir/docker/.env.sanitized"
        
        log "Backed up: .env (full and sanitized versions)"
    fi
    
    # Service configurations
    for service in wireguard transmission jackett jellyfin; do
        local service_config_dir="$MEDIASERVER_DIR/config/$service"
        if [ -d "$service_config_dir" ]; then
            cp -r "$service_config_dir" "$backup_dir/config/"
            log "Backed up: $service configuration"
        fi
    done
    
    # Scripts
    if [ -d "$MEDIASERVER_DIR/scripts" ]; then
        cp -r "$MEDIASERVER_DIR/scripts" "$backup_dir/"
        log "Backed up: scripts directory"
    fi
    
    # Systemd service
    if [ -f "/etc/systemd/system/mediaserver.service" ]; then
        cp "/etc/systemd/system/mediaserver.service" "$backup_dir/systemd/"
        log "Backed up: systemd service file"
    fi
    
    # Cron jobs
    if [ -f "/etc/cron.d/mediaserver" ]; then
        cp "/etc/cron.d/mediaserver" "$backup_dir/systemd/"
        log "Backed up: cron configuration"
    fi
}

# Backup Docker information
backup_docker_info() {
    local backup_dir="$1"
    
    log "Backing up Docker information..."
    
    # Container information
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" > "$backup_dir/docker/containers.txt" 2>/dev/null || true
    
    # Image information
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" > "$backup_dir/docker/images.txt" 2>/dev/null || true
    
    # Network information
    docker network ls > "$backup_dir/docker/networks.txt" 2>/dev/null || true
    
    # Volume information
    docker volume ls > "$backup_dir/docker/volumes.txt" 2>/dev/null || true
    
    # Docker Compose status
    if [ -f "$MEDIASERVER_DIR/docker-compose.yml" ]; then
        cd "$MEDIASERVER_DIR"
        docker-compose ps > "$backup_dir/docker/compose-status.txt" 2>/dev/null || true
        cd - >/dev/null
    fi
    
    log "Docker information backed up"
}

# Backup system information
backup_system_info() {
    local backup_dir="$1"
    
    log "Backing up system information..."
    
    # System information
    {
        echo "=== SYSTEM INFORMATION ==="
        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -a)"
        echo "Uptime: $(uptime)"
        echo ""
        
        echo "=== DISK USAGE ==="
        df -h
        echo ""
        
        echo "=== MEMORY USAGE ==="
        free -h
        echo ""
        
        echo "=== NETWORK INTERFACES ==="
        ip addr show
        echo ""
        
        echo "=== RUNNING PROCESSES ==="
        ps aux | grep -E "(docker|wireguard|transmission|jackett|jellyfin)" | grep -v grep
        echo ""
        
        echo "=== INSTALLED PACKAGES ==="
        dpkg -l | grep -E "(docker|wireguard)"
        echo ""
        
    } > "$backup_dir/system-info.txt"
    
    # Service status
    {
        echo "=== SYSTEMD SERVICES ==="
        systemctl status mediaserver 2>/dev/null || echo "mediaserver service not found"
        echo ""
        systemctl status docker 2>/dev/null || echo "docker service not found"
        echo ""
        
    } > "$backup_dir/service-status.txt"
    
    log "System information backed up"
}

# Backup logs
backup_logs() {
    local backup_dir="$1"
    
    log "Backing up recent logs..."
    
    # System logs (last 1000 lines)
    journalctl -u mediaserver --no-pager -n 1000 > "$backup_dir/logs/mediaserver.log" 2>/dev/null || true
    journalctl -u docker --no-pager -n 500 > "$backup_dir/logs/docker.log" 2>/dev/null || true
    
    # Application logs
    local log_sources=(
        "/var/log/mediaserver-health.log"
        "/var/log/mediaserver-backup.log"
        "$MEDIASERVER_DIR/config/transmission/transmission.log"
        "$MEDIASERVER_DIR/config/jackett/log.txt"
        "$MEDIASERVER_DIR/config/jellyfin/logs/jellyfin.log"
    )
    
    for log_file in "${log_sources[@]}"; do
        if [ -f "$log_file" ]; then
            local basename
            basename=$(basename "$log_file")
            cp "$log_file" "$backup_dir/logs/$basename" 2>/dev/null || true
        fi
    done
    
    log "Logs backed up"
}

# Create backup metadata
create_metadata() {
    local backup_dir="$1"
    
    log "Creating backup metadata..."
    
    cat > "$backup_dir/backup-info.txt" << EOF
Media Server Backup Information
===============================

Backup Date: $(date)
Backup Directory: $backup_dir
Created by: $(whoami)
System: $(hostname)

Backup Contents:
- Docker Compose configuration
- Environment settings (sanitized)
- Service configurations (WireGuard, Transmission, Jackett, Jellyfin)
- Scripts and utilities
- Systemd service files
- Docker container/image information
- System information and logs
- Recent application logs

Restoration Instructions:
1. Copy configuration files to $MEDIASERVER_DIR
2. Update .env file with correct credentials
3. Restart services: systemctl restart mediaserver
4. Verify health: $MEDIASERVER_DIR/scripts/health-check.sh

Notes:
- Sensitive information (passwords, keys) has been sanitized
- Full .env backup is available but contains sensitive data
- Media files and downloads are not included in this backup
EOF
    
    # Create file checksums
    log "Creating checksums..."
    cd "$backup_dir"
    find . -type f -exec sha256sum {} \; > checksums.txt
    cd - >/dev/null
    
    log "Backup metadata created"
}

# Compress backup
compress_backup() {
    local backup_dir="$1"
    local compressed_file="${backup_dir}.tar.gz"
    
    log "Compressing backup..."
    
    cd "$(dirname "$backup_dir")"
    tar -czf "$compressed_file" "$(basename "$backup_dir")" || error_exit "Failed to compress backup"
    
    # Remove uncompressed directory
    rm -rf "$backup_dir"
    
    local size
    size=$(du -h "$compressed_file" | cut -f1)
    log "Backup compressed: $compressed_file ($size)"
    
    echo "$compressed_file"
}

# Clean old backups
cleanup_old_backups() {
    log "Cleaning up old backups (older than $RETENTION_DAYS days)..."
    
    if [ -d "$BACKUP_BASE_DIR" ]; then
        find "$BACKUP_BASE_DIR" -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
        find "$BACKUP_BASE_DIR" -type d -empty -delete 2>/dev/null || true
        
        local remaining_count
        remaining_count=$(find "$BACKUP_BASE_DIR" -name "*.tar.gz" -type f | wc -l)
        log "Cleanup complete. $remaining_count backups remaining."
    fi
}

# Verify backup integrity
verify_backup() {
    local backup_file="$1"
    
    log "Verifying backup integrity..."
    
    if tar -tzf "$backup_file" >/dev/null 2>&1; then
        log "Backup verification successful"
        return 0
    else
        error_exit "Backup verification failed - archive is corrupted"
    fi
}

# Send notification (optional)
send_notification() {
    local backup_file="$1"
    local status="$2"
    
    local size
    size=$(du -h "$backup_file" | cut -f1 2>/dev/null || echo "unknown")
    
    local message="Media Server Backup $status
File: $(basename "$backup_file")
Size: $size
Date: $(date)
Location: $backup_file"
    
    # Email notification (if configured)
    if command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "Media Server Backup $status" root 2>/dev/null || true
    fi
    
    # Webhook notification (if configured)
    if [ -n "${BACKUP_WEBHOOK_URL:-}" ]; then
        curl -X POST -H 'Content-Type: application/json' \
             -d "{\"text\":\"$message\"}" \
             "$BACKUP_WEBHOOK_URL" 2>/dev/null || true
    fi
}

# Main backup function
main() {
    log "=== Starting Media Server Backup ==="
    
    # Check if mediaserver directory exists
    if [ ! -d "$MEDIASERVER_DIR" ]; then
        error_exit "Media server directory not found: $MEDIASERVER_DIR"
    fi
    
    # Create base backup directory
    mkdir -p "$BACKUP_BASE_DIR"
    
    # Create timestamped backup directory
    local backup_dir
    backup_dir=$(create_backup_dirs)
    
    # Perform backup operations
    backup_configs "$backup_dir"
    backup_docker_info "$backup_dir"
    backup_system_info "$backup_dir"
    backup_logs "$backup_dir"
    create_metadata "$backup_dir"
    
    # Compress and verify
    local compressed_backup
    compressed_backup=$(compress_backup "$backup_dir")
    verify_backup "$compressed_backup"
    
    # Cleanup and notification
    cleanup_old_backups
    send_notification "$compressed_backup" "Completed"
    
    log "=== Backup Completed Successfully ==="
    log "Backup file: $compressed_backup"
    
    echo "Backup completed: $compressed_backup"
}

# Error trap
trap 'log "ERROR: Backup failed at line $LINENO"; send_notification "backup-failed" "Failed"' ERR

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Run main function
main "$@"