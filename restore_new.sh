#!/bin/bash

# ==========================================
# CapRover Restore + VPS Hardening (Final)
# ==========================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
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

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   error "Run as root (sudo -i)."
fi

clear
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}   CapRover Restore & Hardening (Safe Mode)   ${NC}"
echo -e "${GREEN}==============================================${NC}"

# ==========================================
# 1. Setup & Inputs
# ==========================================

# User Setup
read -rp "Enter name for new sudo user (default: myuser): " NEW_USER
NEW_USER=${NEW_USER:-myuser}

# SSH Key
echo -e "\n${YELLOW}--- SSH Setup ---${NC}"
echo -e "Paste your SSH PUBLIC KEY (starts with ssh-rsa / ssh-ed25519) and press ENTER:"
read -r SSH_KEY
if [[ -z "$SSH_KEY" ]]; then error "No SSH Key provided."; fi

# Restore Type
echo -e "\n${YELLOW}--- Restore Selection ---${NC}"
echo "1. CapRover backup only (no volumes)"
echo "2. CapRover + volumes backup"
echo "3. Fresh install (no backup)"
read -rp "Enter [1/2/3]: " BACKUP_TYPE
if [[ ! "$BACKUP_TYPE" =~ ^[123]$ ]]; then error "Invalid selection."; fi

USER_HOME="/home/$NEW_USER"

# ==========================================
# 2. System Prep (Update, User, SSH, FW)
# ==========================================

step "Updating System..."
apt-get update &>/dev/null & spinner $!
apt-get install -y ca-certificates curl nano htop npm ufw fail2ban sudo gnupg lsb-release &>/dev/null & spinner $!

step "Creating User & Hardening SSH..."
if ! id "$NEW_USER" &>/dev/null; then
    adduser --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
fi

mkdir -p "$USER_HOME/.ssh"
echo "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$NEW_USER":"$NEW_USER" "$USER_HOME/.ssh"

# SSH Config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Firewall
step "Configuring Firewall..."
ufw --force reset >/dev/null
ufw allow 22/tcp
ufw allow 80,443,3000,996,7946,4789,2377/tcp
ufw allow 7946,4789,2377/udp
ufw --force enable
systemctl enable --now fail2ban

# ==========================================
# 3. Docker Installation
# ==========================================

step "Preparing Docker..."
if command -v docker &> /dev/null; then
    systemctl stop docker 2>/dev/null || true
    systemctl stop docker.socket 2>/dev/null || true
    rm -f /var/lib/docker/network/files/local-kv.db
    systemctl start docker
    docker system prune -a -f
    docker network prune -f
else
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update &>/dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "$NEW_USER"

# ==========================================
# 4. Upload & Restore Logic
# ==========================================

mkdir -p /captain /captain-volumes

# Clean /captain/data to ensure backup.tar is detected cleanly
if [ "$BACKUP_TYPE" -ne 3 ]; then
    rm -rf /captain/data/*
fi

# --- 4a. Upload Backup.tar ---
if [ "$BACKUP_TYPE" -eq 1 ] || [ "$BACKUP_TYPE" -eq 2 ]; then
    step "Upload 'backup.tar'..."
    TARGET="$USER_HOME/backup.tar"
    echo -e "Use SCP to upload to: ${GREEN}$TARGET${NC}"
    
    while true; do
        if [ -f "$TARGET" ]; then
            echo -e "${BLUE}Verifying file...${NC}"
            if tar -tf "$TARGET" &>/dev/null; then
                 mv "$TARGET" /captain/
                 echo -e "${GREEN}backup.tar accepted.${NC}"
                 break
            else
                 echo -e "${RED}File incomplete. Re-upload.${NC}"
                 rm "$TARGET" 2>/dev/null
            fi
        fi
        sleep 2
    done
fi

# --- 4b. Upload & EXTRACT Volumes (BEFORE CapRover Starts) ---
if [ "$BACKUP_TYPE" -eq 2 ]; then
    step "Upload 'volumes-backup.tar.gz'..."
    TARGET="$USER_HOME/volumes-backup.tar.gz"
    echo -e "Use SCP to upload to: ${GREEN}$TARGET${NC}"
    
    while true; do
        if [ -f "$TARGET" ]; then
            echo -e "${BLUE}Verifying archive...${NC}"
            if tar -tzf "$TARGET" &>/dev/null; then
                 mv "$TARGET" /captain-volumes/
                 echo -e "${GREEN}Archive verified.${NC}"
                 break
            else
                 echo -e "${RED}File incomplete. Re-upload.${NC}"
                 rm "$TARGET" 2>/dev/null
            fi
        fi
        sleep 2
    done

    step "Restoring Volumes to /var/lib/docker/volumes..."
    # We extract NOW so data is ready when apps start
    tar -xzf /captain-volumes/volumes-backup.tar.gz -C /var/lib/docker/volumes
    echo -e "${GREEN}Volumes restored successfully!${NC}"
fi

# ==========================================
# 5. Start CapRover
# ==========================================

step "Installing CapRover CLI & Starting Server..."
npm install -g caprover &>/dev/null

# Clean old containers
docker rm -f $(docker ps -aq --filter "ancestor=caprover/caprover") 2>/dev/null || true
docker rm -f caprover 2>/dev/null || true

# Start CapRover
# It will see /captain/backup.tar and auto-initiate restore
docker run -d --name caprover \
  -p 80:80 -p 443:443 -p 3000:3000 \
  -e ACCEPTED_TERMS=true \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /captain:/captain \
  caprover/caprover

step "Waiting for CapRover to initialize..."
sleep 15

if docker ps | grep -q caprover; then
    echo -e "${GREEN}CapRover is running!${NC}"
else
    error "CapRover failed to start. Check 'docker logs caprover'."
fi

# ==========================================
# 6. Finish
# ==========================================

chown -R "$NEW_USER":"$NEW_USER" "$USER_HOME"

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}   RESTORE COMPLETE   ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "1. CapRover IP: http://$(curl -s ifconfig.me):3000"
echo -e "2. SSH User: ${YELLOW}$NEW_USER${NC}"
echo -e "3. Root Login: DISABLED"

if [ "$BACKUP_TYPE" -eq 2 ]; then
    echo -e "\n${GREEN}Volumes were restored BEFORE apps started.${NC}"
    echo -e "Your apps should pick up the data immediately."
    echo -e "${YELLOW}A reboot is recommended to ensure all network bridges reset clean.${NC}"
    read -r -p "Reboot now? [y/N] " CHOICE
    if [[ "$CHOICE" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        reboot
    fi
fi

exit 0
