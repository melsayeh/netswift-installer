#!/usr/bin/env bash
#
# NetSwift 2.0 Installer
# Description: Automated deployment for NetSwift network management system
# Author: Mansour El Sayeh
# Version: 2.0.0
#

#═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
#═══════════════════════════════════════════════════════════════════════════

readonly SCRIPT_VERSION="2.0.0"
readonly INSTALL_DIR="/opt/netswift"
readonly BASE_URL="https://raw.githubusercontent.com/melsayeh/netswift-installer/refs/heads/main"
readonly LOG_FILE="/var/log/netswift-install.log"
readonly MIN_RAM_GB=4
readonly MIN_DISK_GB=10

# Docker image details
readonly DOCKER_IMAGE="melsayeh/netswift-backend"
readonly DOCKER_TAG="2.0.0"

#═══════════════════════════════════════════════════════════════════════════
# COLORS & FORMATTING
#═══════════════════════════════════════════════════════════════════════════

if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly MAGENTA='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly MAGENTA=''
    readonly CYAN=''
    readonly BOLD=''
    readonly NC=''
fi

#═══════════════════════════════════════════════════════════════════════════
# LOGGING FUNCTIONS
#═══════════════════════════════════════════════════════════════════════════

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${message}"
    echo "[${timestamp}] [${level}] ${message}" | sed 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}"
}

log_info() {
    log "INFO" "${BLUE}ℹ${NC} $*"
}

log_success() {
    log "SUCCESS" "${GREEN}✓${NC} $*"
}

log_warning() {
    log "WARNING" "${YELLOW}⚠${NC} $*"
}

log_error() {
    log "ERROR" "${RED}✗${NC} $*"
}

log_step() {
    log "STEP" "\n${CYAN}${BOLD}[$1]${NC} $2"
}

#═══════════════════════════════════════════════════════════════════════════
# ERROR HANDLING
#═══════════════════════════════════════════════════════════════════════════

cleanup() {
    local exit_code=$?
    
    if [[ ${exit_code} -ne 0 ]]; then
        log_error "Installation failed with exit code: ${exit_code}"
        log_info "Check log file: ${LOG_FILE}"
        
        if [[ -d "${INSTALL_DIR}" ]]; then
            log_warning "Attempting rollback..."
            cd "${INSTALL_DIR}" 2>/dev/null && docker-compose down 2>&1 | tee -a "${LOG_FILE}" || true
        fi
    fi
}

trap cleanup EXIT

handle_error() {
    local line_num="$1"
    local exit_code="$2"
    log_error "Error on line ${line_num} (exit code: ${exit_code})"
    exit "${exit_code}"
}

trap 'handle_error ${LINENO} $?' ERR

#═══════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
#═══════════════════════════════════════════════════════════════════════════

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "${default}" == "y" ]]; then
        prompt="${prompt} [Y/n]: "
    else
        prompt="${prompt} [y/N]: "
    fi
    
    read -p "$(echo -e ${prompt})" -n 1 -r
    echo
    
    if [[ "${default}" == "y" ]]; then
        [[ ! $REPLY =~ ^[Nn]$ ]]
    else
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

get_server_ip() {
    # Try multiple methods to get IP
    local ip
    
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    
    if [[ -z "${ip}" ]]; then
        ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    fi
    
    if [[ -z "${ip}" ]]; then
        ip="localhost"
    fi
    
    echo "${ip}"
}

#═══════════════════════════════════════════════════════════════════════════
# VALIDATION FUNCTIONS
#═══════════════════════════════════════════════════════════════════════════

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root"
        log_info "Please run: sudo bash $0"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/redhat-release ]]; then
        log_error "This installer supports Red Hat/CentOS/Rocky Linux only"
        log_info "Detected OS: $(uname -s)"
        exit 1
    fi
    
    local os_version
    os_version=$(cat /etc/redhat-release)
    log_success "Detected: ${os_version}"
}

