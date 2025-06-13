#!/bin/bash
# Media Server Initial Setup Script
# ==================================
# Automated installation and configuration for Raspberry Pi

set -euo pipefail

# Configuration
MEDIASERVER_USER="mediaserver"
INSTALL_DIR="/opt/mediaserver"
MEDIA_DIR="/mnt/media"
DOWNLOAD_DIR="/mnt/downloads"
LOG_FILE="/var/log/mediaserver-setup.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Colored output functions
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "INFO: $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log "SUCCESS: $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "WARNING: $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "ERROR: $1"
}

# Error handling
error_exit() {
    error "$1"
    exit 1
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root. Use: sudo $0"
    fi
}

# Detect system information
detect_system() {
    info "Detecting system information..."
    
    # Check if it's a Raspberry Pi
    if [ -f /proc/device-tree/model ]; then
        local model
        model=$(cat /proc/device-tree/model 2>/dev/null || echo "Unknown")
        info "Detected: $model"
        
        if [[ "$model" == *"Raspberry Pi"* ]]; then
            info "Raspberry Pi detected - will enable hardware acceleration"
            export RPI_DETECTED=true
        else
            warning "Not a Raspberry Pi - hardware acceleration may not work"
            export RPI_DETECTED=false
        fi
    fi
    
    # Check architecture
    local arch
    arch=$(uname -m)
    info "Architecture: $arch"
    
    if [[ "$arch" != "armv7l" && "$arch" != "aarch64" ]]; then
        warning "This script is optimized for ARM architecture (Raspberry Pi)"
    fi
}

# Update system packages
update_system() {
    info "Updating system packages..."
    
    apt-get update || error_exit "Failed to update package lists"
    apt-get upgrade -y || error_exit "Failed to upgrade packages"
    
    success "System packages updated"
}

# Install prerequisites
install_prerequisites() {
    info "Installing prerequisites..."
    
    local packages=(
        "docker.io"
        "docker-compose"
        "curl"
        "wget"
        "htop"
        "iotop"
        "ncdu"
        "git"
        "vim"
        "bc"
        "jq"
        "mailutils"
        "wireguard-tools"
    )
    
    apt-get install -y "${packages[@]}" || error_exit "Failed to install prerequisites"
    
    # Enable and start Docker
    systemctl enable docker || error_exit "Failed to enable Docker"
    systemctl start docker || error_exit "Failed to start Docker"
    
    success "Prerequisites installed"
}

# Create system user
create_user() {
    info "Creating system user: $MEDIASERVER_USER"
    
    if id "$MEDIASERVER_USER" &>/dev/null; then
        warning "User $MEDIASERVER_USER already exists"
    else
        useradd -r -s /bin/bash -d "$INSTALL_DIR" -m "$MEDIASERVER_USER" || error_exit "Failed to create user"
        success "User $MEDIASERVER_USER created"
    fi
    
    # Add user to docker group
    usermod -aG docker "$MEDIASERVER_USER" || error_exit "Failed to add user to docker group"
    
    # Add user to video group for hardware acceleration (Raspberry Pi)
    if [ "$RPI_DETECTED" = true ]; then
        usermod -aG video "$MEDIASERVER_USER" 2>/dev/null || warning "Could not add user to video group"
    fi
    
    success "User configuration completed"
}

# Create directory structure
create_directories() {
    info "Creating directory structure..."
    
    # Main directories
    mkdir -p "$INSTALL_DIR"/{config/{wireguard,transmission,jackett,jellyfin},scripts,systemd}
    mkdir -p "$MEDIA_DIR"/{movies,tv,music,books,misc}
    mkdir -p "$DOWNLOAD_DIR"/{complete,incomplete,watch}
    
    # Log directory
    mkdir -p /var/log/mediaserver
    
    # Set ownership
    chown -R "$MEDIASERVER_USER:$MEDIASERVER_USER" "$INSTALL_DIR"
    chown -R "$MEDIASERVER_USER:$MEDIASERVER_USER" "$MEDIA_DIR"
    chown -R "$MEDIASERVER_USER:$MEDIASERVER_USER" "$DOWNLOAD_DIR"
    chown -R "$MEDIASERVER_USER:$MEDIASERVER_USER" /var/log/mediaserver
    
    # Set permissions
    chmod -R 755 "$INSTALL_DIR"
    chmod -R 755 "$MEDIA_DIR"
    chmod -R 755 "$DOWNLOAD_DIR"
    
    success "Directory structure created"
}

