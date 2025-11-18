cat > redhat-94-install.sh << 'EOF'
#!/bin/bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/opt/netswift"
BASE_URL="https://raw.githubusercontent.com/melsayeh/netswift-installer/refs/heads/main/redhat-94-install.sh"
LOG_FILE="/tmp/netswift-install.log"

log() {
    echo -e "$1" | tee -a ${LOG_FILE}
}

handle_error() {
    log "${RED}Error on line $1${NC}"
    log "${YELLOW}Check logs at: ${LOG_FILE}${NC}"
    log "${YELLOW}Rolling back...${NC}"
    cd ${INSTALL_DIR} 2>/dev/null && docker-compose down 2>&1 | tee -a ${LOG_FILE}
    exit 1
}

trap 'handle_error $LINENO' ERR

clear
log "${BLUE}================================================================${NC}"
log "${BLUE}           NetSwift 2.0 - Automated Installer${NC}"
log "${BLUE}================================================================${NC}"
log ""

# Check root
if [ "$EUID" -ne 0 ]; then 
    log "${RED}Please run as root (use sudo)${NC}"
    exit 1
fi

# Detect OS
log "${YELLOW}[1/10] Detecting operating system...${NC}"
if [ -f /etc/redhat-release ]; then
    OS_VERSION=$(cat /etc/redhat-release)
    log "${GREEN}✓ Detected: ${OS_VERSION}${NC}"
else
    log "${RED}✗ This installer is for Red Hat/CentOS only${NC}"
    exit 1
fi

# Check system requirements
log "${YELLOW}[2/10] Checking system requirements...${NC}"
TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
DISK_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')

log "  Memory: ${TOTAL_MEM}GB"
log "  Disk Space: ${DISK_SPACE}GB available"

if [ "$TOTAL_MEM" -lt 4 ]; then
    log "${YELLOW}⚠ Warning: Less than 4GB RAM detected.${NC}"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

log "${GREEN}✓ System requirements met${NC}"

# Install Docker
log "${YELLOW}[3/10] Installing Docker...${NC}"
if ! command -v docker &> /dev/null; then
    yum install -y yum-utils 2>&1 | tee -a ${LOG_FILE}
    yum-config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>&1 | tee -a ${LOG_FILE}
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>&1 | tee -a ${LOG_FILE}
    systemctl start docker
    systemctl enable docker
    log "${GREEN}✓ Docker installed${NC}"
else
    log "${GREEN}✓ Docker already installed${NC}"
fi

# Install Docker Compose
log "${YELLOW}[4/10] Installing Docker Compose...${NC}"
if ! command -v docker-compose &> /dev/null; then
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
    curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose 2>&1 | tee -a ${LOG_FILE}
    chmod +x /usr/local/bin/docker-compose
    log "${GREEN}✓ Docker Compose installed${NC}"
else
    log "${GREEN}✓ Docker Compose already installed${NC}"
fi

# Create installation directory
log "${YELLOW}[5/10] Creating installation directory...${NC}"
if [ -d "${INSTALL_DIR}" ]; then
    log "${YELLOW}⚠ Backing up existing installation...${NC}"
    mv ${INSTALL_DIR} ${INSTALL_DIR}.backup.$(date +%Y%m%d_%H%M%S)
fi
mkdir -p ${INSTALL_DIR}
cd ${INSTALL_DIR}
log "${GREEN}✓ Directory created: ${INSTALL_DIR}${NC}"

# Download files
log "${YELLOW}[6/10] Downloading NetSwift files...${NC}"
curl -f -s ${BASE_URL}/docker-compose.yml -o docker-compose.yml 2>&1 | tee -a ${LOG_FILE}
curl -f -s ${BASE_URL}/netswift.json -o netswift.json 2>&1 | tee -a ${LOG_FILE}

mkdir -p data logs
log "${GREEN}✓ Files downloaded${NC}"

# Docker Hub login
log "${YELLOW}[7/10] Docker Hub authentication...${NC}"
log "${BLUE}Enter Docker Hub credentials to access private NetSwift image:${NC}"
read -p "Username: " DOCKER_USER
read -sp "Password/Token: " DOCKER_PASS
echo ""

echo ${DOCKER_PASS} | docker login -u ${DOCKER_USER} --password-stdin 2>&1 | tee -a ${LOG_FILE}
if [ $? -eq 0 ]; then
    log "${GREEN}✓ Authenticated${NC}"
else
    log "${RED}✗ Authentication failed${NC}"
    exit 1
fi

