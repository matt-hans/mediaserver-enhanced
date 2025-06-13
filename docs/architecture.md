After analyzing the official documentation for WireGuard, Transmission, Jackett, and Jellyfin, I'll provide a comprehensive, modular architecture that ensures secure torrenting through VPN while maintaining service reliability and proper containerization.

## System Architecture Overview

```mermaid
graph TB
    subgraph "Host Network"
        subgraph "Docker Network Bridge"
            subgraph "VPN Network Namespace"
                WG[WireGuard Container<br/>VPN Gateway]
                TR[Transmission<br/>BitTorrent Client]
                JK[Jackett<br/>Indexer Proxy]
            end
            
            subgraph "Host Network Access"
                JF[Jellyfin<br/>Media Server]
                WU[Watchtower<br/>Auto Updates]
                AH[Autoheal<br/>Health Monitor]
            end
        end
        
        subgraph "Storage Layer"
            CONFIG[/opt/mediaserver/config]
            MEDIA[/mnt/media]
            DOWNLOADS[/mnt/downloads]
        end
    end
    
    subgraph "External Services"
        TRACKERS[Torrent Trackers]
        VPN_PROVIDER[VPN Provider]
        USERS[End Users]
    end
    
    WG -.->|Encrypted Tunnel| VPN_PROVIDER
    JK -->|Search Queries| WG
    TR -->|Torrent Traffic| WG
    JK -.->|API Calls| TRACKERS
    TR -.->|Peer Connections| TRACKERS
    
    JF -->|Reads| MEDIA
    TR -->|Writes| DOWNLOADS
    TR -->|Moves Complete| MEDIA
    
    USERS -->|HTTPS:8096| JF
    USERS -->|HTTPS:9091| TR
    USERS -->|HTTPS:9117| JK
    
    CONFIG -.->|Persistent Config| WG
    CONFIG -.->|Persistent Config| TR
    CONFIG -.->|Persistent Config| JK
    CONFIG -.->|Persistent Config| JF
```

## Technical Implementation

### 1. Directory Structure

```bash
/opt/mediaserver/
├── docker-compose.yml
├── .env
├── config/
│   ├── wireguard/
│   │   └── wg0.conf
│   ├── transmission/
│   ├── jackett/
│   └── jellyfin/
├── scripts/
│   ├── health-check.sh
│   ├── backup.sh
│   ├── post-download.sh
│   └── vpn-monitor.sh
└── systemd/
    └── mediaserver.service

/mnt/
├── media/
│   ├── movies/
│   ├── tv/
│   ├── music/
│   └── books/
└── downloads/
    ├── complete/
    ├── incomplete/
    └── watch/
```

### 2. Docker Compose Configuration

