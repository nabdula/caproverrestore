#!/bin/bash

# ==========================================
# CapRover Restore + VPS Hardening (V4 - Robust)
# ==========================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
SPIN='|/-\'

# --- 1. IP Detection (Fixed) ---
# We prioritize internal IP detection to avoid "upstream connect errors"
SERVER_IP=$(hostname -I | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(ip route get 1 | awk '{print $7}' 2>/dev/null)
fi
# Final fallback
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="YOUR_VPS_IP"
fi

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

header() {
    echo -e "\n${YELLOW}--------------------------------------------------${NC}"
    echo -e "${YELLOW}   $1${NC}"
    echo -e "${YELLOW}--------------------------------------------------${NC}"
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
echo -e "${GREEN}   CapRover Restore & Hardening (V4)          ${NC}"
echo -e "${GREEN}==============================================${NC}"

# ==========================================
# 2. Setup & Inputs
# ==========================================

header "Configuration Setup"

# User Setup
read -rp "Enter name for new sudo user (default: myuser): " NEW_USER
NEW_USER=${NEW_USER:-myuser}

# SSH Key
header "SSH Setup"
echo -e "We need your Public Key to secure the server."
echo -e "${BLUE}Run these on your LOCAL machine if needed:${NC}"
echo -e "  1. Generate Key:  ${GREEN}ssh-keygen -t ed25519${NC}"
echo -e "  2. Copy Key:      ${GREEN}cat ~/.ssh/id_ed25519.pub | pbcopy${NC} (or id_rsa.pub)"
echo -e "\n${YELLOW}Paste your Public Key below and press ENTER:${NC}"
read -r SSH_KEY
if [[ -z "$SSH_KEY" ]]; then error "No SSH Key provided."; fi

# Restore Type
header "Restore Selection"
echo "1. CapRover backup only (no volumes)"
echo "2. CapRover + volumes backup"
echo "3. Fresh install (no backup)"
read -rp "Enter [1/2/3]: " BACKUP_TYPE
if [[ ! "$BACKUP_TYPE" =~ ^[123]$ ]]; then error "Invalid selection."; fi

USER_HOME="/home/$NEW_USER"

# ==========================================
# 3. System Prep
# ==========================================

step "Updating System & Installing Tools..."
# Added 'psmisc' to get the 'fuser' command for killing ports later
apt-get update &>/dev/null & spinner $!
apt-get install -y ca-certificates curl nano htop npm ufw fail2ban sudo gnupg lsb-release psmisc &>/dev/null & spinner $!

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
# 4. Docker Installation
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
# 5. Upload & Restore Logic
# ==========================================

mkdir -p /captain /captain-volumes
if [ "$BACKUP_TYPE" -ne 3 ]; then
    rm -rf /captain/data/*
fi

# --- 5a. Upload Backup.tar ---
if [ "$BACKUP_TYPE" -eq 1 ] || [ "$BACKUP_TYPE" -eq 2 ]; then
    header "ACTION REQUIRED: Upload Backup.tar"
    TARGET="$USER_HOME/backup.tar"
    
    echo -e "Copy this command and run it on your local machine:"
    echo -e "${GREEN}scp backup.tar $NEW_USER@$SERVER_IP:~/backup.tar${NC}"
    echo -e "\nMonitor below:"

    prev_size=-1
    while true; do
        if [ -f "$TARGET" ]; then
            curr_size=$(stat -c%s "$TARGET")
            readable_size=$(du -h "$TARGET" | cut -f1)
            
            if [ "$curr_size" -gt "$prev_size" ]; then
                echo -ne "\r${YELLOW}Uploading... (Size: $readable_size)${NC}      "
                prev_size=$curr_size
                sleep 2
            else
                echo -ne "\r${BLUE}Verifying Integrity... ($readable_size)${NC}      "
                if tar -tf "$TARGET" &>/dev/null; then
                     echo -e "\n${GREEN}Integrity Check: PASSED${NC}"
                     mv "$TARGET" /captain/
                     break
                else
                     echo -ne "\r${RED}Integrity Failed. File corrupted? Waiting for re-upload...${NC} "
                     sleep 3
                fi
            fi
        else
            echo -ne "\r${YELLOW}Waiting for file...${NC}      "
            sleep 2
        fi
    done
fi

# --- 5b. Upload & EXTRACT Volumes ---
if [ "$BACKUP_TYPE" -eq 2 ]; then
    header "ACTION REQUIRED: Upload Volumes Backup"
    TARGET="$USER_HOME/volumes-backup.tar.gz"

    echo -e "Copy this command and run it on your local machine:"
    echo -e "${GREEN}scp volumes-backup.tar.gz $NEW_USER@$SERVER_IP:~/volumes-backup.tar.gz${NC}"
    echo -e "\nMonitor below:"

    prev_size=-1
    while true; do
        if [ -f "$TARGET" ]; then
            curr_size=$(stat -c%s "$TARGET")
            readable_size=$(du -h "$TARGET" | cut -f1)
            
            if [ "$curr_size" -gt "$prev_size" ]; then
                echo -ne "\r${YELLOW}Uploading... (Size: $readable_size)${NC}      "
                prev_size=$curr_size
                sleep 2
            else
                echo -ne "\r${BLUE}Verifying Integrity... ($readable_size)${NC}      "
                if tar -tzf "$TARGET" &>/dev/null; then
                     echo -e "\n${GREEN}Integrity Check: PASSED${NC}"
                     mv "$TARGET" /captain-volumes/
                     break
                else
                     echo -ne "\r${RED}Integrity Failed. File corrupted? Waiting for re-upload...${NC} "
                     sleep 3
                fi
            fi
        else
            echo -ne "\r${YELLOW}Waiting for file...${NC}      "
            sleep 2
        fi
    done

    step "Restoring Volumes..."
    tar -xzf /captain-volumes/volumes-backup.tar.gz -C /var/lib/docker/volumes
    echo -e "${GREEN}Volumes restored successfully!${NC}"
fi

# ==========================================
# 6. Start CapRover
# ==========================================

step "Installing CapRover CLI..."
npm install -g caprover &>/dev/null

step "Ensuring Port 80/443 are FREE..."
# 1. Stop web servers
systemctl stop apache2 nginx 2>/dev/null || true
systemctl disable apache2 nginx 2>/dev/null || true
# 2. Kill old CapRover containers
docker rm -f $(docker ps -aq --filter "ancestor=caprover/caprover") 2>/dev/null || true
docker rm -f caprover 2>/dev/null || true
# 3. NUCLEAR OPTION: Kill anything else holding the ports
fuser -k 80/tcp 2>/dev/null || true
fuser -k 443/tcp 2>/dev/null || true
sleep 2

step "Starting CapRover Server..."
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
# 7. Finish
# ==========================================

chown -R "$NEW_USER":"$NEW_USER" "$USER_HOME"

header "RESTORE COMPLETE"
echo -e "1. CapRover IP: http://$SERVER_IP:3000"
echo -e "2. SSH User:    ${YELLOW}$NEW_USER${NC}"
echo -e "3. Root Login:  ${RED}DISABLED${NC}"

if [ "$BACKUP_TYPE" -eq 2 ]; then
    echo -e "\n${GREEN}Volumes restored. Reboot recommended.${NC}"
    read -r -p "Reboot now? [y/N] " CHOICE
    if [[ "$CHOICE" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        reboot
    fi
fi

exit 0
