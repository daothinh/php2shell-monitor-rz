#!/usr/bin/env bash
##############################################################################
# PHP2SHELL MONITOR - Installation Script
# 
# Deploys monitor and simulator to production locations
#
# Author: php2shell-monitor project
# Version: 1.0
##############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/php2shell}"
MONITOR_USER="${MONITOR_USER:-root}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

check_requirements() {
    log_info "Checking requirements..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ] && [ -z "${SKIP_ROOT_CHECK}" ]; then
        log_error "Please run as root or with sudo"
    fi
    
    # Check bash version
    if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        log_error "Bash 4.0+ required (current: ${BASH_VERSION})"
    fi
    
    # Check required commands
    for cmd in curl grep find jq; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
        fi
    done
    
    log_success "Requirements check passed"
}

install_monitor() {
    log_info "Installing monitor engine..."
    
    # Create directories
    mkdir -p "${INSTALL_ROOT}"/{monitor,engine,plugins,rules}
    mkdir -p /var/lib/php2shell/{state,logs}
    mkdir -p /var/log/php2shell-monitor
    
    # Install monitor
    install -m 755 "${SCRIPT_DIR}/monitor/monitor.sh" "${INSTALL_ROOT}/monitor/monitor.sh"
    
    # Create convenience symlink
    ln -sf "${INSTALL_ROOT}/monitor/monitor.sh" "${INSTALL_ROOT}/monitor_prod.sh"
    
    log_success "Monitor installed to ${INSTALL_ROOT}"
}

install_simulator() {
    log_info "Installing attack simulator..."
    
    mkdir -p /tmp/php2shell-attack
    
    install -m 755 "${SCRIPT_DIR}/simulator/attacker.sh" /tmp/php2shell-attack/attacker.sh
    install -m 755 "${SCRIPT_DIR}/simulator/orchestrator.sh" /tmp/php2shell-attack/orchestrator.sh
    
    log_success "Simulator installed to /tmp/php2shell-attack/"
}

install_docker() {
    log_info "Installing Docker lab files..."
    
    local docker_dir="/home/gaban/Downloads/php2shell-monitor/docker-lab/detector"
    mkdir -p "$docker_dir"
    
    cp "${SCRIPT_DIR}/docker/Dockerfile" "$docker_dir/"
    cp "${SCRIPT_DIR}/docker/docker-compose.yml" "$docker_dir/"
    
    log_success "Docker lab installed to $docker_dir"
}

create_systemd_service() {
    log_info "Creating systemd service..."
    
    cat > /etc/systemd/system/php2shell-monitor.service <<EOF
[Unit]
Description=PHP2Shell Monitor - CVE-2026-109618/109619 Detection
After=network.target

[Service]
Type=simple
Environment="LOGS_DIR=/var/log/nginx:/var/log/php-fpm"
Environment="OUTPUT_DIR=/var/log/php2shell-monitor"
Environment="MONITOR_INTERVAL=60"
ExecStart=${INSTALL_ROOT}/monitor/monitor.sh
Restart=on-failure
RestartSec=10s
User=${MONITOR_USER}

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/log/php2shell-monitor /var/lib/php2shell

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    log_success "Systemd service created"
    log_info "Enable with: systemctl enable php2shell-monitor"
    log_info "Start with:  systemctl start php2shell-monitor"
}

show_usage() {
    cat <<EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║                   PHP2SHELL MONITOR - Installation Complete                 ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

Installation Summary:
─────────────────────────────────────────────────────────────────────────────

Monitor Engine:        ${INSTALL_ROOT}/monitor/monitor.sh
Simulator:             /tmp/php2shell-attack/attacker.sh
Orchestrator:          /tmp/php2shell-attack/orchestrator.sh
Docker Lab:            /home/gaban/Downloads/php2shell-monitor/docker-lab/detector/
Systemd Service:       /etc/systemd/system/php2shell-monitor.service

Quick Start:
─────────────────────────────────────────────────────────────────────────────

1. Start Docker target:
   cd /home/gaban/Downloads/php2shell-monitor/docker-lab/detector
   docker compose up -d

2. Run orchestrated test (60s):
   /tmp/php2shell-attack/orchestrator.sh http://localhost:8082 60 2 3

3. View detections:
   tail -f /tmp/php2shell-monitor-output/alerts.jsonl | jq '.'

Production Deployment:
─────────────────────────────────────────────────────────────────────────────

1. Enable systemd service:
   systemctl enable php2shell-monitor
   systemctl start php2shell-monitor

2. Check status:
   systemctl status php2shell-monitor
   journalctl -u php2shell-monitor -f

Configuration:
─────────────────────────────────────────────────────────────────────────────

Edit /etc/systemd/system/php2shell-monitor.service to customize:
  - LOGS_DIR:          Log directories to monitor (colon-separated)
  - OUTPUT_DIR:        Alert output directory
  - MONITOR_INTERVAL:  Scan frequency in seconds

Documentation:
─────────────────────────────────────────────────────────────────────────────

README:              /home/gaban/Downloads/php2shell-monitor/README.md
Deployment Guide:    /home/gaban/Downloads/php2shell-monitor/ENVIRONMENT_SETUP_COMPLETE.md
Architecture:        /home/gaban/Downloads/php2shell-monitor/ARCHITECTURE.md

════════════════════════════════════════════════════════════════════════════════
EOF
}

main() {
    echo ""
    echo "PHP2Shell Monitor - Installation Script"
    echo "========================================"
    echo ""
    
    check_requirements
    install_monitor
    install_simulator
    install_docker
    
    if [ -d "/etc/systemd/system" ] && [ -z "${SKIP_SYSTEMD}" ]; then
        create_systemd_service
    else
        log_info "Skipping systemd service creation"
    fi
    
    show_usage
}

main "$@"