```yaml
# /opt/mediaserver/docker-compose.yml
version: '3.8'

networks:
  default:
    driver: bridge

services:
  # VPN Gateway Container
  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: wireguard
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - SERVERURL=${VPN_SERVER_URL}
      - SERVERPORT=${VPN_SERVER_PORT}
      - PEERS=1
      - PEERDNS=1.1.1.1
      - INTERNAL_SUBNET=10.13.13.0
      - ALLOWEDIPS=0.0.0.0/0
      - LOG_CONFS=true
    volumes:
      - ./config/wireguard:/config
      - /lib/modules:/lib/modules:ro
    ports:
      # Jellyfin
      - "${JELLYFIN_PORT}:8096"
      - "8920:8920"  # Jellyfin HTTPS (optional)
      # Transmission
      - "${TRANSMISSION_PORT}:9091"
      - "${TRANSMISSION_PEER_PORT}:51413"
      - "${TRANSMISSION_PEER_PORT}:51413/udp"
      # Jackett
      - "${JACKETT_PORT}:9117"
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=${DISABLE_IPV6}
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "ping", "-c", "1", "${VPN_HEALTH_CHECK_IP}"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  # Torrent Client
  transmission:
    image: lscr.io/linuxserver/transmission:latest
    container_name: transmission
    network_mode: service:wireguard
    depends_on:
      wireguard:
        condition: service_healthy
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - TRANSMISSION_WEB_HOME=/config/transmission-web-control/
      - USER=${TRANSMISSION_USER}
      - PASS=${TRANSMISSION_PASS}
      - WHITELIST=${TRANSMISSION_WHITELIST}
      - PEERPORT=${TRANSMISSION_PEER_PORT}
      - HOST_WHITELIST=${TRANSMISSION_HOST_WHITELIST}
    volumes:
      - ./config/transmission:/config
      - ${DOWNLOAD_PATH}:/downloads
      - ${MEDIA_PATH}:/media
      - ./scripts/post-download.sh:/scripts/post-download.sh:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9091/transmission/web/"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Indexer Proxy
  jackett:
    image: lscr.io/linuxserver/jackett:latest
    container_name: jackett
    network_mode: service:wireguard
    depends_on:
      wireguard:
        condition: service_healthy
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - AUTO_UPDATE=true
      - RUN_OPTS=--ProxyConnection=http://localhost:8118
    volumes:
      - ./config/jackett:/config
      - ${DOWNLOAD_PATH}/watch:/downloads
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9117/UI/Login", "--max-time", "10"]
      interval: 30s
      timeout: 15s
      retries: 3

  # Media Server
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    user: ${PUID}:${PGID}
    group_add:
      - "109"  # render group for hardware acceleration
    environment:
      - TZ=${TZ}
      - JELLYFIN_PublishedServerUrl=${JELLYFIN_URL}
    volumes:
      - ./config/jellyfin:/config
      - ${MEDIA_PATH}:/media:ro
      - ${DOWNLOAD_PATH}/complete:/downloads:ro
      - /opt/vc/lib:/opt/vc/lib:ro  # Raspberry Pi GPU libraries
    devices:
      # Hardware acceleration for Raspberry Pi
      - /dev/vchiq:/dev/vchiq
      - /dev/vcsm:/dev/vcsm
      - /dev/video10:/dev/video10
      - /dev/video11:/dev/video11
      - /dev/video12:/dev/video12
    ports:
      - "${JELLYFIN_PORT}:8096"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8096/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Container Health Monitor
  autoheal:
    image: willfarrell/autoheal:latest
    container_name: autoheal
    environment:
      - AUTOHEAL_CONTAINER_LABEL=all
      - AUTOHEAL_INTERVAL=300
      - AUTOHEAL_START_PERIOD=600
      - WEBHOOK_URL=${AUTOHEAL_WEBHOOK_URL}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped

  # Automatic Updates (Optional)
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_STOPPED=false
      - WATCHTOWER_SCHEDULE=0 0 3 * * *
      - WATCHTOWER_NOTIFICATIONS=${WATCHTOWER_NOTIFICATIONS}
      - WATCHTOWER_NOTIFICATION_URL=${WATCHTOWER_NOTIFICATION_URL}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped
```

### 3. Environment Configuration

```bash
# /opt/mediaserver/.env

# System Configuration
PUID=1000
PGID=1000
TZ=America/New_York

# Network Configuration
DISABLE_IPV6=1
VPN_SERVER_URL=your-vpn-server.com
VPN_SERVER_PORT=51820
VPN_HEALTH_CHECK_IP=10.0.0.1

# Service Ports (host side)
JELLYFIN_PORT=8096
TRANSMISSION_PORT=9091
TRANSMISSION_PEER_PORT=51413
JACKETT_PORT=9117

# Storage Paths
MEDIA_PATH=/mnt/media
DOWNLOAD_PATH=/mnt/downloads

# Jellyfin Configuration
JELLYFIN_URL=http://your-domain.com:8096

# Transmission Configuration
TRANSMISSION_USER=admin
TRANSMISSION_PASS=secure_password_here
TRANSMISSION_WHITELIST=192.168.*.*,10.*.*.*
TRANSMISSION_HOST_WHITELIST=your-domain.com,localhost

# Notification Configuration (Optional)
AUTOHEAL_WEBHOOK_URL=
WATCHTOWER_NOTIFICATIONS=email
WATCHTOWER_NOTIFICATION_URL=smtp://user:pass@smtp.gmail.com:587
```

### 4. WireGuard Configuration

```ini
# /opt/mediaserver/config/wireguard/wg0.conf
[Interface]
PrivateKey = your_private_key_here
Address = 10.0.0.2/32
DNS = 1.1.1.1, 1.0.0.1
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT

[Peer]
PublicKey = server_public_key_here
Endpoint = your-vpn-server.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

### 5. Transmission Settings Override

```json
// /opt/mediaserver/config/transmission/settings.json (partial)
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
    "queue-stalled-minutes": 30
}
```

### 6. Health Monitoring Script

```bash
#!/bin/bash
# /opt/mediaserver/scripts/health-check.sh

set -euo pipefail

LOG_FILE="/var/log/mediaserver-health.log"
NOTIFICATION_SENT="/tmp/mediaserver-notification-sent"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

send_notification() {
    local message=$1
    if [ ! -f "$NOTIFICATION_SENT" ]; then
        # Send notification via your preferred method
        echo "$message" | mail -s "Media Server Alert" admin@example.com || true
        touch "$NOTIFICATION_SENT"
    fi
}

