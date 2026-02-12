#!/bin/bash

# ==========================================
# CapRover Restore + VPS Hardening Script
# ==========================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
SPIN='|/-\'

# --- Helper Functions ---

function spinner() {
    pid=$1
    i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${YELLOW}[%c]${NC} " "${SPIN:$i:1}"
        sleep .1
    done
    printf "\r"
}

step() {
    echo -e "\n${BLUE}==>${NC} ${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

error() {
    echo -e "${RED}$1${NC}"
    exit 1
}

wait_for_enter() {
    echo -e "${YELLOW}Press ENTER to continue...${NC}"
    read -r
}

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root. Please switch to root (sudo -i) and try again."
fi

clear
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}   CapRover Full Setup: Hardening + Restore   ${NC}"
echo -e "${GREEN}==============================================${NC}"

# ==========================================
# 1. Configuration & Inputs
# ==========================================

step "Configuration Setup"

# Get New Username
read -rp "Enter name for new sudo user (default: myuser): " NEW_USER
NEW_USER=${NEW_USER:-myuser}

# Get SSH Key (Crucial for automated hardening)
echo -e "\n${YELLOW}--- SSH Setup ---${NC}"
echo "To secure the server, we need your SSH Public Key (e.g., from id_rsa.pub)."
echo "If you don't have one, generate it locally with 'ssh-keygen' and copy the content."
echo -e "${YELLOW}Paste your SSH PUBLIC KEY below and press ENTER:${NC}"
read -r SSH_KEY

if [[ -z "$SSH_KEY" ]]; then
    error "No SSH Key provided. Aborting to prevent locking you out."
fi

# Get Backup Type
echo -e "\n${YELLOW}--- Restore Selection ---${NC}"
echo -e "1. CapRover backup only (no volumes)"
echo -e "2. CapRover + volumes backup"
echo -e "3. Fresh install (no backup)"
read -rp "Enter [1/2/3]: " BACKUP_TYPE

if [[ ! "$BACKUP_TYPE" =~ ^[123]$ ]]; then
    error "Invalid selection."
fi

USER_HOME="/home/$NEW_USER"

# ==========================================
# 2. System Update & Dependencies
# ==========================================
step "Updating system and installing dependencies..."
apt-get update &>/dev/null &
spinner $!
apt-get install -y ca-certificates curl nano htop npm ufw fail2ban sudo gnupg lsb-release &>/dev/null &
spinner $!

# ==========================================
# 3. User Creation & Hardening
# ==========================================
step "Creating user '$NEW_USER'..."

if id "$NEW_USER" &>/dev/null; then
    warn "User '$NEW_USER' already exists. Skipping creation."
else
    adduser --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    echo -e "${YELLOW}User '$NEW_USER' created.${NC}"
fi

step "Setting up SSH keys for '$NEW_USER'..."
mkdir -p "$USER_HOME/.ssh"
echo "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$NEW_USER":"$NEW_USER" "$USER_HOME/.ssh"

step "Hardening SSH (Disabling Root Login & Password Auth)..."
# Backup config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Update configurations using sed
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Restart SSH
systemctl restart sshd
echo -e "${GREEN}SSH Hardened. Root login disabled.${NC}"

step "Configuring Firewall (UFW)..."
# Reset UFW to be safe
ufw --force reset >/dev/null

# Allow SSH first!
ufw allow OpenSSH
ufw allow 22/tcp

# CapRover Ports
ufw allow 80,443,3000,996,7946,4789,2377/tcp
ufw allow 7946,4789,2377/udp

# Enable
ufw --force enable
echo -e "${GREEN}Firewall enabled and ports locked down.${NC}"

step "Enabling Fail2Ban..."
systemctl enable --now fail2ban

# ==========================================
# 4. Docker Installation / Prep
# ==========================================

# Fix: Check if Docker is running before trying to stop it
step "Checking Docker status..."
if command -v docker &> /dev/null; then
    echo "Docker found. Preparing for CapRover..."
    systemctl stop docker 2>/dev/null || true
    systemctl stop docker.socket 2>/dev/null || true
    # Remove old locks
    rm -f /var/lib/docker/network/files/local-kv.db
    
    step "Starting Docker..."
    systemctl start docker
    sleep 2
    
    step "Pruning Docker resources..."
    docker system prune -a -f
    docker network prune -f
else
    echo "Docker not found. Installing..."
    # Install Docker Official
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update &>/dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Add new user to docker group
usermod -aG docker "$NEW_USER"

# Check for port conflicts
step "Ensuring ports 80/443 are free..."
systemctl stop apache2 nginx 2>/dev/null || true
systemctl disable apache2 nginx 2>/dev/null || true

