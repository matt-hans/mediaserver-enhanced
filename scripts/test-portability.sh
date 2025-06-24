#\!/bin/bash
# Media Server Portability Test Suite
# Agent 3 Implementation

set -euo pipefail

LOG_FILE="/tmp/portability-test.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [PORTABILITY-TEST] $1" | tee -a "$LOG_FILE"
}

test_result() {
    local test_name="$1"
    local result="$2"
    
    if [[ "$result" == "PASS" ]]; then
        log "✅ $test_name: PASS"
        return 0
    else
        log "❌ $test_name: FAIL"
        return 1
    fi
}

# Test VPN connection
test_vpn_connection() {
    if docker exec wireguard curl -s https://ipinfo.io | grep -q '"org"'; then
        echo "PASS"
    else
        echo "FAIL"
    fi
}

# Test service accessibility
test_service_access() {
    local service="$1"
    local port="$2"
    local path="$3"
    
    if timeout 10 curl -sf "http://localhost:$port$path" &>/dev/null; then
        echo "PASS"
    else
        echo "FAIL"
    fi
}

# Test DNS resolution
test_dns_resolution() {
    if docker exec wireguard nslookup google.com &>/dev/null; then
        echo "PASS"
    else
        echo "FAIL"
    fi
}

# Test container health
test_container_health() {
    local container="$1"
    local status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
    
    if [[ "$status" == "healthy" ]]; then
        echo "PASS"
    else
        echo "FAIL"
    fi
}

# Main test suite
main() {
    log "=== Media Server Portability Test Suite ==="
    
    local total_tests=0
    local passed_tests=0
    
    # Test 1: VPN Connection
    ((total_tests++))
    if test_result "VPN Connection" "$(test_vpn_connection)"; then
        ((passed_tests++))
    fi
    
    # Test 2: Jellyfin Access
    ((total_tests++))
    if test_result "Jellyfin Access" "$(test_service_access jellyfin 8096 /health)"; then
        ((passed_tests++))
    fi
    
    # Test 3: Jackett Access
    ((total_tests++))
    if test_result "Jackett Access" "$(test_service_access jackett 9117 "")"; then
        ((passed_tests++))
    fi
    
    # Test 4: Transmission Access
    ((total_tests++))
    if test_result "Transmission Access" "$(test_service_access transmission 9091 /transmission/web/)"; then
        ((passed_tests++))
    fi
    
    # Test 5: DNS Resolution
    ((total_tests++))
    if test_result "DNS Resolution" "$(test_dns_resolution)"; then
        ((passed_tests++))
    fi
    
    # Test 6: Container Health
    for container in wireguard jellyfin; do
        ((total_tests++))
        if test_result "$container Health" "$(test_container_health $container)"; then
            ((passed_tests++))
        fi
    done
    
    # Results Summary
    log "=== Test Results Summary ==="
    log "Passed: $passed_tests/$total_tests"
    log "Success Rate: $(( passed_tests * 100 / total_tests ))%"
    
    if [[ $passed_tests -eq $total_tests ]]; then
        log "🎉 All tests passed\! Media server is fully portable."
        return 0
    else
        log "⚠️  Some tests failed. System may have portability issues."
        return 1
    fi
}

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
