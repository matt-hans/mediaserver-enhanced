#\!/bin/bash
# Network Detection and Auto-Configuration Script
# Agent 3 Implementation - Senior DevOps Engineer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"
LOG_FILE="/tmp/network-detect.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [NETWORK-DETECT] $1" | tee -a "$LOG_FILE"
}

# Detect network environment and return type
detect_network_type() {
    local gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    local external_ip=$(timeout 10 curl -s https://ipinfo.io/ip 2>/dev/null || echo "unknown")
    
    log "Gateway: $gateway, External IP: $external_ip"
    
    # Check if behind carrier-grade NAT
    if [[ $gateway =~ ^10\. ]] || [[ $gateway =~ ^100\.[6-9][4-9]\. ]] || [[ $gateway =~ ^100\.[7-9][0-9]\. ]] || [[ $gateway =~ ^100\.1[0-2][0-9]\. ]]; then
        echo "cgnat"
    # Check for typical home router ranges
    elif [[ $gateway =~ ^192\.168\. ]] || [[ $gateway =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
        echo "home"
    else
        echo "direct"
    fi
}

# Auto-detect optimal MTU
detect_mtu() {
    local base_mtu=1420
    local test_host="8.8.8.8"
    
    # Test different MTU sizes
    for mtu in 1420 1380 1350 1280; do
        if ping -c 1 -M do -s $((mtu - 28)) $test_host >/dev/null 2>&1; then
            echo $mtu
            return
        fi
    done
    echo 1280  # Fallback
}

# Select best WireGuard config based on location/performance
select_wireguard_config() {
    local config_dir="$CONFIG_DIR/wireguard"
    local best_config=""
    local best_latency=9999
    
    log "Testing WireGuard configurations..."
    
    # Test a few configs for latency
    for config in "$config_dir"/se-got-wg-*.conf "$config_dir"/se-sto-wg-*.conf; do
        [[ -f "$config" ]] || continue
        
        local endpoint=$(grep "Endpoint" "$config" | cut -d' ' -f3 | cut -d: -f1)
        if [[ -n "$endpoint" ]]; then
            local latency=$(timeout 5 ping -c 1 "$endpoint" 2>/dev/null | grep 'time=' | sed 's/.*time=\([0-9.]*\).*/\1/' || echo "9999")
            log "Config $(basename "$config"): $endpoint latency ${latency}ms"
            
            if (( $(echo "$latency < $best_latency" | bc -l 2>/dev/null || echo 0) )); then
                best_latency=$latency
                best_config=$config
            fi
        fi
        
        # Only test first 3 configs to avoid delays
        [[ $(($RANDOM % 3)) -eq 0 ]] && break
    done
    
    if [[ -n "$best_config" ]]; then
        log "Selected: $(basename "$best_config") (latency: ${best_latency}ms)"
        echo "$best_config"
    else
        log "No working config found, using default"
        echo "$config_dir/wg0.conf"
    fi
}

# Apply network-specific optimizations
apply_network_optimizations() {
    local network_type="$1"
    local mtu="$2"
    local selected_config="$3"
    
    log "Applying optimizations for $network_type network (MTU: $mtu)"
    
    # Copy selected config to active config
    cp "$selected_config" "$CONFIG_DIR/wireguard/wg0.conf"
    
    # Update MTU in config
    if grep -q "MTU" "$CONFIG_DIR/wireguard/wg0.conf"; then
        sed -i "s/MTU = .*/MTU = $mtu/" "$CONFIG_DIR/wireguard/wg0.conf"
    else
        sed -i '/\[Interface\]/a MTU = '$mtu "$CONFIG_DIR/wireguard/wg0.conf"
    fi
    
    # Add persistent keepalive based on network type
    local keepalive=25
    case $network_type in
        cgnat) keepalive=15 ;;
        home) keepalive=25 ;;
        direct) keepalive=60 ;;
    esac
    
    if \! grep -q "PersistentKeepalive" "$CONFIG_DIR/wireguard/wg0.conf"; then
        sed -i '/\[Peer\]/a PersistentKeepalive = '$keepalive "$CONFIG_DIR/wireguard/wg0.conf"
    else
        sed -i "s/PersistentKeepalive = .*/PersistentKeepalive = $keepalive/" "$CONFIG_DIR/wireguard/wg0.conf"
    fi
    
    log "WireGuard configuration updated with MTU=$mtu, KeepAlive=$keepalive"
}

# Main execution
main() {
    log "Starting network detection and configuration..."
    
    local network_type=$(detect_network_type)
    local optimal_mtu=$(detect_mtu)
    local selected_config=$(select_wireguard_config)
    
    log "Network Type: $network_type"
    log "Optimal MTU: $optimal_mtu"
    log "Selected Config: $(basename "$selected_config")"
    
    apply_network_optimizations "$network_type" "$optimal_mtu" "$selected_config"
    
    # Export environment variables for docker-compose
    cat > "$(dirname "$SCRIPT_DIR")/.env.network" << EOL
# Auto-generated network configuration
DETECTED_NETWORK_TYPE=$network_type
DETECTED_MTU=$optimal_mtu
WIREGUARD_CONFIG=$(basename "$selected_config")
WIREGUARD_KEEPALIVE=$keepalive
DETECTION_TIMESTAMP=$(date -Iseconds)
EOL
    
    log "Network configuration complete. Environment saved to .env.network"
}

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
