#!/bin/bash

# VPN Manager Script with Smart Server Selection
# ==============================================
# Implements intelligent VPN server selection with automatic failover
# Author: Media Server Development Team
# Version: 2.0

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly CONFIG_DIR="$PROJECT_DIR/config"
readonly LOGS_DIR="$PROJECT_DIR/logs"
readonly VPN_CONFIG_DIR="$CONFIG_DIR/wireguard"
readonly VPN_STATE_FILE="/tmp/vpn-manager-state"
readonly VPN_METRICS_FILE="$LOGS_DIR/vpn-metrics.log"
readonly LOG_FILE="$LOGS_DIR/vpn-manager.log"

# VPN Configuration
readonly VPN_INTERFACE="wg0"
readonly CONNECTION_TIMEOUT=30
readonly PERFORMANCE_TEST_TIMEOUT=10
readonly MAX_RETRY_ATTEMPTS=3

# Create logs directory if it doesn't exist
mkdir -p "$LOGS_DIR"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    
    # Also log to systemd journal
    if command -v systemd-cat >/dev/null 2>&1; then
        echo "[$level] $message" | systemd-cat -t vpn-manager
    fi
}

# Error handling
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Get list of available VPN configurations
get_vpn_configs() {
    local configs=()
    if [[ -d "$VPN_CONFIG_DIR" ]]; then
        while IFS= read -r -d '' config; do
            # Skip the active wg0.conf and backup files
            if [[ "$(basename "$config")" != "wg0.conf" ]] && [[ ! "$config" =~ \.backup$ ]]; then
                configs+=("$config")
            fi
        done < <(find "$VPN_CONFIG_DIR" -name "*.conf" -print0 2>/dev/null)
    fi
    
    printf '%s\n' "${configs[@]}"
}