clear_notification() {
    rm -f "$NOTIFICATION_SENT"
}

# Check VPN connectivity
check_vpn() {
    if ! docker exec wireguard ping -c1 -W3 10.0.0.1 &>/dev/null; then
        log "ERROR: VPN connection lost"
        send_notification "VPN connection lost on media server"
        return 1
    fi
    
    # Check if we're exposing our real IP
    REAL_IP=$(curl -s https://ipinfo.io/ip)
    VPN_IP=$(docker exec wireguard curl -s https://ipinfo.io/ip)
    
    if [ "$REAL_IP" = "$VPN_IP" ]; then
        log "ERROR: VPN is not masking IP address"
        docker-compose restart wireguard transmission jackett
        return 1
    fi
    
    return 0
}

# Check container health
check_container() {
    local container=$1
    local service=$2
    
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log "ERROR: Container $container is not running"
        docker-compose up -d "$service"
        return 1
    fi
    
    local health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
    if [ "$health" = "unhealthy" ]; then
        log "WARNING: Container $container is unhealthy"
        docker-compose restart "$service"
        return 1
    fi
    
    return 0
}

# Check disk space
check_disk_space() {
    local threshold=90
    local usage=$(df -h /mnt/downloads | awk 'NR==2 {print $5}' | sed 's/%//')
    
    if [ "$usage" -gt "$threshold" ]; then
        log "WARNING: Disk space usage is at ${usage}%"
        send_notification "Media server disk space is at ${usage}%"
        
        # Pause all torrents if critically low
        if [ "$usage" -gt 95 ]; then
            docker exec transmission transmission-remote -n admin:password --torrent all --stop
        fi
    fi
}

# Main health check
main() {
    log "Starting health check..."
    
    local all_healthy=true
    
    if ! check_vpn; then
        all_healthy=false
    fi
    
    for container in wireguard transmission jackett jellyfin; do
        if ! check_container "$container" "$container"; then
            all_healthy=false
        fi
    done
    
    check_disk_space
    
    # Check if Transmission can reach Jackett through VPN
    if ! docker exec transmission curl -sf http://localhost:9117/UI/Login &>/dev/null; then
        log "ERROR: Transmission cannot reach Jackett"
        docker-compose restart transmission jackett
        all_healthy=false
    fi
    
    if [ "$all_healthy" = true ]; then
        log "All services healthy"
        clear_notification
    fi
}

main "$@"
```

### 7. Systemd Service

```ini
# /opt/mediaserver/systemd/mediaserver.service
[Unit]
Description=Media Server Docker Stack
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/mediaserver
ExecStartPre=/usr/bin/docker-compose pull --quiet
ExecStartPre=/bin/bash -c 'until ping -c1 google.com &>/dev/null; do sleep 5; done'
ExecStart=/usr/bin/docker-compose up -d --remove-orphans
ExecStop=/usr/bin/docker-compose down
ExecReload=/usr/bin/docker-compose pull --quiet && /usr/bin/docker-compose up -d
Restart=on-failure
RestartSec=30

# Security hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### 8. Post-Download Script

```bash
#!/bin/bash
# /opt/mediaserver/scripts/post-download.sh

# This script is called by Transmission when a download completes
# Environment variables from Transmission are available

set -euo pipefail

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /config/post-download.log
}

# Move completed files to appropriate media directories
organize_media() {
    local source_dir="$TR_TORRENT_DIR"
    local torrent_name="$TR_TORRENT_NAME"
    
    # Determine media type based on file extensions and structure
    if [[ "$torrent_name" =~ (S[0-9]{2}E[0-9]{2}|[0-9]{1,2}x[0-9]{2}) ]]; then
        dest_dir="/media/tv"
    elif find "$source_dir/$torrent_name" -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" | head -1 | grep -q .; then
        dest_dir="/media/movies"
    elif find "$source_dir/$torrent_name" -name "*.mp3" -o -name "*.flac" | head -1 | grep -q .; then
        dest_dir="/media/music"
    else
        dest_dir="/media/misc"
    fi
    
    log "Moving $torrent_name to $dest_dir"
    
    # Create hardlinks instead of moving to keep seeding
    cp -al "$source_dir/$torrent_name" "$dest_dir/" || {
        log "ERROR: Failed to create hardlink, falling back to copy"
        cp -r "$source_dir/$torrent_name" "$dest_dir/"
    }
    
    # Set proper permissions
    chmod -R 755 "$dest_dir/$torrent_name"
    chown -R $PUID:$PGID "$dest_dir/$torrent_name"
}

# Notify Jellyfin to scan for new media
notify_jellyfin() {
    local jellyfin_url="http://jellyfin:8096"
    local api_key="${JELLYFIN_API_KEY:-}"
    
    if [ -n "$api_key" ]; then
        curl -X POST \
            "${jellyfin_url}/Library/Refresh" \
            -H "X-Emby-Token: ${api_key}" \
            || log "WARNING: Failed to trigger Jellyfin library scan"
    fi
}

# Main execution
main() {
    log "Processing completed torrent: $TR_TORRENT_NAME"
    log "Torrent ID: $TR_TORRENT_ID"
    log "Download directory: $TR_TORRENT_DIR"
    
    organize_media
    notify_jellyfin
    
    log "Post-processing complete for: $TR_TORRENT_NAME"
}

main "$@"
```

### 9. Initial Setup Script

```bash
#!/bin/bash
# /opt/mediaserver/setup.sh

set -euo pipefail

echo "Media Server Initial Setup"
echo "========================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

# Install prerequisites
echo "Installing prerequisites..."
apt-get update
apt-get install -y \
    docker.io \
    docker-compose \
    curl \
    wget \
    htop \
    iotop \
    ncdu

# Create user if doesn't exist
if ! id "mediaserver" &>/dev/null; then
    echo "Creating mediaserver user..."
    useradd -r -s /bin/bash -d /opt/mediaserver mediaserver
    usermod -aG docker mediaserver
fi

# Create directory structure
echo "Creating directory structure..."
mkdir -p /opt/mediaserver/{config/{wireguard,transmission,jackett,jellyfin},scripts,systemd}
mkdir -p /mnt/{media/{movies,tv,music,books,misc},downloads/{complete,incomplete,watch}}

# Set permissions
chown -R mediaserver:mediaserver /opt/mediaserver
chown -R mediaserver:mediaserver /mnt/media
chown -R mediaserver:mediaserver /mnt/downloads
chmod -R 755 /opt/mediaserver/scripts

# Copy configuration files
echo "Setting up configuration files..."
cp docker-compose.yml /opt/mediaserver/
cp .env.example /opt/mediaserver/.env
cp scripts/* /opt/mediaserver/scripts/
chmod +x /opt/mediaserver/scripts/*.sh

# Generate WireGuard keys if needed
if [ ! -f /opt/mediaserver/config/wireguard/privatekey ]; then
    echo "Generating WireGuard keys..."
    cd /opt/mediaserver/config/wireguard
    wg genkey | tee privatekey | wg pubkey > publickey
    chmod 600 privatekey
    echo "Public key: $(cat publickey)"
    echo "Add this public key to your VPN provider"
fi

# Install systemd service
echo "Installing systemd service..."
cp systemd/mediaserver.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable mediaserver.service

# Setup cron jobs
echo "Setting up cron jobs..."
cat > /etc/cron.d/mediaserver << EOF
# Media Server Health Checks
*/5 * * * * mediaserver /opt/mediaserver/scripts/health-check.sh
0 3 * * * mediaserver /opt/mediaserver/scripts/backup.sh
EOF

# Configure sysctl for better performance
echo "Optimizing system settings..."
cat >> /etc/sysctl.conf << EOF

# Media Server Optimizations
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
EOF
sysctl -p

echo ""
echo "Setup complete!"
echo "=============="
echo "1. Edit /opt/mediaserver/.env with your configuration"
echo "2. Add your WireGuard configuration to /opt/mediaserver/config/wireguard/wg0.conf"
echo "3. Start the services with: systemctl start mediaserver"
echo "4. Check logs with: journalctl -u mediaserver -f"
```

## Key Architecture Features

### 1. **Network Isolation**
- All torrent traffic routes through WireGuard VPN
- Transmission and Jackett use WireGuard's network namespace
- Kill switch prevents leaks if VPN disconnects

### 2. **Modularity**
- Each service runs in its own container
- Services can be updated independently
- Easy to add/remove components

### 3. **Resilience**
- Health checks on all services
- Automatic container restart on failure
- VPN connection monitoring
- Disk space monitoring

### 4. **Security**
- All torrenting traffic encrypted through VPN
- Jellyfin separated from torrent network
- Proper file permissions and user isolation
- No privilege escalation

### 5. **Performance**
- Hardware acceleration for Jellyfin (Raspberry Pi specific)
- Optimized preallocation for torrents
- Efficient file organization
- Resource limits to prevent system overload

### 6. **Maintenance**
- Automated updates via Watchtower
- Backup scripts for configurations
- Health monitoring and alerting
- Comprehensive logging

This architecture provides a robust, secure, and maintainable media server solution that ensures all torrenting occurs through the VPN while maintaining high availability and easy management.