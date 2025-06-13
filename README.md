# Enhanced Media Server for Raspberry Pi

A secure, containerized media server stack with VPN-protected torrenting, automatic media organization, and comprehensive monitoring.

## 🏗️ Architecture Overview

This system implements a secure media server using Docker containers with the following key components:

- **WireGuard VPN**: Secure tunnel for all torrent traffic
- **Transmission**: BitTorrent client (VPN-protected)
- **Jackett**: Torrent indexer proxy (VPN-protected)
- **Jellyfin**: Media server with hardware acceleration
- **Autoheal**: Container health monitoring and recovery
- **Watchtower**: Automatic container updates

### Security Features

- ✅ All torrent traffic routed through VPN
- ✅ Kill switch prevents IP leaks
- ✅ Network isolation between services
- ✅ Continuous VPN monitoring
- ✅ Emergency shutdown on VPN failure
- ✅ IP leak detection and prevention

## 📁 Directory Structure

```
mediaserver-enhanced/
├── docker-compose.yml          # Main service orchestration
├── .env                        # Environment configuration
├── config/                     # Service configurations
│   ├── wireguard/
│   │   └── wg0.conf           # VPN configuration template
│   ├── transmission/
│   ├── jackett/
│   └── jellyfin/
├── scripts/                    # Automation scripts
│   ├── setup.sh              # Initial system setup
│   ├── health-check.sh        # System health monitoring
│   ├── post-download.sh       # Media organization
│   ├── backup.sh              # Configuration backup
│   └── vpn-monitor.sh         # VPN monitoring
├── systemd/
│   └── mediaserver.service    # System service definition
├── storage/                    # Media and downloads
│   ├── media/                 # Organized media files
│   │   ├── movies/
│   │   ├── tv/
│   │   ├── music/
│   │   ├── books/
│   │   └── misc/
│   └── downloads/             # Download staging
│       ├── complete/
│       ├── incomplete/
│       └── watch/
└── docs/
    └── architecture.md         # Detailed architecture documentation
```

## 🚀 Quick Start

### Prerequisites

- Raspberry Pi 4 (recommended) with Raspberry Pi OS
- At least 32GB SD card (64GB+ recommended)
- Internet connection
- VPN provider that supports WireGuard

### 1. Initial Setup

```bash
# Clone the repository
git clone https://github.com/yourusername/mediaserver-enhanced.git
cd mediaserver-enhanced

# Run the automated setup script
sudo ./scripts/setup.sh
```

### 2. Configure VPN

Update the WireGuard configuration with your VPN provider details:

```bash
sudo nano /opt/mediaserver/config/wireguard/wg0.conf
```

Replace the placeholder values:
- `PLACEHOLDER_PRIVATE_KEY_HERE` - Your WireGuard private key
- `PLACEHOLDER_SERVER_PUBLIC_KEY_HERE` - VPN server's public key  
- `PLACEHOLDER_VPN_SERVER_ENDPOINT` - VPN server endpoint

### 3. Update Environment Settings

```bash
sudo nano /opt/mediaserver/.env
```

Configure essential settings:
- Set strong passwords for Transmission
- Update timezone
- Configure notification URLs (optional)

### 4. Start Services

```bash
# Start the media server
sudo systemctl start mediaserver

# Enable auto-start on boot
sudo systemctl enable mediaserver

# Check status
sudo systemctl status mediaserver
```

## 🔧 Configuration

### Environment Variables (.env)

| Variable | Description | Example |
|----------|-------------|---------|
| `PUID/PGID` | User/Group IDs for file permissions | `1000` |
| `TZ` | Timezone | `America/New_York` |
| `TRANSMISSION_USER/PASS` | Transmission credentials | `admin/secure_password` |
| `VPN_SERVER_URL` | WireGuard server endpoint | `vpn.provider.com` |
| `JELLYFIN_URL` | Public Jellyfin URL | `http://your-domain.com:8096` |

### VPN Configuration

The WireGuard configuration must be properly set up before starting services:

1. Obtain WireGuard credentials from your VPN provider
2. Update `/opt/mediaserver/config/wireguard/wg0.conf`
3. Test VPN connection: `sudo /opt/mediaserver/scripts/vpn-monitor.sh check`

### Service Ports

| Service | Port | Purpose |
|---------|------|---------|
| Jellyfin | 8096 | Media streaming interface |
| Transmission | 9091 | BitTorrent web interface |
| Jackett | 9117 | Indexer management |

## 🔍 Monitoring & Maintenance

### Health Monitoring

The system includes comprehensive monitoring:

```bash
# Manual health check
sudo /opt/mediaserver/scripts/health-check.sh

# VPN status check
sudo /opt/mediaserver/scripts/vpn-monitor.sh status

# View service logs
sudo journalctl -u mediaserver -f
```

### Automated Tasks

