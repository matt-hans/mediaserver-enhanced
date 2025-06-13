#\!/bin/bash

# Media Server Services Debug Script
# ==================================

echo "=== Media Server Service Debug Report ==="
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo "IP Address: $(hostname -I)"
echo ""

echo "=== Docker Container Status ==="
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

echo "=== Service URL Tests (Internal) ==="
echo "Jellyfin (8096): $(curl -s -o /dev/null -w "%{http_code}" http://localhost:8096 2>/dev/null || echo "FAIL")"
echo "Transmission (9091): $(curl -s -o /dev/null -w "%{http_code}" http://localhost:9091 2>/dev/null || echo "FAIL")"  
echo "Jackett (9117): $(curl -s -o /dev/null -w "%{http_code}" http://localhost:9117 2>/dev/null || echo "FAIL")"
echo ""

echo "=== Port Listening Status ==="
echo "Port 8096 (Jellyfin): $(netstat -ln | grep :8096 | wc -l) listeners"
echo "Port 9091 (Transmission): $(netstat -ln | grep :9091 | wc -l) listeners"
echo "Port 9117 (Jackett): $(netstat -ln | grep :9117 | wc -l) listeners"
echo ""

echo "=== WireGuard Container Network Inspection ==="
sudo docker exec wireguard ps aux | grep -E "(transmission|jackett)" | head -10
echo ""

echo "=== Service Configuration Check ==="
echo "Transmission config exists: $([ -f ./config/transmission/settings.json ] && echo "YES" || echo "NO")"
echo "Jackett config exists: $([ -d ./config/jackett ] && echo "YES" || echo "NO")"
echo "Jellyfin config exists: $([ -d ./config/jellyfin ] && echo "YES" || echo "NO")"
echo ""

echo "=== Environment Variables ==="
echo "JELLYFIN_PORT: ${JELLYFIN_PORT}"
echo "TRANSMISSION_PORT: ${TRANSMISSION_PORT}"  
echo "JACKETT_PORT: ${JACKETT_PORT}"
echo ""

echo "=== Recent Container Logs (last 10 lines each) ==="
echo "--- Jellyfin Logs ---"
sudo docker logs jellyfin --tail 10 2>/dev/null || echo "No logs available"
echo ""
echo "--- Transmission Logs ---"
sudo docker logs transmission --tail 10 2>/dev/null || echo "No logs available"
echo ""
echo "--- Jackett Logs ---"
sudo docker logs jackett --tail 10 2>/dev/null || echo "No logs available"
echo ""
echo "--- WireGuard Logs ---"
sudo docker logs wireguard --tail 10 2>/dev/null || echo "No logs available"
echo ""

echo "=== Debug Report Complete ==="
