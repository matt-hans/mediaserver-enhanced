#\!/bin/bash

# Media Server Services Fix Script
# ===============================

echo "=== Media Server Service Fix Script ==="
echo "Date: $(date)"
echo ""

# Step 1: Check current service status
echo "=== Current Service Status ==="
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(transmission|jackett|jellyfin|wireguard)"
echo ""

# Step 2: Fix watchtower if it is restarting
echo "=== Fixing Watchtower ==="
WATCHTOWER_STATUS=$(sudo docker ps --filter "name=watchtower" --format "{{.Status}}")
if [[ "$WATCHTOWER_STATUS" == *"Restarting"* ]]; then
    echo "Watchtower is restarting, stopping and removing..."
    sudo docker stop watchtower 2>/dev/null || true
    sudo docker rm watchtower 2>/dev/null || true
    echo "Watchtower removed. Will be recreated on next docker-compose up."
else
    echo "Watchtower is running normally."
fi
echo ""

# Step 3: Check and fix transmission settings
echo "=== Checking Transmission Configuration ==="
if [ -f "./config/transmission/settings.json" ]; then
    echo "Transmission settings.json exists"
    # Check if authentication is properly configured
    if grep -q "rpc-authentication-required.*true" "./config/transmission/settings.json"; then
        echo "Transmission authentication is enabled"
    else
        echo "Transmission authentication might not be configured properly"
    fi
else
    echo "Transmission settings.json not found - will be created on first run"
fi
echo ""

# Step 4: Test internal connectivity
echo "=== Testing Internal Service Connectivity ==="
echo "Testing Jellyfin..."
JELLYFIN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8096 2>/dev/null || echo "FAIL")
echo "Jellyfin (http://localhost:8096): $JELLYFIN_STATUS"

echo "Testing Transmission..."
TRANS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9091 2>/dev/null || echo "FAIL")
echo "Transmission (http://localhost:9091): $TRANS_STATUS"

echo "Testing Jackett..."
JACKETT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9117 2>/dev/null || echo "FAIL")
echo "Jackett (http://localhost:9117): $JACKETT_STATUS"
echo ""

# Step 5: Check if services are accessible via transmission and jackett containers
echo "=== Testing Service Accessibility in Containers ==="
echo "Testing Transmission container internal access..."
sudo docker exec transmission curl -s -o /dev/null -w "Transmission internal: %{http_code}\\n" http://localhost:9091 2>/dev/null || echo "Transmission container curl failed"

echo "Testing Jackett container internal access..."
sudo docker exec jackett curl -s -o /dev/null -w "Jackett internal: %{http_code}\\n" http://localhost:9117 2>/dev/null || echo "Jackett container curl failed"
echo ""

# Step 6: Provide service URLs
echo "=== Service URLs ==="
PI_IP=$(hostname -I | awk {print })
echo "Jellyfin: http://$PI_IP:8096"
echo "Transmission: http://$PI_IP:9091 (Username: admin, Password: invent-creat3)"
echo "Jackett: http://$PI_IP:9117"
echo ""

# Step 7: Create a service status monitoring script
cat > service_monitor.sh << "INNER_EOF"
#\!/bin/bash
# Service Monitor Script
while true; do
    clear
    echo "=== Media Server Status Monitor ==="
    echo "Press Ctrl+C to exit"
    echo "Updated: $(date)"
    echo ""
    
    # Container status
    echo "Container Status:"
    sudo docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "(transmission|jackett|jellyfin|wireguard|watchtower)" | head -6
    echo ""
    
    # Service accessibility
    echo "Service Accessibility:"
    PI_IP=$(hostname -I | awk {print })
    echo "Jellyfin ($PI_IP:8096): $(curl -s -o /dev/null -w %{http_code} http://localhost:8096 2>/dev/null || echo FAIL)"
    echo "Transmission ($PI_IP:9091): $(curl -s -o /dev/null -w %{http_code} http://localhost:9091 2>/dev/null || echo FAIL)"
    echo "Jackett ($PI_IP:9117): $(curl -s -o /dev/null -w %{http_code} http://localhost:9117 2>/dev/null || echo FAIL)"
    echo ""
    
    sleep 5
done
INNER_EOF
chmod +x service_monitor.sh

echo "=== Fix Script Complete ==="
echo "Service monitor script created: ./service_monitor.sh"
echo "Run it with: ./service_monitor.sh"
