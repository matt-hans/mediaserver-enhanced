# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Enhanced Media Server stack for Raspberry Pi, implementing a secure containerized media server with VPN-protected torrenting. The system uses Docker Compose to orchestrate multiple services including WireGuard VPN, Transmission (BitTorrent), Jackett (indexer), and Jellyfin (media server).

## Key Commands

### Service Management
```bash
# Start all services
sudo systemctl start mediaserver

# Stop all services  
sudo systemctl stop mediaserver

# Restart services
sudo systemctl restart mediaserver

# Check service status
sudo systemctl status mediaserver

# View service logs
sudo journalctl -u mediaserver -f
```

### Docker Operations
```bash
# Start containers
cd /home/matthewhans/mediaserver-enhanced && docker-compose up -d

# Stop containers
docker-compose down

# View container logs
docker-compose logs -f [service_name]

# Check container health
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.State}}'
```

### Development & Debugging
```bash
# Run health check
./scripts/health-check.sh

# Check VPN status
./scripts/vpn-monitor.sh status

# Test media organization
python3 scripts/media_organizer.py "/path/to/media/file"

# Manual backup
sudo ./scripts/backup.sh
```

### Python Development
```bash
# No virtual environment needed - scripts run directly
python3 scripts/media_organizer.py
python3 scripts/media_organizer_external.py

# Test scripts
python3 test_search.py
python3 test_magnet.py
```

## Architecture & Key Components

### Service Dependencies
1. **WireGuard** must be healthy before Transmission/Jackett start
2. **Transmission** depends on WireGuard for all network traffic
3. **Jackett** depends on WireGuard for secure API calls
4. **Jellyfin** runs independently on host network
5. **Autoheal** monitors and restarts unhealthy containers

### Critical Security Flow
```
Internet → WireGuard VPN → Transmission/Jackett
         ↓ (kill switch on VPN failure)
         → Emergency shutdown
```

### Media Processing Pipeline
```
Jackett (search) → Transmission (download) → post-download.sh → media_organizer.py → Jellyfin
```

### Network Architecture
- **secure_network**: Internal bridge for VPN-protected services
- **host network**: Jellyfin only (for mDNS/device discovery)
- Transmission/Jackett have NO direct internet access

### File Organization Structure
```
/mnt/storage/downloads/complete/ → /mnt/storage/media/
                                   ├── movies/Movie Name (Year)/
                                   └── tv/Show Name/Season XX/
```

## Critical Implementation Details

### VPN Kill Switch Implementation
The system implements a multi-layer kill switch:
1. Docker network isolation (no default route)
2. iptables rules in WireGuard container
3. Continuous monitoring via vpn-monitor.sh
4. Health checks that trigger container shutdown

### Media Organization Rules
- Uses hard links to avoid duplication
- Preserves original files in downloads
- Title case formatting for Jellyfin compatibility
- Season/episode detection for TV shows
- Automatic cleanup of empty directories

### Boot Sequence (Power Loss Recovery)
1. wait-for-network.service ensures network ready
2. boot-manager.sh orchestrates staged startup
3. WireGuard starts first and validated
4. Dependent services start only after VPN confirmed
5. Health monitoring begins after all services up

### Environment Variables (.env)
Critical variables that must be set:
- `PUID/PGID`: User permissions (typically 1000:1000)
- `TZ`: Timezone (e.g., America/Los_Angeles)
- `WIREGUARD_ENDPOINT`: VPN server details
- `TRANSMISSION_USER/PASS`: WebUI credentials

## Common Tasks & Troubleshooting

### Adding New Torrents
1. Search via Jackett web interface (port 9117)
2. Add magnet/torrent to Transmission (port 9091)
3. Monitor download progress
4. Check logs/media/ for organized files

### VPN Connection Issues
```bash
# Check WireGuard logs
docker logs wireguard

# Verify configuration
docker exec wireguard wg show

# Test connectivity
docker exec wireguard ping -c 1 1.1.1.1
```

### Storage Management
- Downloads cleaned after successful organization
- Hard links don't consume extra space
- Monitor /mnt/storage usage regularly

### Service Recovery
If services fail to start:
1. Check `sudo systemctl status mediaserver`
2. Review `/home/matthewhans/mediaserver-enhanced/logs/`
3. Verify VPN credentials in `config/wireguard/wg0.conf`
4. Run `./scripts/health-check.sh` for diagnostics

## Testing Approach
- Integration tests via test_search.py and test_magnet.py
- Health checks validate service connectivity
- VPN monitoring tests IP address and DNS resolution
- Media organizer can be tested with sample files