- **Health checks**: Every 5 minutes
- **VPN monitoring**: Every minute
- **Backups**: Daily at 3 AM
- **Updates**: Daily at 3 AM (Watchtower)

### Backup & Recovery

```bash
# Create manual backup
sudo /opt/mediaserver/scripts/backup.sh

# Backups are stored in: /var/backups/mediaserver/
# Retention: 30 days
```

## 🎬 Media Management

### Automatic Organization

Downloads are automatically organized by type:

- **Movies**: `/mnt/media/movies/`
- **TV Shows**: `/mnt/media/tv/Show Name/Season X/`
- **Music**: `/mnt/media/music/`
- **Books**: `/mnt/media/books/`
- **Other**: `/mnt/media/misc/`

### Jellyfin Setup

1. Access Jellyfin at `http://your-pi-ip:8096`
2. Complete initial setup wizard
3. Add media libraries pointing to `/media/` directories
4. Configure hardware acceleration (automatic on Raspberry Pi)

### Adding Content

1. **Through Jackett**: Configure indexers in Jackett web interface
2. **Manual**: Drop `.torrent` files in `/mnt/downloads/watch/`
3. **Transmission**: Add torrents directly via web interface

## 🛡️ Security

### VPN Protection

- All torrent traffic is encrypted and routed through VPN
- Kill switch prevents traffic if VPN disconnects
- Continuous monitoring with automatic recovery
- IP leak detection and emergency shutdown

### Access Control

- Strong passwords required for all services
- Network isolation between torrent and media services
- Regular security updates via Watchtower

### Privacy

- No logging of torrent activity
- Encrypted storage of sensitive configuration
- Optional anonymous usage statistics

## 🔧 Troubleshooting

### Common Issues

**VPN not connecting:**
```bash
# Check VPN configuration
sudo /opt/mediaserver/scripts/vpn-monitor.sh check

# View WireGuard logs
sudo docker logs wireguard
```

**Services not starting:**
```bash
# Check service status
sudo systemctl status mediaserver

# View detailed logs
sudo journalctl -u mediaserver -f
```

**Permission errors:**
```bash
# Fix file permissions
sudo chown -R mediaserver:mediaserver /opt/mediaserver
sudo chown -R mediaserver:mediaserver /mnt/media
sudo chown -R mediaserver:mediaserver /mnt/downloads
```

**High disk usage:**
```bash
# Check disk space
df -h

# Clean old downloads (configured in Transmission)
# Increase ratio limits or remove completed torrents
```

### Log Locations

- **System logs**: `sudo journalctl -u mediaserver`
- **Health monitoring**: `/var/log/mediaserver-health.log`
- **VPN monitoring**: `/var/log/mediaserver-vpn-monitor.log`
- **Backup logs**: `/var/log/mediaserver-backup.log`
- **Application logs**: `/opt/mediaserver/config/*/logs/`

## 🔄 Updates

### System Updates

```bash
# Update system packages
sudo apt update && sudo apt upgrade

# Restart media server
sudo systemctl restart mediaserver
```

### Container Updates

Watchtower automatically updates containers daily. For manual updates:

```bash
cd /opt/mediaserver
sudo docker-compose pull
sudo docker-compose up -d
```

## 📊 Performance Optimization

### Raspberry Pi Specific

- GPU memory split configured automatically
- Hardware transcoding enabled for Jellyfin
- Optimized kernel parameters
- Efficient file organization with hardlinks

### Network Optimization

- Bandwidth limiting in Transmission
- QoS prioritization for streaming
- Connection limits to prevent saturation

## 🆘 Emergency Procedures

### VPN Failure

If VPN fails, the system automatically:
1. Stops all torrent services immediately
2. Blocks network traffic from affected containers
3. Sends critical alerts
4. Attempts automatic recovery

### Manual Recovery

```bash
# Emergency stop all torrent services
sudo docker stop transmission jackett

# Restart VPN services
sudo /opt/mediaserver/scripts/vpn-monitor.sh restart

# Check system status
sudo /opt/mediaserver/scripts/health-check.sh
```

## 📝 Contributing

1. Fork the repository
2. Create a feature branch
3. Test thoroughly on Raspberry Pi
4. Submit pull request with detailed description

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments

- LinuxServer.io for excellent Docker images
- WireGuard for secure VPN technology
- The Jellyfin, Transmission, and Jackett communities
- Raspberry Pi Foundation for affordable computing

## 📞 Support

- **Issues**: GitHub Issues
- **Documentation**: `/docs/architecture.md`
- **Logs**: Check system logs for troubleshooting
- **Community**: Join the discussion in GitHub Discussions

---

**⚠️ Important Notes:**

- This system is designed for personal use and legal content only
- Always use a reputable VPN provider
- Keep your system and containers updated
- Monitor logs regularly for security issues
- Backup your configuration regularly

**🎯 Tip:** Run the health check script manually after any configuration changes to ensure everything is working correctly.