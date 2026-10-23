#!/usr/bin/env bash
##############################################################################
# PHP2SHELL ORCHESTRATOR - Coordinated Attack + Detection Runner
# 
# Manages attack simulator and monitor in synchronized fashion
# Provides statistics and graceful shutdown
#
# Author: php2shell-monitor project
# Version: 1.0
##############################################################################

TARGET="${1:-http://localhost:8082}"
DURATION="${2:-300}"
ATTACK_INTERVAL="${3:-2}"
MONITOR_INTERVAL="${4:-3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/php2shell-monitor-output}"
ATTACK_LOG="${OUTPUT_DIR}/attack.log"
MONITOR_LOG="${OUTPUT_DIR}/monitor.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "${OUTPUT_DIR}"

log_orch() {
    echo -e "${BLUE}[ORCH]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERR]${NC} $1"
}

main() {
    log_orch "Starting PHP2Shell orchestration"
    log_orch "Target: ${TARGET}"
    log_orch "Duration: ${DURATION}s"
    log_orch "Attack interval: ${ATTACK_INTERVAL}s"
    log_orch "Monitor interval: ${MONITOR_INTERVAL}s"
    echo ""
    
    # Cleanup
    : > "${ATTACK_LOG}"
    : > "${MONITOR_LOG}"
    : > "${OUTPUT_DIR}/alerts.jsonl"
    
    # Start attack
    log_orch "Starting attack simulator..."
    "${SCRIPT_DIR}/attacker.sh" "${TARGET}" "${ATTACK_INTERVAL}" 0 \
        >> "${ATTACK_LOG}" 2>&1 &
    ATTACK_PID=$!
    log_success "Attack started (PID: ${ATTACK_PID})"
    
    # Start monitor
    log_orch "Starting monitor..."
    LOGS_DIR="/tmp/php2shell-docker-logs" \
    OUTPUT_DIR="${OUTPUT_DIR}" \
    MONITOR_INTERVAL="${MONITOR_INTERVAL}" \
    "${SCRIPT_DIR}/../monitor/monitor.sh" \
        >> "${MONITOR_LOG}" 2>&1 &
    MONITOR_PID=$!
    log_success "Monitor started (PID: ${MONITOR_PID})"
    
    echo ""
    log_orch "Running for ${DURATION} seconds..."
    echo ""
    
    local start_time=$(date +%s)
    local last_count=0
    
    # Monitor progress
    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        
        # Check processes
        if ! kill -0 ${ATTACK_PID} 2>/dev/null; then
            log_error "Attack died"
            kill -9 ${MONITOR_PID} 2>/dev/null
            return 1
        fi
        
        if ! kill -0 ${MONITOR_PID} 2>/dev/null; then
            log_error "Monitor died"
            kill -9 ${ATTACK_PID} 2>/dev/null
            return 1
        fi
        
        # Stats every 30s
        if [ $((elapsed % 30)) -eq 0 ] && [ ${elapsed} -gt 0 ]; then
            local alert_count=$(wc -l < "${OUTPUT_DIR}/alerts.jsonl" 2>/dev/null || echo 0)
            local new_alerts=$((alert_count - last_count))
            log_orch "Progress: ${elapsed}/${DURATION}s | Detections: ${alert_count} (+${new_alerts})"
            last_count=${alert_count}
        fi
        
        if [ ${elapsed} -ge ${DURATION} ]; then
            break
        fi
        
        sleep 5
    done
    
    # Shutdown
    log_orch "Stopping attack..."
    kill -TERM ${ATTACK_PID} 2>/dev/null
    sleep 2
    kill -9 ${ATTACK_PID} 2>/dev/null
    
    log_orch "Stopping monitor..."
    kill -TERM ${MONITOR_PID} 2>/dev/null
    sleep 2
    kill -9 ${MONITOR_PID} 2>/dev/null
    
    # Final stats
    echo ""
    log_success "Orchestration complete"
    local total_alerts=$(wc -l < "${OUTPUT_DIR}/alerts.jsonl" 2>/dev/null || echo 0)
    log_success "Total detections: ${total_alerts}"
    log_success "Alert file: ${OUTPUT_DIR}/alerts.jsonl"
}

trap 'log_error "Interrupted"; kill -9 ${ATTACK_PID} ${MONITOR_PID} 2>/dev/null; exit 1' SIGTERM SIGINT

main "$@"