check_system_resources() {
    local total_mem_gb
    local disk_space_gb
    local warnings=0
    
    # Check RAM
    total_mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    log_info "Available RAM: ${total_mem_gb}GB"
    
    if [[ ${total_mem_gb} -lt ${MIN_RAM_GB} ]]; then
        log_warning "RAM below recommended minimum (${MIN_RAM_GB}GB)"
        ((warnings++))
    fi
    
    # Check disk space
    disk_space_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    log_info "Available disk space: ${disk_space_gb}GB"
    
    if [[ ${disk_space_gb} -lt ${MIN_DISK_GB} ]]; then
        log_error "Insufficient disk space (minimum ${MIN_DISK_GB}GB required)"
        exit 1
    fi
    
    if [[ ${warnings} -gt 0 ]]; then
        if ! confirm "System does not meet recommended requirements. Continue anyway?"; then
            log_info "Installation cancelled by user"
            exit 0
        fi
    fi
    
    log_success "System resources adequate"
}

check_network() {
    log_info "Checking network connectivity..."
    
    if ! curl -s --connect-timeout 5 https://raw.githubusercontent.com >/dev/null 2>&1; then
        log_error "Cannot reach GitHub. Check your internet connection"
        exit 1
    fi
    
    if ! curl -s --connect-timeout 5 https://hub.docker.com >/dev/null 2>&1; then
        log_warning "Cannot reach Docker Hub. Installation may fail"
    fi
    
    log_success "Network connectivity OK"
}

#═══════════════════════════════════════════════════════════════════════════
# INSTALLATION FUNCTIONS
#═══════════════════════════════════════════════════════════════════════════

install_docker() {
    if command_exists docker; then
        local docker_version
        docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        log_success "Docker already installed (version ${docker_version})"
        
        # Ensure Docker is running
        if ! systemctl is-active --quiet docker; then
            log_info "Starting Docker service..."
            systemctl start docker
            systemctl enable docker
        fi
        return 0
    fi
    
    log_info "Installing Docker..."
    
    # Install prerequisites
    yum install -y yum-utils &>> "${LOG_FILE}" || {
        log_error "Failed to install yum-utils"
        return 1
    }
    
    # Add Docker repository
    yum-config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo &>> "${LOG_FILE}" || {
        log_error "Failed to add Docker repository"
        return 1
    }
    
    # Install Docker
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin &>> "${LOG_FILE}" || {
        log_error "Failed to install Docker"
        return 1
    }
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
    
    log_success "Docker installed successfully"
}

install_docker_compose() {
    if command_exists docker-compose; then
        local compose_version
        compose_version=$(docker-compose --version | cut -d' ' -f4 | tr -d ',')
        log_success "Docker Compose already installed (version ${compose_version})"
        return 0
    fi
    
    log_info "Installing Docker Compose..."
    
    # Get latest version
    local compose_version
    compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
    
    if [[ -z "${compose_version}" ]]; then
        log_error "Failed to determine latest Docker Compose version"
        return 1
    fi
    
    # Download and install
    curl -L "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose 2>> "${LOG_FILE}" || {
        log_error "Failed to download Docker Compose"
        return 1
    }
    
    chmod +x /usr/local/bin/docker-compose
    
    log_success "Docker Compose installed (${compose_version})"
}

setup_installation_directory() {
    log_info "Setting up installation directory: ${INSTALL_DIR}"
    
    if [[ -d "${INSTALL_DIR}" ]]; then
        local backup_dir="${INSTALL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        log_warning "Existing installation found"
        
        if confirm "Backup existing installation to ${backup_dir}?" "y"; then
            mv "${INSTALL_DIR}" "${backup_dir}"
            log_success "Backup created: ${backup_dir}"
        else
            if confirm "Remove existing installation?" "n"; then
                rm -rf "${INSTALL_DIR}"
                log_warning "Existing installation removed"
            else
                log_error "Cannot proceed with existing installation"
                exit 1
            fi
        fi
    fi
    
    mkdir -p "${INSTALL_DIR}"/{data,logs}
    cd "${INSTALL_DIR}" || exit 1
    
    log_success "Installation directory ready"
}

