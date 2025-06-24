#!/bin/bash

# Enhanced Service Monitor with SystemD Integration
# =================================================
# Monitors service health and integrates with systemd for status reporting
# Author: Media Server Development Team
# Version: 2.0

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly LOGS_DIR="$PROJECT_DIR/logs"
readonly LOG_FILE="$LOGS_DIR/service-monitor.log"
readonly STATUS_FILE="/tmp/service-monitor-status"
readonly LOCK_FILE="/tmp/service-monitor.lock"

# Monitoring configuration
readonly CHECK_INTERVAL=60
readonly UNHEALTHY_THRESHOLD=3
readonly RESTART_COOLDOWN=300
readonly MAX_RESTART_ATTEMPTS=5

# Create logs directory
mkdir -p "$LOGS_DIR"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    
    # Log to systemd journal
    if command -v systemd-cat >/dev/null 2>&1; then
        echo "[$level] $message" | systemd-cat -t service-monitor
    fi
}

# Cleanup function
cleanup() {
    rm -f "$LOCK_FILE"
}

# Trap cleanup
trap cleanup EXIT INT TERM

# Lock mechanism
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log "ERROR" "Another monitor instance is running (PID: $lock_pid)"
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# Check if a Docker container is healthy
check_container_health() {
    local container_name="$1"
    local health_status
    
    # Check if container exists and is running
    if ! docker inspect "$container_name" >/dev/null 2>&1; then
        echo "not_found"
        return 1
    fi
    
    # Get container state
    local container_state
    container_state=$(docker inspect --format='{{.State.Status}}' "$container_name")
    
    if [[ "$container_state" != "running" ]]; then
        echo "not_running"
        return 1
    fi
    
    # Check health status if available
    health_status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no_healthcheck{{end}}' "$container_name")
    
    case "$health_status" in
        "healthy")
            echo "healthy"
            return 0
            ;;
        "unhealthy")
            echo "unhealthy"
            return 1
            ;;
        "starting")
            echo "starting"
            return 2
            ;;
        "no_healthcheck")
            # If no healthcheck, consider it healthy if running
            echo "running_no_healthcheck"
            return 0
            ;;
        *)
            echo "unknown"
            return 1
            ;;
    esac
}

# Check VPN connectivity
check_vpn_connectivity() {
    local vpn_interface="wg0"
    
    # Check if VPN interface exists
    if ! ip link show "$vpn_interface" >/dev/null 2>&1; then
        echo "interface_down"
        return 1
    fi
    
    # Check if interface has IP
    if ! ip addr show "$vpn_interface" | grep -q "inet "; then
        echo "no_ip"
        return 1
    fi
    
    # Test external connectivity
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        echo "connected"
        return 0
    else
        echo "no_connectivity"
        return 1
    fi
}

# Check service responsiveness
check_service_responsiveness() {
    local service="$1"
    local port="$2"
    local endpoint="${3:-/}"
    local timeout="${4:-10}"
    
    case "$service" in
        "jellyfin")
            if curl -f -s --max-time "$timeout" "http://localhost:$port/health" >/dev/null 2>&1; then
                echo "responsive"
                return 0
            fi
            ;;
        "transmission")
            if curl -f -s --max-time "$timeout" "http://localhost:$port" >/dev/null 2>&1; then
                echo "responsive"
                return 0
            fi
            ;;
        "jackett")
            if curl -f -s --max-time "$timeout" "http://localhost:$port" >/dev/null 2>&1; then
                echo "responsive"
                return 0
            fi
            ;;
    esac
    
    echo "unresponsive"
    return 1
}

# Get service status
get_service_status() {
    local service_name="$1"
    local status_data="{\"timestamp\": $(date +%s), \"service\": \"$service_name\""
    
    case "$service_name" in
        "vpn")
            local vpn_status
            vpn_status=$(check_vpn_connectivity)
            status_data+=", \"status\": \"$vpn_status\""
            ;;
        "wireguard"|"transmission"|"jackett"|"jellyfin"|"autoheal"|"watchtower")
            local container_health
            container_health=$(check_container_health "$service_name")
            status_data+=", \"container_status\": \"$container_health\""
            
            # Additional service-specific checks
            case "$service_name" in
                "jellyfin")
                    local responsiveness
                    responsiveness=$(check_service_responsiveness "jellyfin" "8096")
                    status_data+=", \"responsiveness\": \"$responsiveness\""
                    ;;
                "transmission")
                    if [[ "$container_health" == "healthy" || "$container_health" == "running_no_healthcheck" ]]; then
                        local responsiveness
                        responsiveness=$(check_service_responsiveness "transmission" "9091")
                        status_data+=", \"responsiveness\": \"$responsiveness\""
                    fi
                    ;;
                "jackett")
                    if [[ "$container_health" == "healthy" || "$container_health" == "running_no_healthcheck" ]]; then
                        local responsiveness
                        responsiveness=$(check_service_responsiveness "jackett" "9117")
                        status_data+=", \"responsiveness\": \"$responsiveness\""
                    fi
                    ;;
            esac
            ;;
    esac
    
    status_data+="}"
    echo "$status_data"
}