for port in 80 443; do
    if lsof -i :$port | grep LISTEN; then
        error "Port $port is still in use! Please check manually (sudo lsof -i :$port)."
    fi
done

# ==========================================
# 5. Restore Logic
# ==========================================

# Prepare CapRover directories
mkdir -p /captain /captain-volumes

if [ "$BACKUP_TYPE" -eq 1 ] || [ "$BACKUP_TYPE" -eq 2 ]; then
    step "Waiting for Backup File..."
    echo -e "${YELLOW}IMPORTANT:${NC} Upload 'backup.tar' to: ${GREEN}$USER_HOME/backup.tar${NC}"
    echo -e "You must use SCP/SFTP with user '${GREEN}$NEW_USER${NC}' and your SSH Key."
    echo -e "Example local command: ${BLUE}scp backup.tar $NEW_USER@<YOUR-IP>:~/backup.tar${NC}"
    
    while [ ! -f "$USER_HOME/backup.tar" ]; do
         wait_for_enter
         if [ -f "$USER_HOME/backup.tar" ]; then break; fi
         echo -e "${RED}File not found yet.${NC}"
    done
    
    mv "$USER_HOME/backup.tar" /captain/
    echo -e "${GREEN}backup.tar found and moved.${NC}"
fi

if [ "$BACKUP_TYPE" -eq 2 ]; then
    step "Waiting for Volumes Backup..."
    echo -e "${YELLOW}IMPORTANT:${NC} Upload 'volumes-backup.tar.gz' to: ${GREEN}$USER_HOME/volumes-backup.tar.gz${NC}"
    
    while [ ! -f "$USER_HOME/volumes-backup.tar.gz" ]; do
         wait_for_enter
         if [ -f "$USER_HOME/volumes-backup.tar.gz" ]; then break; fi
         echo -e "${RED}File not found yet.${NC}"
    done
    
    mv "$USER_HOME/volumes-backup.tar.gz" /captain-volumes/
    echo -e "${GREEN}volumes-backup.tar.gz found and moved.${NC}"
fi

# ==========================================
# 6. Install CapRover
# ==========================================

step "Installing CapRover CLI..."
npm install -g caprover &>/dev/null

step "Starting CapRover Server..."
# Remove old if exists
docker rm -f $(docker ps -aq --filter "ancestor=caprover/caprover") 2>/dev/null || true
docker rm -f caprover 2>/dev/null || true

CAPROVER_STARTED="no"
for i in {1..3}; do
    docker run -d --name caprover \
      -p 80:80 -p 443:443 -p 3000:3000 \
      -e ACCEPTED_TERMS=true \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /captain:/captain \
      caprover/caprover && CAPROVER_STARTED="yes" && break
    echo -e "${RED}Failed to start CapRover. Retrying ($i)...${NC}"
    sleep 3
done

if [ "$CAPROVER_STARTED" != "yes" ]; then
    error "Failed to start CapRover server. Check 'docker logs caprover'."
fi

# Wait for container startup
step "Waiting for CapRover to initialize (15s)..."
sleep 15

if ! docker ps | grep -q caprover; then
    error "CapRover container died. Check logs."
fi

echo -e "${GREEN}CapRover is running!${NC}"

# Restore Volumes if needed
if [ "$BACKUP_TYPE" -eq 2 ] && [ -f /captain-volumes/volumes-backup.tar.gz ]; then
    step "Restoring Volumes..."
    tar -xzf /captain-volumes/volumes-backup.tar.gz -C /var/lib/docker/volumes
    echo -e "${GREEN}Volumes extracted.${NC}"
fi

# ==========================================
# 7. Finalize
# ==========================================

step "Final Cleanup..."
# Fix permissions on home dir just in case
chown -R "$NEW_USER":"$NEW_USER" "$USER_HOME"

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}   Setup Complete!   ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "1. Access CapRover: http://$(curl -s ifconfig.me):3000"
echo -e "2. Your new SSH User: ${YELLOW}$NEW_USER${NC}"
echo -e "3. Root login is now ${RED}DISABLED${NC}."
echo -e "4. Use: ${BLUE}ssh $NEW_USER@$(curl -s ifconfig.me)${NC}"

if [ "$BACKUP_TYPE" -eq 2 ]; then
    echo -e "\n${YELLOW}Since volumes were restored, a reboot is highly recommended.${NC}"
    read -r -p "Reboot now? [y/N] " CHOICE
    if [[ "$CHOICE" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        step "Rebooting..."
        reboot
    fi
fi

exit 0
