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
