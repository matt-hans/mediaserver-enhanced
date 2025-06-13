#!/bin/bash
# VPN Connection Monitor Script
# =============================
# Continuously monitors VPN connection and prevents IP leaks
# This script provides an additional safety layer beyond Docker networking

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEDIASERVER_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/var/log/mediaserver-vpn-monitor.log"
LOCK_FILE="/tmp/vpn-monitor.lock"
ALERT_FILE="/tmp/vpn-alert-sent"

# VPN monitoring settings
VPN_CHECK_INTERVAL=60  # seconds between checks
MAX_FAILURES=3        # failures before taking action
EMERGENCY_MODE=false  # emergency shutdown mode

# Logging with rotation
log() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Rotate log if it gets too large (>10MB)
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 10485760 ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
    fi
    
    echo "$timestamp - VPN-MONITOR - $message" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    log "CRITICAL ERROR: $1"
    emergency_shutdown
    exit 1
}

# Lock mechanism to prevent multiple instances
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "Another VPN monitor instance is running (PID: $pid)"
            exit 0
        else
            log "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"; exit' EXIT INT TERM
}

# Release lock on exit
release_lock() {
    rm -f "$LOCK_FILE"
}

# Check if WireGuard container is running
check_wireguard_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^wireguard$"; then
        log "ERROR: WireGuard container is not running"
        return 1
    fi
    return 0
}

# Check VPN tunnel connectivity
check_vpn_tunnel() {
    local test_hosts=("8.8.8.8" "1.1.1.1" "9.9.9.9")
    local success_count=0
    
    for host in "${test_hosts[@]}"; do
        if docker exec wireguard ping -c1 -W3 "$host" &>/dev/null; then
            ((success_count++))
        fi
    done
    
    # At least 2 out of 3 hosts should be reachable
    if [ $success_count -ge 2 ]; then
        return 0
    else
        log "ERROR: VPN tunnel connectivity failed (only $success_count/3 hosts reachable)"
        return 1
    fi
}