download_config_files() {
    log_info "Downloading configuration files..."
    
    local files=(
        "docker-compose.yml"
        "netswift.json"
    )
    
    for file in "${files[@]}"; do
        local url="${BASE_URL}/${file}"
        log_info "Downloading ${file}..."
        
        if ! curl -f -sS "${url}" -o "${file}" 2>> "${LOG_FILE}"; then
            log_error "Failed to download ${file} from ${url}"
            return 1
        fi
        
        log_success "Downloaded ${file}"
    done
}

docker_hub_login() {
    log_info "Docker Hub authentication required for private image"
    echo
    
    local max_attempts=3
    local attempt=1
    
    while [[ ${attempt} -le ${max_attempts} ]]; do
        read -p "Docker Hub Username: " docker_user
        read -sp "Docker Hub Password/Token: " docker_pass
        echo
        
        if [[ -z "${docker_user}" ]] || [[ -z "${docker_pass}" ]]; then
            log_warning "Username and password cannot be empty"
            ((attempt++))
            continue
        fi
        
        log_info "Authenticating..."
        
        if echo "${docker_pass}" | docker login -u "${docker_user}" --password-stdin &>> "${LOG_FILE}"; then
            log_success "Docker Hub authentication successful"
            return 0
        else
            log_error "Authentication failed (attempt ${attempt}/${max_attempts})"
            ((attempt++))
            
            if [[ ${attempt} -le ${max_attempts} ]]; then
                echo
            fi
        fi
    done
    
    log_error "Failed to authenticate after ${max_attempts} attempts"
    return 1
}

configure_firewall() {
    if ! systemctl is-active --quiet firewalld; then
        log_warning "Firewall not active, skipping configuration"
        return 0
    fi
    
    log_info "Configuring firewall..."
    
    local ports=("80/tcp" "443/tcp" "8000/tcp")
    
    for port in "${ports[@]}"; do
        if firewall-cmd --permanent --add-port="${port}" &>> "${LOG_FILE}"; then
            log_success "Opened port ${port}"
        else
            log_warning "Failed to open port ${port}"
        fi
    done
    
    if firewall-cmd --reload &>> "${LOG_FILE}"; then
        log_success "Firewall configuration applied"
    else
        log_warning "Failed to reload firewall"
    fi
}

configure_selinux() {
    if ! command_exists getenforce; then
        log_info "SELinux not installed, skipping"
        return 0
    fi
    
    local selinux_status
    selinux_status=$(getenforce)
    
    if [[ "${selinux_status}" == "Disabled" ]]; then
        log_info "SELinux is disabled"
        return 0
    fi
    
    if [[ "${selinux_status}" == "Permissive" ]]; then
        log_success "SELinux already in permissive mode"
        return 0
    fi
    
    log_warning "SELinux is in enforcing mode"
    log_info "Docker requires permissive mode for volume mounts"
    
    if confirm "Set SELinux to permissive mode?" "y"; then
        setenforce 0
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>> "${LOG_FILE}"
        log_success "SELinux set to permissive mode"
    else
        log_warning "Continuing with SELinux enforcing (may cause issues)"
    fi
}

deploy_containers() {
    log_info "Pulling Docker images..."
    
    if ! docker-compose pull 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Failed to pull Docker images"
        return 1
    fi
    
    log_info "Starting containers..."
    
    if ! docker-compose up -d 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Failed to start containers"
        return 1
    fi
    
    log_success "Containers started"
}