# Copy configuration files
copy_configs() {
    info "Copying configuration files..."
    
    local source_dir
    source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    
    # Copy main files
    cp "$source_dir/docker-compose.yml" "$INSTALL_DIR/"
    cp "$source_dir/.env" "$INSTALL_DIR/"
    
    # Copy scripts
    cp "$source_dir/scripts"/* "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts"/*.sh
    
    # Copy systemd service
    cp "$source_dir/systemd/mediaserver.service" /etc/systemd/system/
    
    # Copy WireGuard template
    if [ -f "$source_dir/config/wireguard/wg0.conf" ]; then
        cp "$source_dir/config/wireguard/wg0.conf" "$INSTALL_DIR/config/wireguard/"
    else
        warning "WireGuard configuration template not found"
    fi
    
    # Set ownership
    chown -R "$MEDIASERVER_USER:$MEDIASERVER_USER" "$INSTALL_DIR"
    
    success "Configuration files copied"
}

# Generate WireGuard keys
generate_wireguard_keys() {
    info "Generating WireGuard keys..."
    
    local wg_dir="$INSTALL_DIR/config/wireguard"
    
    if [ ! -f "$wg_dir/privatekey" ]; then
        cd "$wg_dir"
        
        # Generate keys
        wg genkey | tee privatekey | wg pubkey > publickey
        chmod 600 privatekey
        
        # Set ownership
        chown "$MEDIASERVER_USER:$MEDIASERVER_USER" privatekey publickey
        
        success "WireGuard keys generated"
        
        echo ""
        info "=== WIREGUARD CONFIGURATION ==="
        info "Public key: $(cat publickey)"
        info "Add this public key to your VPN provider configuration"
        info "Then update $wg_dir/wg0.conf with your VPN settings"
        echo ""
    else
        info "WireGuard keys already exist"
    fi
}

# Configure systemd service
configure_systemd() {
    info "Configuring systemd service..."
    
    # Reload systemd
    systemctl daemon-reload || error_exit "Failed to reload systemd"
    
    # Enable service
    systemctl enable mediaserver.service || error_exit "Failed to enable mediaserver service"
    
    success "Systemd service configured"
}

# Setup cron jobs
setup_cron() {
    info "Setting up cron jobs..."
    
    cat > /etc/cron.d/mediaserver << EOF
# Media Server Health Checks and Maintenance
# Health check every 5 minutes
*/5 * * * * $MEDIASERVER_USER $INSTALL_DIR/scripts/health-check.sh >/dev/null 2>&1

# Backup configurations daily at 3 AM
0 3 * * * $MEDIASERVER_USER $INSTALL_DIR/scripts/backup.sh >/dev/null 2>&1

# VPN monitoring every minute
* * * * * $MEDIASERVER_USER $INSTALL_DIR/scripts/vpn-monitor.sh >/dev/null 2>&1
EOF
    
    success "Cron jobs configured"
}

# Optimize system settings
optimize_system() {
    info "Optimizing system settings..."
    
    # Kernel parameters for better performance
    cat >> /etc/sysctl.conf << EOF

# Media Server Optimizations
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# Docker optimizations
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
    
    # Apply settings
    sysctl -p || warning "Some sysctl settings may not have been applied"
    
    # Raspberry Pi specific optimizations
    if [ "$RPI_DETECTED" = true ]; then
        info "Applying Raspberry Pi specific optimizations..."
        
        # GPU memory split (if config.txt exists)
        if [ -f /boot/config.txt ]; then
            if ! grep -q "gpu_mem" /boot/config.txt; then
                echo "gpu_mem=128" >> /boot/config.txt
                info "GPU memory split configured (requires reboot)"
            fi
        fi
        
        # Enable hardware acceleration modules
        if [ -f /etc/modules ]; then
            echo "bcm2835-v4l2" >> /etc/modules 2>/dev/null || true
        fi
    fi
    
    success "System optimizations applied"
}

