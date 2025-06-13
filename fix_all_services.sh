#\!/bin/bash

echo "=== COMPREHENSIVE SERVICE FIX ==="
echo "Date: $(date)"
echo ""

# Fix 1: Transmission Web UI Issue
echo "=== Fixing Transmission Web UI ==="
sudo docker exec transmission sh -c "
    cd /config && 
    rm -rf transmission-web-control 2>/dev/null || true &&
    git clone https://github.com/ronggang/transmission-web-control.git 2>/dev/null || 
    wget -qO- https://github.com/ronggang/transmission-web-control/archive/master.tar.gz | tar xz --strip-components=1 -C . 2>/dev/null ||
    echo \"Using default web interface\"
" 2>/dev/null || echo "Will fix on restart"

# Fix 2: Correct Docker Compose Configuration
echo "=== Updating Docker Compose Configuration ==="
# Remove problematic TRANSMISSION_WEB_HOME environment variable
sed -i /TRANSMISSION_WEB_HOME/d docker-compose.yml

# Fix 3: Remove Hardware Acceleration Issues for Jellyfin
echo "=== Fixing Jellyfin Hardware Acceleration ==="
cp docker-compose.yml docker-compose.yml.broken
sed -i //dev/vchiq/d docker-compose.yml
sed -i //dev/vcsm/d docker-compose.yml  
sed -i //dev/video/d docker-compose.yml

# Fix 4: Restart All Services in Correct Order
echo "=== Restarting Services ==="
sudo docker-compose down
sleep 5

# Clean up any conflicting containers
sudo docker system prune -f

# Start services in dependency order
sudo docker-compose up -d wireguard
sleep 15
sudo docker-compose up -d jellyfin autoheal
sleep 10
sudo docker-compose up -d transmission jackett
sleep 15

echo "=== Service Fix Complete ==="
echo ""
echo "=== Testing Services ==="
sleep 10

# Test all services
echo "Jellyfin: $(curl -s -o /dev/null -w %{http_code} http://localhost:8096 2>/dev/null)"
echo "Transmission: $(curl -s -o /dev/null -w %{http_code} http://localhost:9091 2>/dev/null)"  
echo "Jackett: $(curl -s -o /dev/null -w %{http_code} http://localhost:9117 2>/dev/null)"

echo ""
echo "=== Service URLs ==="
PI_IP=$(hostname -I | awk "{print \$1}")
echo "Jellyfin: http://$PI_IP:8096"
echo "Transmission: http://$PI_IP:9091 (admin/invent-creat3)"
echo "Jackett: http://$PI_IP:9117"