wait_for_services() {
    log_info "Waiting for services to become healthy..."
    
    # Wait for backend
    log_info "Checking backend service..."
    local backend_ready=false
    
    for i in {1..30}; do
        if curl -f -s http://localhost:8000/health >/dev/null 2>&1; then
            log_success "Backend service is healthy"
            backend_ready=true
            break
        fi
        sleep 2
        echo -n "."
    done
    echo
    
    if [[ "${backend_ready}" == false ]]; then
        log_warning "Backend service did not become healthy"
        log_info "Checking logs..."
        docker-compose logs backend | tail -20 | tee -a "${LOG_FILE}"
    fi
    
    # Wait for Appsmith (takes longer)
    log_info "Waiting for Appsmith (this may take 1-2 minutes)..."
    local appsmith_ready=false
    
    for i in {1..60}; do
        if curl -f -s http://localhost/api/v1/health >/dev/null 2>&1; then
            log_success "Appsmith service is healthy"
            appsmith_ready=true
            break
        fi
        sleep 3
        [[ $((i % 5)) -eq 0 ]] && echo -n "."
    done
    echo
    
    if [[ "${appsmith_ready}" == false ]]; then
        log_warning "Appsmith service is taking longer than expected"
        log_info "It may still be initializing. Check with: ${INSTALL_DIR}/status.sh"
    fi
}