# Configure firewall
log "${YELLOW}[8/10] Configuring firewall...${NC}"
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=80/tcp 2>&1 | tee -a ${LOG_FILE}
    firewall-cmd --permanent --add-port=443/tcp 2>&1 | tee -a ${LOG_FILE}
    firewall-cmd --permanent --add-port=8000/tcp 2>&1 | tee -a ${LOG_FILE}
    firewall-cmd --reload 2>&1 | tee -a ${LOG_FILE}
    log "${GREEN}✓ Firewall configured${NC}"
else
    log "${YELLOW}⚠ Firewall not active${NC}"
fi

# SELinux
log "${YELLOW}[9/10] Configuring SELinux...${NC}"
if command -v getenforce &> /dev/null; then
    if [ "$(getenforce)" == "Enforcing" ]; then
        log "${YELLOW}⚠ Setting SELinux to permissive...${NC}"
        setenforce 0
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        log "${GREEN}✓ SELinux configured${NC}"
    else
        log "${GREEN}✓ SELinux already permissive${NC}"
    fi
fi

# Deploy
log "${YELLOW}[10/10] Deploying NetSwift...${NC}"
docker-compose pull 2>&1 | tee -a ${LOG_FILE}
docker-compose up -d 2>&1 | tee -a ${LOG_FILE}

# Wait and health check
log "${YELLOW}Waiting for services...${NC}"
sleep 20

for i in {1..10}; do
    if curl -f -s http://localhost:8000/health > /dev/null 2>&1; then
        log "${GREEN}✓ Backend is healthy${NC}"
        break
    fi
    sleep 3
done

log "${YELLOW}Waiting for Appsmith (1-2 minutes)...${NC}"
for i in {1..40}; do
    if curl -f -s http://localhost/api/v1/health > /dev/null 2>&1; then
        log "${GREEN}✓ Appsmith is healthy${NC}"
        break
    fi
    sleep 3
    echo -n "."
done
echo ""

# Create management scripts
cat > ${INSTALL_DIR}/start.sh << 'SCRIPT'
#!/bin/bash
cd /opt/netswift
docker-compose up -d
echo "NetSwift started"
SCRIPT

cat > ${INSTALL_DIR}/stop.sh << 'SCRIPT'
#!/bin/bash
cd /opt/netswift
docker-compose down
echo "NetSwift stopped"
SCRIPT

cat > ${INSTALL_DIR}/restart.sh << 'SCRIPT'
#!/bin/bash
cd /opt/netswift
docker-compose restart
echo "NetSwift restarted"
SCRIPT

cat > ${INSTALL_DIR}/logs.sh << 'SCRIPT'
#!/bin/bash
cd /opt/netswift
docker-compose logs -f
SCRIPT

cat > ${INSTALL_DIR}/status.sh << 'SCRIPT'
#!/bin/bash
cd /opt/netswift
docker-compose ps
SCRIPT

cat > ${INSTALL_DIR}/update.sh << 'SCRIPT'
#!/bin/bash
cd /opt/netswift
echo "Pulling latest images..."
docker-compose pull
echo "Restarting services..."
docker-compose up -d
echo "Update complete"
SCRIPT

cat > ${INSTALL_DIR}/uninstall.sh << 'SCRIPT'
#!/bin/bash
cd /opt/netswift
docker-compose down -v
cd /
rm -rf /opt/netswift
echo "NetSwift uninstalled"
SCRIPT

chmod +x ${INSTALL_DIR}/*.sh

SERVER_IP=$(hostname -I | awk '{print $1}')

log ""
log "${GREEN}================================================================${NC}"
log "${GREEN}          Installation Complete!${NC}"
log "${GREEN}================================================================${NC}"
log ""
log "${BLUE}Access URLs:${NC}"
log "  Backend:  http://${SERVER_IP}:8000"
log "  Frontend: http://${SERVER_IP}"
log ""
log "${BLUE}Management:${NC}"
log "  Start:     ${INSTALL_DIR}/start.sh"
log "  Stop:      ${INSTALL_DIR}/stop.sh"
log "  Restart:   ${INSTALL_DIR}/restart.sh"
log "  Logs:      ${INSTALL_DIR}/logs.sh"
log "  Status:    ${INSTALL_DIR}/status.sh"
log "  Update:    ${INSTALL_DIR}/update.sh"
log "  Uninstall: ${INSTALL_DIR}/uninstall.sh"
log ""
log "${YELLOW}Next Steps:${NC}"
log "  1. Access: http://${SERVER_IP}"
log "  2. Create Appsmith admin account"
log "  3. Import application:"
log "     - Click 'Create New' → 'Import'"
log "     - Select: ${INSTALL_DIR}/netswift.json"
log "  4. Configure backend URL in Appsmith to: http://${SERVER_IP}:8000"
log ""
log "${GREEN}================================================================${NC}"
EOF

chmod +x redhat-94-install.sh