# Get original IP address (before VPN)
get_original_ip() {
    local original_ip
    original_ip=$(curl -s --max-time 10 https://api.ipify.org || echo "")
    echo "$original_ip"
}

# Test VPN server connectivity
test_vpn_server() {
    local config_file="$1"
    local config_name
    config_name=$(basename "$config_file" .conf)
    
    log "INFO" "Testing VPN server: $config_name"
    
    # Backup current configuration
    if [[ -f "$VPN_CONFIG_DIR/wg0.conf" ]]; then
        cp "$VPN_CONFIG_DIR/wg0.conf" "$VPN_CONFIG_DIR/wg0.conf.backup"
    fi
    
    # Copy test configuration
    cp "$config_file" "$VPN_CONFIG_DIR/wg0.conf"
    
    # Try to bring up VPN interface
    local start_time=$(date +%s)
    if wg-quick down "$VPN_INTERFACE" >/dev/null 2>&1; then
        log "DEBUG" "Brought down existing VPN interface"
    fi
    
    if wg-quick up "$VPN_INTERFACE" >/dev/null 2>&1; then
        log "INFO" "VPN interface brought up successfully"
        
        # Test connectivity
        local test_success=false
        local test_start=$(date +%s)
        
        # Wait for connection to stabilize
        sleep 3
        
        # Test external connectivity through VPN
        if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
            log "INFO" "Basic connectivity test passed"
            
            # Test HTTP connectivity
            local vpn_ip
            vpn_ip=$(curl -s --max-time 10 https://api.ipify.org || echo "")
            
            if [[ -n "$vpn_ip" ]]; then
                local test_end=$(date +%s)
                local connection_time=$((test_end - test_start))
                
                log "INFO" "VPN server $config_name: IP=$vpn_ip, Connection time=${connection_time}s"
                
                # Log metrics for future reference
                echo "$(date '+%Y-%m-%d %H:%M:%S'),$config_name,$vpn_ip,$connection_time" >> "$VPN_METRICS_FILE"
                
                test_success=true
            else
                log "WARN" "Could not verify VPN IP for $config_name"
            fi
        else
            log "WARN" "Basic connectivity test failed for $config_name"
        fi
        
        # Bring down test interface
        wg-quick down "$VPN_INTERFACE" >/dev/null 2>&1 || true
        
        # Restore backup if it exists
        if [[ -f "$VPN_CONFIG_DIR/wg0.conf.backup" ]]; then
            mv "$VPN_CONFIG_DIR/wg0.conf.backup" "$VPN_CONFIG_DIR/wg0.conf"
        fi
        
        if $test_success; then
            local total_time=$(($(date +%s) - start_time))
            echo "$config_name:$total_time:$vpn_ip"
            return 0
        fi
    else
        log "WARN" "Failed to bring up VPN interface for $config_name"
        
        # Restore backup if it exists
        if [[ -f "$VPN_CONFIG_DIR/wg0.conf.backup" ]]; then
            mv "$VPN_CONFIG_DIR/wg0.conf.backup" "$VPN_CONFIG_DIR/wg0.conf"
        fi
    fi
    
    return 1
}

# Select best VPN server based on performance
select_best_vpn_server() {
    log "INFO" "Starting VPN server selection process"
    
    local configs
    mapfile -t configs < <(get_vpn_configs)
    
    if [[ ${#configs[@]} -eq 0 ]]; then
        error_exit "No VPN configurations found in $VPN_CONFIG_DIR"
    fi
    
    log "INFO" "Found ${#configs[@]} VPN configurations"
    
    local best_config=""
    local best_time=999999
    local working_servers=()
    
    # Test all available servers
    for config in "${configs[@]}"; do
        local result
        if result=$(test_vpn_server "$config" 2>/dev/null); then
            local config_name
            local connection_time
            local ip_address
            
            IFS=':' read -r config_name connection_time ip_address <<< "$result"
            working_servers+=("$config:$connection_time")
            
            log "INFO" "Server $config_name working: ${connection_time}s"
            
            # Track the fastest server
            if [[ $connection_time -lt $best_time ]]; then
                best_time=$connection_time
                best_config="$config"
            fi
        else
            local config_name
            config_name=$(basename "$config" .conf)
            log "WARN" "Server $config_name failed connectivity test"
        fi
    done
    
    if [[ -z "$best_config" ]]; then
        error_exit "No working VPN servers found"
    fi
    
    local best_name
    best_name=$(basename "$best_config" .conf)
    log "INFO" "Selected best VPN server: $best_name (${best_time}s)"
    
    echo "$best_config"
}

# Connect to VPN with the best available server
connect_vpn() {
    log "INFO" "Starting VPN connection process"
    
    # Get original IP for comparison
    local original_ip
    original_ip=$(get_original_ip)
    if [[ -n "$original_ip" ]]; then
        log "INFO" "Original IP: $original_ip"
    fi
    
    # Select best server
    local best_server
    best_server=$(select_best_vpn_server)
    
    if [[ -z "$best_server" ]]; then
        error_exit "Could not select a working VPN server"
    fi
    
    # Connect to the selected server
    log "INFO" "Connecting to VPN server: $(basename "$best_server" .conf)"
    
    # Ensure any existing connection is down
    wg-quick down "$VPN_INTERFACE" >/dev/null 2>&1 || true
    
    # Copy the selected configuration
    cp "$best_server" "$VPN_CONFIG_DIR/wg0.conf"
    
    # Bring up the VPN interface
    if wg-quick up "$VPN_INTERFACE"; then
        log "INFO" "VPN interface brought up successfully"
        
        # Wait for connection to stabilize
        sleep 5
        
        # Verify connection
        local vpn_ip
        vpn_ip=$(curl -s --max-time 15 https://api.ipify.org || echo "")
        
        if [[ -n "$vpn_ip" ]] && [[ "$vpn_ip" != "$original_ip" ]]; then
            log "INFO" "VPN connection established successfully"
            log "INFO" "VPN IP: $vpn_ip"
            
            # Save state
            echo "connected:$(basename "$best_server" .conf):$vpn_ip:$(date +%s)" > "$VPN_STATE_FILE"
            
            return 0
        else
            log "ERROR" "VPN connection verification failed"
            wg-quick down "$VPN_INTERFACE" >/dev/null 2>&1 || true
            return 1
        fi
    else
        error_exit "Failed to bring up VPN interface"
    fi
}

# Disconnect VPN
disconnect_vpn() {
    log "INFO" "Disconnecting VPN"
    
    if wg-quick down "$VPN_INTERFACE" 2>/dev/null; then
        log "INFO" "VPN disconnected successfully"
    else
        log "WARN" "VPN interface was not active or failed to disconnect"
    fi
    
    # Clear state
    rm -f "$VPN_STATE_FILE"
}

# Check VPN status
check_vpn_status() {
    local is_connected=false
    local config_name=""
    local vpn_ip=""
    local connected_since=""
    
    # Check if interface is up
    if ip link show "$VPN_INTERFACE" >/dev/null 2>&1; then
        # Check if there's an IP address assigned
        if ip addr show "$VPN_INTERFACE" | grep -q "inet "; then
            is_connected=true
            
            # Get current IP
            vpn_ip=$(curl -s --max-time 10 https://api.ipify.org || echo "")
            
            # Read state file if it exists
            if [[ -f "$VPN_STATE_FILE" ]]; then
                local state_line
                state_line=$(cat "$VPN_STATE_FILE")
                IFS=':' read -r _ config_name _ connected_since <<< "$state_line"
            fi
        fi
    fi
    
    if $is_connected; then
        local uptime=""
        if [[ -n "$connected_since" ]]; then
            local current_time=$(date +%s)
            local duration=$((current_time - connected_since))
            uptime=" (uptime: ${duration}s)"
        fi
        
        echo "Status: Connected"
        echo "Server: ${config_name:-unknown}"
        echo "VPN IP: ${vpn_ip:-unknown}"
        echo "Interface: $VPN_INTERFACE"
        echo "Uptime: $uptime"
    else
        echo "Status: Disconnected"
    fi
    
    return $($is_connected && echo 0 || echo 1)
}

# Reconnect with better server if available
reconnect_vpn() {
    log "INFO" "Reconnecting VPN with server selection"
    
    disconnect_vpn
    sleep 2
    connect_vpn
}

# Monitor VPN connection health
monitor_vpn() {
    log "INFO" "Starting VPN health monitoring"
    
    while true; do
        if ! check_vpn_status >/dev/null 2>&1; then
            log "WARN" "VPN connection lost, attempting to reconnect"
            connect_vpn
        else
            # Test connectivity
            if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
                log "WARN" "VPN connectivity test failed, reconnecting"
                reconnect_vpn
            fi
        fi
        
        sleep 30
    done
}

# List available VPN servers
list_servers() {
    echo "Available VPN servers:"
    local configs
    mapfile -t configs < <(get_vpn_configs)
    
    for config in "${configs[@]}"; do
        local config_name
        config_name=$(basename "$config" .conf)
        echo "  - $config_name"
    done
}

# Show usage
show_usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  connect    - Connect to best available VPN server"
    echo "  disconnect - Disconnect from VPN"
    echo "  status     - Show current VPN status"
    echo "  reconnect  - Reconnect with server selection"
    echo "  monitor    - Monitor VPN health (runs continuously)"
    echo "  list       - List available VPN servers"
    echo "  test       - Test all servers and show performance"
    echo "  help       - Show this help message"
}

# Test all servers and show results
test_servers() {
    echo "Testing all VPN servers..."
    echo "=========================="
    
    local configs
    mapfile -t configs < <(get_vpn_configs)
    
    for config in "${configs[@]}"; do
        local config_name
        config_name=$(basename "$config" .conf)
        echo -n "Testing $config_name... "
        
        if result=$(test_vpn_server "$config" 2>/dev/null); then
            IFS=':' read -r _ connection_time ip_address <<< "$result"
            echo "OK (${connection_time}s, IP: $ip_address)"
        else
            echo "FAILED"
        fi
    done
}

# Main command dispatcher
main() {
    local command="${1:-}"
    
    case "$command" in
        "connect")
            connect_vpn
            ;;
        "disconnect")
            disconnect_vpn
            ;;
        "status")
            check_vpn_status
            ;;
        "reconnect")
            reconnect_vpn
            ;;
        "monitor")
            monitor_vpn
            ;;
        "list")
            list_servers
            ;;
        "test")
            test_servers
            ;;
        "help"|"--help"|"")
            show_usage
            ;;
        *)
            echo "Unknown command: $command" >&2
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Check if running as root (required for WireGuard operations)
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root (VPN operations require root privileges)"
fi

# Run main function with all arguments
main "$@"