create_management_scripts() {
    log_info "Creating management scripts..."
    
    # Start script
    cat > "${INSTALL_DIR}/start.sh" << 'SCRIPT'
#!/bin/bash
cd /opt/netswift || exit 1
docker-compose up -d
echo "NetSwift started"
docker-compose ps
SCRIPT
    
    # Stop script
    cat > "${INSTALL_DIR}/stop.sh" << 'SCRIPT'
#!/bin/bash
cd /opt/netswift || exit 1
docker-compose down
echo "NetSwift stopped"
SCRIPT
    
    # Restart script
    cat > "${INSTALL_DIR}/restart.sh" << 'SCRIPT'
#!/bin/bash
cd /opt/netswift || exit 1
docker-compose restart
echo "NetSwift restarted"
docker-compose ps
SCRIPT
    
    # Logs script
    cat > "${INSTALL_DIR}/logs.sh" << 'SCRIPT'
#!/bin/bash
cd /opt/netswift || exit 1
if [[ -n "$1" ]]; then
    docker-compose logs -f "$1"
else
    docker-compose logs -f
fi
SCRIPT
    
    # Status script
    cat > "${INSTALL_DIR}/status.sh" << 'SCRIPT'
#!/bin/bash
cd /opt/netswift || exit 1
echo "=== Container Status ==="
docker-compose ps
echo ""
echo "=== Service Health ==="
echo -n "Backend: "
if curl -f -s http://localhost:8000/health >/dev/null 2>&1; then
    echo "✓ Healthy"
else
    echo "✗ Unhealthy"
fi
echo -n "Appsmith: "
if curl -f -s http://localhost/api/v1/health >/dev/null 2>&1; then
    echo "✓ Healthy"
else
    echo "✗ Unhealthy"
fi
SCRIPT
    
    # Update script
    cat > "${INSTALL_DIR}/update.sh" << 'SCRIPT'
#!/bin/bash
cd /opt/netswift || exit 1
echo "Pulling latest images..."
docker-compose pull
echo "Restarting services..."
docker-compose up -d
echo "Update complete"
docker-compose ps
SCRIPT
    
    # Backup script
    cat > "${INSTALL_DIR}/backup.sh" << 'SCRIPT'
#!/bin/bash
cd /opt/netswift || exit 1
BACKUP_DIR="/opt/netswift-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "${BACKUP_DIR}"
echo "Creating backup..."
tar -czf "${BACKUP_DIR}/netswift-backup-${TIMESTAMP}.tar.gz" \
    data/ logs/ docker-compose.yml netswift.json
echo "Backup created: ${BACKUP_DIR}/netswift-backup-${TIMESTAMP}.tar.gz"
SCRIPT
    
    # Uninstall script
    cat > "${INSTALL_DIR}/uninstall.sh" << 'SCRIPT'
#!/bin/bash
echo "This will completely remove NetSwift including all data"
read -p "Are you sure? (type 'yes' to confirm): " confirm
if [[ "${confirm}" != "yes" ]]; then
    echo "Uninstall cancelled"
    exit 0
fi
cd /opt/netswift || exit 1
echo "Stopping containers..."
docker-compose down -v
cd /
echo "Removing installation..."
rm -rf /opt/netswift
echo "NetSwift uninstalled"
SCRIPT
    
    chmod +x "${INSTALL_DIR}"/*.sh
    
    log_success "Management scripts created"
}

print_summary() {
    local server_ip
    server_ip=$(get_server_ip)
    
    echo
    echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║                  Installation Complete!                          ║${NC}"
    echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${CYAN}${BOLD}Access URLs:${NC}"
    echo -e "  Backend API:  ${BLUE}http://${server_ip}:8000${NC}"
    echo -e "  Frontend:     ${BLUE}http://${server_ip}${NC}"
    echo
    echo -e "${CYAN}${BOLD}Installation Directory:${NC}"
    echo -e "  ${INSTALL_DIR}"
    echo
    echo -e "${CYAN}${BOLD}Management Commands:${NC}"
    echo -e "  Start:     ${INSTALL_DIR}/start.sh"
    echo -e "  Stop:      ${INSTALL_DIR}/stop.sh"
    echo -e "  Restart:   ${INSTALL_DIR}/restart.sh"
    echo -e "  Status:    ${INSTALL_DIR}/status.sh"
    echo -e "  Logs:      ${INSTALL_DIR}/logs.sh [service]"
    echo -e "  Update:    ${INSTALL_DIR}/update.sh"
    echo -e "  Backup:    ${INSTALL_DIR}/backup.sh"
    echo -e "  Uninstall: ${INSTALL_DIR}/uninstall.sh"
    echo
    echo -e "${CYAN}${BOLD}Next Steps:${NC}"
    echo -e "  ${YELLOW}1.${NC} Access Appsmith: ${BLUE}http://${server_ip}${NC}"
    echo -e "  ${YELLOW}2.${NC} Create admin account (first time only)"
    echo -e "  ${YELLOW}3.${NC} Import application:"
    echo -e "     • Click 'Create New' → 'Import'"
    echo -e "     • Select: ${INSTALL_DIR}/netswift.json"
    echo -e "  ${YELLOW}4.${NC} Configure backend URL: ${BLUE}http://${server_ip}:8000${NC}"
    echo
    echo -e "${CYAN}${BOLD}Support:${NC}"
    echo -e "  Log file:  ${LOG_FILE}"
    echo -e "  Docs:      https://github.com/melsayeh/netswift-installer"
    echo
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
    echo
}

#═══════════════════════════════════════════════════════════════════════════
# MAIN INSTALLATION FLOW
#═══════════════════════════════════════════════════════════════════════════

main() {
    # Ensure we fail on any error from here on
    set -euo pipefail
    
    # Clear screen and show banner
    clear
    echo -e "${BLUE}${BOLD}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║                    NetSwift 2.0 Installer                         ║
║            Network Management System for AOS-CX Switches          ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    log_info "Version: ${SCRIPT_VERSION}"
    log_info "Log file: ${LOG_FILE}"
    echo
    
    # Pre-flight checks
    log_step "1/11" "Pre-flight checks"
    check_root
    check_os
    check_system_resources
    check_network
    
    # Install Docker
    log_step "2/11" "Installing Docker"
    install_docker
    
    # Install Docker Compose
    log_step "3/11" "Installing Docker Compose"
    install_docker_compose
    
    # Setup directories
    log_step "4/11" "Setting up installation directory"
    setup_installation_directory
    
    # Download configuration
    log_step "5/11" "Downloading configuration files"
    download_config_files
    
    # Docker Hub authentication
    log_step "6/11" "Docker Hub authentication"
    docker_hub_login
    
    # Configure firewall
    log_step "7/11" "Configuring firewall"
    configure_firewall
    
    # Configure SELinux
    log_step "8/11" "Configuring SELinux"
    configure_selinux
    
    # Deploy containers
    log_step "9/11" "Deploying containers"
    deploy_containers
    
    # Wait for services
    log_step "10/11" "Waiting for services"
    wait_for_services
    
    # Create management scripts
    log_step "11/11" "Creating management scripts"
    create_management_scripts
    
    # Print summary
    print_summary
    
    log_success "Installation completed successfully!"
    
    return 0
}

# Run main installation
main "$@"