# Create Transmission settings override
create_transmission_config() {
    info "Creating Transmission configuration..."
    
    local transmission_dir="$INSTALL_DIR/config/transmission"
    mkdir -p "$transmission_dir"
    
    cat > "$transmission_dir/settings.json" << 'EOF'
{
    "download-dir": "/downloads/complete",
    "incomplete-dir": "/downloads/incomplete",
    "incomplete-dir-enabled": true,
    "watch-dir": "/downloads/watch",
    "watch-dir-enabled": true,
    "script-torrent-done-enabled": true,
    "script-torrent-done-filename": "/scripts/post-download.sh",
    "encryption": 2,
    "peer-port": 51413,
    "peer-port-random-on-start": false,
    "port-forwarding-enabled": false,
    "preallocation": 2,
    "ratio-limit": 2,
    "ratio-limit-enabled": true,
    "speed-limit-up": 1000,
    "speed-limit-up-enabled": true,
    "queue-stalled-enabled": true,
    "queue-stalled-minutes": 30,
    "rpc-whitelist-enabled": true,
    "rpc-whitelist": "127.0.0.1,192.168.*.*,10.*.*.*,172.16.*.*"
}
EOF
    
    chown "$MEDIASERVER_USER:$MEDIASERVER_USER" "$transmission_dir/settings.json"
    
    success "Transmission configuration created"
}

# Final setup and instructions
final_setup() {
    info "Completing final setup..."
    
    # Create README with instructions
    cat > "$INSTALL_DIR/README.md" << 'EOF'
# Media Server Setup Complete

## Next Steps

1. **Configure VPN Settings**
   - Edit `config/wireguard/wg0.conf` with your VPN provider settings
   - Your public key is in `config/wireguard/publickey`

2. **Update Environment Variables**
   - Edit `.env` file with your preferences
   - Set strong passwords for Transmission
   - Configure notification URLs if desired

3. **Start the Services**
   ```bash
   sudo systemctl start mediaserver
   sudo systemctl status mediaserver
   ```

4. **Access the Services**
   - Jellyfin: http://your-pi-ip:8096
   - Transmission: http://your-pi-ip:9091
   - Jackett: http://your-pi-ip:9117

5. **Monitor the System**
   ```bash
   # Check service status
   sudo systemctl status mediaserver
   
   # View logs
   sudo journalctl -u mediaserver -f
   
   # Run health check manually
   sudo -u mediaserver /opt/mediaserver/scripts/health-check.sh
   ```

## Important Security Notes

- All torrent traffic is routed through VPN
- Change default passwords in .env file
- Keep your system updated
- Monitor logs regularly

## Support

- Check logs: `sudo journalctl -u mediaserver -f`
- Health check: `/opt/mediaserver/scripts/health-check.sh`
- Configuration: `/opt/mediaserver/.env`
EOF
    
    chown "$MEDIASERVER_USER:$MEDIASERVER_USER" "$INSTALL_DIR/README.md"
    
    success "Setup completed successfully!"
}

# Print final instructions
print_instructions() {
    echo ""
    echo "========================================"
    echo "  MEDIA SERVER SETUP COMPLETE"
    echo "========================================"
    echo ""
    success "Installation directory: $INSTALL_DIR"
    success "Media directory: $MEDIA_DIR"
    success "Downloads directory: $DOWNLOAD_DIR"
    echo ""
    
    if [ "$RPI_DETECTED" = true ]; then
        info "Your WireGuard public key:"
        cat "$INSTALL_DIR/config/wireguard/publickey" 2>/dev/null || echo "Key not found"
        echo ""
    fi
    
    info "NEXT STEPS:"
    echo "1. Configure VPN: $INSTALL_DIR/config/wireguard/wg0.conf"
    echo "2. Update settings: $INSTALL_DIR/.env"
    echo "3. Start services: sudo systemctl start mediaserver"
    echo "4. Check status: sudo systemctl status mediaserver"
    echo ""
    
    info "WEB INTERFACES:"
    echo "- Jellyfin: http://$(hostname -I | awk '{print $1}'):8096"
    echo "- Transmission: http://$(hostname -I | awk '{print $1}'):9091"
    echo "- Jackett: http://$(hostname -I | awk '{print $1}'):9117"
    echo ""
    
    warning "IMPORTANT: Configure your VPN settings before starting the services!"
    echo ""
}

# Main installation function
main() {
    echo "========================================="
    echo "  MEDIA SERVER SETUP FOR RASPBERRY PI"
    echo "========================================="
    echo ""
    
    # Create log file
    touch "$LOG_FILE"
    
    log "Media Server setup started"
    
    # Run setup steps
    check_root
    detect_system
    update_system
    install_prerequisites
    create_user
    create_directories
    copy_configs
    generate_wireguard_keys
    create_transmission_config
    configure_systemd
    setup_cron
    optimize_system
    final_setup
    print_instructions
    
    log "Media Server setup completed successfully"
}

# Error trap
trap 'error "Setup failed at line $LINENO"' ERR

# Run main function
main "$@"