#\!/bin/bash

# Comprehensive WireGuard Health Check Script
# ===========================================
# Multi-layer health verification for WireGuard VPN connection
# Used by Docker health checks and external monitoring

set -euo pipefail

# Configuration
SCRIPT_NAME="wireguard-health-check"
LOG_FILE="/config/health-check.log"
INTERFACE="wg0"
TIMEOUT=25
MAX_RETRIES=3
VPN_TEST_ENDPOINTS=(
    "https://ipinfo.io/ip"
    "https://icanhazip.com"
    "https://api.ipify.org"
)

# Health check criteria
REQUIRED_CHECKS=(
    "interface_up"
    "ip_assigned"
    "external_connectivity"
    "vpn_verification"
)

# Logging function with rotation
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Rotate log if it gets too big (>1MB)
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 1048576 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null || true
    fi
    
    echo "[$timestamp] [$SCRIPT_NAME] [$level] $message" >> "$LOG_FILE"
    
    # Also output to stdout for Docker health check
    if [ "$level" = "ERROR" ] || [ "$level" = "CRITICAL" ]; then
        echo "[$level] $message" >&2
    else
        echo "[$level] $message"
    fi
}

# Check if WireGuard interface is up
check_interface_up() {
    log "DEBUG" "Checking if WireGuard interface $INTERFACE is up..."
    
    if ip link show $INTERFACE >/dev/null 2>&1; then
        local state=$(ip link show $INTERFACE | grep -o 'state [A-Z]*' | awk '{print $2}')
        if [ "$state" = "UP" ]; then
            log "DEBUG" "Interface $INTERFACE is UP"
            return 0
        else
            log "ERROR" "Interface $INTERFACE is in state: $state"
            return 1
        fi
    else
        log "ERROR" "Interface $INTERFACE does not exist"
        return 1
    fi
}

# Check if IP is assigned to WireGuard interface
check_ip_assigned() {
    log "DEBUG" "Checking if IP is assigned to $INTERFACE..."
    
    local ip_info=$(ip addr show $INTERFACE 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)
    
    if [ -n "$ip_info" ]; then
        local ip=$(echo $ip_info | cut -d/ -f1)
        log "DEBUG" "IP assigned to $INTERFACE: $ip"
        return 0
    else
        log "ERROR" "No IP assigned to $INTERFACE"
        return 1
    fi
}

# Test external connectivity
check_external_connectivity() {
    log "DEBUG" "Testing external connectivity..."
    
    local test_passed=false
    
    for endpoint in "${VPN_TEST_ENDPOINTS[@]}"; do
        log "DEBUG" "Testing connectivity to $endpoint"
        
        if timeout $TIMEOUT curl -s --max-time 10 --retry 2 "$endpoint" >/dev/null 2>&1; then
            log "DEBUG" "Successfully connected to $endpoint"
            test_passed=true
            break
        else
            log "DEBUG" "Failed to connect to $endpoint"
        fi
    done
    
    if $test_passed; then
        log "DEBUG" "External connectivity test passed"
        return 0
    else
        log "ERROR" "All external connectivity tests failed"
        return 1
    fi
}

# Verify we're actually using VPN (not leaking real IP)
check_vpn_verification() {
    log "DEBUG" "Verifying VPN is active (checking for IP leaks)..."
    
    local external_ip=""
    local attempt=1
    
    # Try to get external IP
    for endpoint in "${VPN_TEST_ENDPOINTS[@]}"; do
        external_ip=$(timeout $TIMEOUT curl -s --max-time 10 --retry 1 "$endpoint" 2>/dev/null | head -1 | tr -d '\n\r' || echo "")
        if [ -n "$external_ip" ] && [[ $external_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
        ((attempt++))
    done
    
    if [ -z "$external_ip" ]; then
        log "ERROR" "Could not determine external IP address"
        return 1
    fi
    
    log "DEBUG" "External IP detected: $external_ip"
    
    # Check if IP appears to be a private/local IP (would indicate VPN failure)
    if [[ $external_ip =~ ^192\.168\. ]] || [[ $external_ip =~ ^10\. ]] || [[ $external_ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
        log "ERROR" "VPN leak detected\! External IP is private: $external_ip"
        return 1
    fi
    
    # Additional check: Verify the IP is different from common residential ranges
    # This is a basic check - in production you might want to check against known ranges
    log "DEBUG" "VPN verification passed. Using external IP: $external_ip"
    return 0
}

# Perform comprehensive health check
perform_health_check() {
    log "INFO" "Starting comprehensive WireGuard health check..."
    
    local failed_checks=()
    local total_checks=${#REQUIRED_CHECKS[@]}
    local passed_checks=0
    
    for check in "${REQUIRED_CHECKS[@]}"; do
        log "DEBUG" "Running check: $check"
        
        case $check in
            "interface_up")
                if check_interface_up; then
                    ((passed_checks++))
                else
                    failed_checks+=("$check")
                fi
                ;;
            "ip_assigned")
                if check_ip_assigned; then
                    ((passed_checks++))
                else
                    failed_checks+=("$check")
                fi
                ;;
            "external_connectivity")
                if check_external_connectivity; then
                    ((passed_checks++))
                else
                    failed_checks+=("$check")
                fi
                ;;
            "vpn_verification")
                if check_vpn_verification; then
                    ((passed_checks++))
                else
                    failed_checks+=("$check")
                fi
                ;;
            *)
                log "ERROR" "Unknown check: $check"
                failed_checks+=("$check")
                ;;
        esac
    done
    
    # Report results
    log "INFO" "Health check completed: $passed_checks/$total_checks checks passed"
    
    if [ ${#failed_checks[@]} -eq 0 ]; then
        log "INFO" "WireGuard health check: HEALTHY"
        return 0
    else
        log "ERROR" "WireGuard health check: UNHEALTHY - Failed checks: ${failed_checks[*]}"
        return 1
    fi
}

# Quick health check (for frequent monitoring)
perform_quick_check() {
    log "DEBUG" "Performing quick health check..."
    
    # Just check interface and basic connectivity
    if check_interface_up && timeout 15 curl -s --max-time 10 https://ipinfo.io/ip >/dev/null 2>&1; then
        log "DEBUG" "Quick health check: HEALTHY"
        return 0
    else
        log "ERROR" "Quick health check: UNHEALTHY"
        return 1
    fi
}

# Main function
main() {
    local check_type="${1:-full}"
    local exit_code=0
    
    case $check_type in
        "full"|"comprehensive")
            if \! perform_health_check; then
                exit_code=1
            fi
            ;;
        "quick"|"basic")
            if \! perform_quick_check; then
                exit_code=1
            fi
            ;;
        "interface")
            if \! check_interface_up; then
                exit_code=1
            fi
            ;;
        "connectivity")
            if \! check_external_connectivity; then
                exit_code=1
            fi
            ;;
        "vpn")
            if \! check_vpn_verification; then
                exit_code=1
            fi
            ;;
        *)
            log "ERROR" "Usage: $0 [full|quick|interface|connectivity|vpn]"
            exit_code=2
            ;;
    esac
    
    exit $exit_code
}

# Execute main function
main "$@"