# Check overall system health
check_system_health() {
    local overall_status="healthy"
    local issues=()
    
    # Services to monitor
    local services=("vpn" "wireguard" "transmission" "jackett" "jellyfin" "autoheal" "watchtower")
    
    log "INFO" "Starting system health check"
    
    for service in "${services[@]}"; do
        local service_status
        service_status=$(get_service_status "$service")
        
        # Parse status for issues
        case "$service" in
            "vpn")
                if echo "$service_status" | grep -q '"status": "interface_down\|no_ip\|no_connectivity"'; then
                    issues+=("VPN connectivity issue")
                    overall_status="degraded"
                fi
                ;;
            *)
                if echo "$service_status" | grep -q '"container_status": "not_found\|not_running\|unhealthy"'; then
                    issues+=("$service container unhealthy")
                    overall_status="degraded"
                fi
                
                if echo "$service_status" | grep -q '"responsiveness": "unresponsive"'; then
                    issues+=("$service not responding")
                    overall_status="degraded"
                fi
                ;;
        esac
        
        log "DEBUG" "$service status: $service_status"
    done
    
    # Overall assessment
    if [[ ${#issues[@]} -eq 0 ]]; then
        log "INFO" "System health check: All services healthy"
    else
        log "WARN" "System health check: Issues detected - ${issues[*]}"
    fi
    
    # Update status file
    cat > "$STATUS_FILE" << EOF
{
    "timestamp": $(date +%s),
    "overall_status": "$overall_status",
    "issues": [$(printf '"%s",' "${issues[@]}" | sed 's/,$//')]
}
EOF
    
    return $(( ${#issues[@]} > 0 ? 1 : 0 ))
}

# Restart unhealthy services
restart_unhealthy_services() {
    log "INFO" "Checking for services that need restart"
    
    cd "$PROJECT_DIR"
    
    # Get list of unhealthy containers
    local unhealthy_containers
    unhealthy_containers=$(docker-compose ps --services --filter "health=unhealthy" 2>/dev/null || echo "")
    
    if [[ -n "$unhealthy_containers" ]]; then
        log "WARN" "Found unhealthy containers: $unhealthy_containers"
        
        # Restart unhealthy containers
        for container in $unhealthy_containers; do
            log "INFO" "Restarting unhealthy container: $container"
            if docker-compose restart "$container"; then
                log "INFO" "Successfully restarted $container"
            else
                log "ERROR" "Failed to restart $container"
            fi
        done
    fi
    
    # Check for exited containers
    local exited_containers
    exited_containers=$(docker-compose ps --services --filter "status=exited" 2>/dev/null || echo "")
    
    if [[ -n "$exited_containers" ]]; then
        log "WARN" "Found exited containers: $exited_containers"
        
        for container in $exited_containers; do
            log "INFO" "Starting exited container: $container"
            if docker-compose start "$container"; then
                log "INFO" "Successfully started $container"
            else
                log "ERROR" "Failed to start $container"
            fi
        done
    fi
}

# Monitor loop
monitor_loop() {
    log "INFO" "Starting service monitoring loop"
    
    local failure_count=0
    local last_restart=0
    
    while true; do
        if check_system_health; then
            failure_count=0
            log "DEBUG" "System health check passed"
        else
            ((failure_count++))
            log "WARN" "System health check failed (failure count: $failure_count)"
            
            # If we've had consecutive failures, attempt recovery
            if [[ $failure_count -ge $UNHEALTHY_THRESHOLD ]]; then
                local current_time=$(date +%s)
                local time_since_restart=$((current_time - last_restart))
                
                if [[ $time_since_restart -ge $RESTART_COOLDOWN ]]; then
                    log "INFO" "Attempting to restart unhealthy services"
                    restart_unhealthy_services
                    last_restart=$current_time
                    failure_count=0
                else
                    log "INFO" "Skipping restart (cooldown: ${time_since_restart}s/${RESTART_COOLDOWN}s)"
                fi
            fi
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# Get current status
get_status() {
    if [[ -f "$STATUS_FILE" ]]; then
        cat "$STATUS_FILE"
    else
        echo '{"error": "No status available"}'
    fi
}

# Send notification to systemd
notify_systemd() {
    local status="$1"
    local message="$2"
    
    if command -v systemd-notify >/dev/null 2>&1; then
        systemd-notify --status="$message"
        case "$status" in
            "ready")
                systemd-notify --ready
                ;;
            "stopping")
                systemd-notify --stopping
                ;;
        esac
    fi
}

# Main function
main() {
    local command="${1:-monitor}"
    
    case "$command" in
        "monitor")
            acquire_lock
            notify_systemd "ready" "Service monitor started"
            monitor_loop
            ;;
        "check")
            check_system_health
            ;;
        "status")
            get_status
            ;;
        "restart-unhealthy")
            restart_unhealthy_services
            ;;
        "help"|"--help")
            echo "Usage: $0 [monitor|check|status|restart-unhealthy|help]"
            echo "  monitor          - Start continuous monitoring (default)"
            echo "  check            - Perform single health check"
            echo "  status           - Show current status"
            echo "  restart-unhealthy - Restart unhealthy services"
            echo "  help             - Show this help"
            ;;
        *)
            echo "Unknown command: $command" >&2
            exit 1
            ;;
    esac
}

# Run main function
main "$@"