# Critical: Check for IP leaks
check_ip_leak() {
    local real_ip vpn_ip
    local timeout=10
    
    # Get real IP (from host)
    real_ip=$(timeout $timeout curl -s https://ipinfo.io/ip 2>/dev/null || echo "unknown")
    
    # Get VPN IP (from wireguard container)
    vpn_ip=$(timeout $timeout docker exec wireguard curl -s https://ipinfo.io/ip 2>/dev/null || echo "unknown")
    
    log "IP Check - Real: $real_ip, VPN: $vpn_ip"
    
    # Critical check: If both IPs are the same and not unknown, we have a leak
    if [ "$real_ip" != "unknown" ] && [ "$vpn_ip" != "unknown" ] && [ "$real_ip" = "$vpn_ip" ]; then
        log "CRITICAL: IP LEAK DETECTED! Real IP is exposed: $real_ip"
        return 1
    fi
    
    # Additional check: VPN IP should not be from local/private ranges
    if [[ "$vpn_ip" =~ ^192\.168\. ]] || [[ "$vpn_ip" =~ ^10\. ]] || [[ "$vpn_ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
        log "WARNING: VPN IP appears to be from private range: $vpn_ip"
        return 1
    fi
    
    return 0
}

# Check VPN provider connectivity
check_vpn_provider() {
    local config_file="$MEDIASERVER_DIR/config/wireguard/wg0.conf"
    
    if [ ! -f "$config_file" ]; then
        log "ERROR: WireGuard config file not found: $config_file"
        return 1
    fi
    
    # Extract endpoint from config
    local endpoint
    endpoint=$(grep "^Endpoint" "$config_file" | cut -d'=' -f2 | tr -d ' ' || echo "")
    
    if [ -z "$endpoint" ]; then
        log "ERROR: Could not extract VPN endpoint from config"
        return 1
    fi
    
    local vpn_host vpn_port
    vpn_host=$(echo "$endpoint" | cut -d':' -f1)
    vpn_port=$(echo "$endpoint" | cut -d':' -f2)
    
    # Test connectivity to VPN provider
    if nc -z -w5 "$vpn_host" "$vpn_port" 2>/dev/null; then
        return 0
    else
        log "ERROR: Cannot reach VPN provider: $endpoint"
        return 1
    fi
}

# Emergency shutdown of torrent services
emergency_shutdown() {
    log "EMERGENCY: Shutting down torrent services to prevent IP exposure"
    
    EMERGENCY_MODE=true
    touch "$ALERT_FILE"
    
    # Stop torrent-related containers immediately
    docker stop transmission jackett 2>/dev/null || true
    
    # Block all traffic from these containers
    docker exec wireguard iptables -I OUTPUT -j DROP 2>/dev/null || true
    
    send_critical_alert "VPN failure detected - torrent services stopped"
    
    log "Emergency shutdown completed"
}

# Restart VPN and dependent services
restart_vpn_services() {
    log "Attempting to restart VPN services..."
    
    cd "$MEDIASERVER_DIR"
    
    # Stop dependent services first
    docker-compose stop transmission jackett
    
    # Restart WireGuard
    docker-compose restart wireguard
    
    # Wait for VPN to stabilize
    local retry_count=0
    local max_retries=10
    
    while [ $retry_count -lt $max_retries ]; do
        sleep 10
        
        if check_vpn_tunnel && check_ip_leak; then
            log "VPN connection restored"
            
            # Restart dependent services
            docker-compose start transmission jackett
            
            # Clear emergency mode
            EMERGENCY_MODE=false
            rm -f "$ALERT_FILE"
            
            log "All services restarted successfully"
            return 0
        fi
        
        ((retry_count++))
        log "VPN not ready yet, retry $retry_count/$max_retries"
    done
    
    log "ERROR: Failed to restore VPN connection after $max_retries attempts"
    return 1
}

# Send critical alerts
send_critical_alert() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local full_message="CRITICAL VPN ALERT - $timestamp
    
$message

System: $(hostname)
Status: Emergency Mode Active
Action: Torrent services stopped

Manual intervention may be required.
Check logs: $LOG_FILE"
    
    # Email alert
    if command -v mail >/dev/null 2>&1; then
        echo "$full_message" | mail -s "CRITICAL: VPN Failure on Media Server" root 2>/dev/null || true
    fi
    
    # Webhook alert
    if [ -n "${VPN_ALERT_WEBHOOK_URL:-}" ]; then
        curl -X POST -H 'Content-Type: application/json' \
             -d "{\"text\":\"$full_message\"}" \
             "$VPN_ALERT_WEBHOOK_URL" 2>/dev/null || true
    fi
    
    # System notification
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical "VPN Monitor" "$message" 2>/dev/null || true
    fi
    
    log "Critical alert sent: $message"
}

# Monitor VPN status
monitor_vpn() {
    local failure_count=0
    
    log "Starting VPN monitoring (checking every ${VPN_CHECK_INTERVAL}s)"
    
    while true; do
        local vpn_ok=true
        local issues=()
        
        # Check WireGuard container
        if ! check_wireguard_container; then
            vpn_ok=false
            issues+=("container_down")
        fi
        
        # Check VPN tunnel
        if ! check_vpn_tunnel; then
            vpn_ok=false
            issues+=("tunnel_failed")
        fi
        
        # Critical: Check for IP leaks
        if ! check_ip_leak; then
            vpn_ok=false
            issues+=("ip_leak")
            # IP leak is critical - immediate action required
            emergency_shutdown
            failure_count=$((MAX_FAILURES + 1))
        fi
        
        # Check VPN provider connectivity
        if ! check_vpn_provider; then
            vpn_ok=false
            issues+=("provider_unreachable")
        fi
        
        if [ "$vpn_ok" = true ]; then
            if [ $failure_count -gt 0 ]; then
                log "VPN connection restored after $failure_count failures"
                failure_count=0
                
                # Clear emergency mode if it was set
                if [ "$EMERGENCY_MODE" = true ]; then
                    EMERGENCY_MODE=false
                    rm -f "$ALERT_FILE"
                    log "Emergency mode cleared"
                fi
            fi
        else
            ((failure_count++))
            local issues_str
            issues_str=$(IFS=', '; echo "${issues[*]}")
            log "VPN check failed ($failure_count/$MAX_FAILURES): $issues_str"
            
            if [ $failure_count -ge $MAX_FAILURES ]; then
                log "Maximum failures reached, attempting VPN restart"
                
                if restart_vpn_services; then
                    failure_count=0
                else
                    log "VPN restart failed, entering extended monitoring"
                    send_critical_alert "VPN restart failed - manual intervention required"
                    sleep 300  # Wait 5 minutes before retrying
                fi
            fi
        fi
        
        sleep $VPN_CHECK_INTERVAL
    done
}

# Status check (for manual use)
status_check() {
    echo "VPN Monitor Status Check"
    echo "======================="
    echo ""
    
    echo -n "WireGuard Container: "
    if check_wireguard_container; then
        echo "Running"
    else
        echo "Not Running"
    fi
    
    echo -n "VPN Tunnel: "
    if check_vpn_tunnel; then
        echo "Connected"
    else
        echo "Failed"
    fi
    
    echo -n "IP Leak Check: "
    if check_ip_leak; then
        echo "Secure"
    else
        echo "LEAK DETECTED!"
    fi
    
    echo -n "VPN Provider: "
    if check_vpn_provider; then
        echo "Reachable"
    else
        echo "Unreachable"
    fi
    
    echo ""
    echo "Emergency Mode: $EMERGENCY_MODE"
    
    if [ -f "$ALERT_FILE" ]; then
        echo "Alert Status: Active"
    else
        echo "Alert Status: Clear"
    fi
}

# Show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  monitor    Start continuous VPN monitoring (default)"
    echo "  status     Show current VPN status"
    echo "  check      Run one-time VPN check"
    echo "  emergency  Trigger emergency shutdown"
    echo "  restart    Restart VPN services"
    echo "  help       Show this help message"
    echo ""
}

# Main function
main() {
    local command="${1:-monitor}"
    
    case "$command" in
        "monitor")
            acquire_lock
            monitor_vpn
            ;;
        "status")
            status_check
            ;;
        "check")
            log "Running one-time VPN check..."
            if check_wireguard_container && check_vpn_tunnel && check_ip_leak && check_vpn_provider; then
                echo "VPN Status: OK"
                log "VPN check passed"
            else
                echo "VPN Status: FAILED"
                log "VPN check failed"
                exit 1
            fi
            ;;
        "emergency")
            emergency_shutdown
            ;;
        "restart")
            restart_vpn_services
            ;;
        "help"|"-h"|"--help")
            usage
            ;;
        *)
            echo "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Error trap
trap 'log "ERROR: VPN monitor failed at line $LINENO"; release_lock' ERR

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Run main function
main "$@"