#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
SPIN='|/-\'

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
    echo -e "${GREEN}==> $1${NC}"
}

wait_for_enter() {
    echo -e "${YELLOW}Press ENTER to continue...${NC}"
    read
}

USER_HOME="/home/t12"

printf '\n%.0s' {1..3}
echo -e "${YELLOW}CapRover Restore/Install:${NC}"
echo -e "1. CapRover backup only (no volumes)"
echo -e "2. CapRover + volumes backup"
echo -e "3. Fresh install (no backup)"
read -rp "Enter [1/2/3]: " BACKUP_TYPE

if [[ ! "$BACKUP_TYPE" =~ ^[123]$ ]]; then
    echo -e "${RED}Invalid selection.${NC}"
    exit 1
fi

step "Stopping Docker to free up all ports..."
sudo systemctl stop docker
sudo systemctl stop docker.socket
sudo killall docker-proxy 2>/dev/null || true
sleep 2

step "Removing old Docker port locks if any..."
sudo rm -f /var/lib/docker/network/files/local-kv.db

step "Starting Docker..."
sudo systemctl start docker
sleep 2

step "Pruning Docker system resources (no containers should be running now)..."
sudo docker system prune -a -f
sudo docker network prune -f

step "Ensuring nothing is listening on 80/443..."
for port in 80 443; do
    if sudo lsof -i :$port | grep LISTEN; then
        echo -e "${RED}Error: Port $port is still in use! Fix manually and rerun the script.${NC}"
        exit 1
    fi
done

# Prepare folders and move uploaded backup files as needed
sudo mkdir -p /captain /captain-volumes

if [ "$BACKUP_TYPE" -eq 1 ] || [ "$BACKUP_TYPE" -eq 2 ]; then
    step "Checking and moving backup files..."
    if [ ! -f "/captain/backup.tar" ]; then
        if [ -f "$USER_HOME/backup.tar" ]; then
            sudo mv "$USER_HOME/backup.tar" /captain/
        else
            echo -e "${YELLOW}Please upload 'backup.tar' to $USER_HOME and press ENTER once done.${NC}"
            wait_for_enter
            [ -f "$USER_HOME/backup.tar" ] && sudo mv "$USER_HOME/backup.tar" /captain/
        fi
    fi
fi

if [ "$BACKUP_TYPE" -eq 2 ]; then
    if [ ! -f "/captain-volumes/volumes-backup.tar.gz" ]; then
        if [ -f "$USER_HOME/volumes-backup.tar.gz" ]; then
            sudo mv "$USER_HOME/volumes-backup.tar.gz" /captain-volumes/
        else
            echo -e "${YELLOW}Please upload 'volumes-backup.tar.gz' to $USER_HOME and press ENTER once done.${NC}"
            wait_for_enter
            [ -f "$USER_HOME/volumes-backup.tar.gz" ] && sudo mv "$USER_HOME/volumes-backup.tar.gz" /captain-volumes/
        fi
    fi
fi

step "Updating system and installing dependencies (curl, nano, htop, npm, UFW, fail2ban)..."
sudo apt-get update &>/dev/null &
spinner $!
sudo apt-get install -y ca-certificates curl nano htop npm ufw fail2ban &>/dev/null &
spinner $!

step "Installing CapRover CLI..."
sudo npm install -g caprover &>/dev/null

step "Adding user '$USER' to docker group..."
sudo usermod -aG docker $USER

step "Checking and updating Docker to latest version..."
if ! docker version | grep -q "API version: *1.44"; then
    sudo apt-get remove -y docker-ce docker-ce-cli containerd.io
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

step "Configuring UFW (allowing needed ports)..."
sudo ufw allow OpenSSH
sudo ufw allow 80,443,3000,996,7946,4789,2377/tcp
sudo ufw allow 7946,4789,2377/udp
sudo ufw --force enable

step "Enabling & starting Fail2Ban..."
sudo systemctl enable --now fail2ban

step "Disabling Apache/Nginx if any..."
sudo systemctl stop apache2 nginx 2>/dev/null || true
sudo systemctl disable apache2 nginx 2>/dev/null || true

step "Removing existing CapRover containers if any..."
sudo docker rm -f $(sudo docker ps -aq --filter "ancestor=caprover/caprover") 2>/dev/null || true
sudo docker rm -f caprover 2>/dev/null || true

step "Starting CapRover server container..."
CAPROVER_STARTED="no"
for i in {1..3}; do
    sudo docker run -d --name caprover \
      -p 80:80 -p 443:443 -p 3000:3000 \
      -e ACCEPTED_TERMS=true \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /captain:/captain \
      caprover/caprover && CAPROVER_STARTED="yes" && break
    echo -e "${RED}Failed to start CapRover. Retrying ($i)...${NC}"
    sleep 3
done

if [ "$CAPROVER_STARTED" != "yes" ]; then
    echo -e "${RED}Failed to start CapRover server after several attempts. Please check Docker and port usage manually.${NC}"
    exit 1
fi

sleep 15

if ! sudo docker ps | grep -q caprover; then
    echo -e "${RED}CapRover is not running. Something went wrong. Check with 'sudo docker logs caprover' and fix manually.${NC}"
    exit 1
fi

if ! sudo docker ps | grep -q "0.0.0.0:80->80"; then
    echo -e "${RED}Port 80 is not mapped. CapRover won't be accessible in browser. Fix port conflicts and rerun the script.${NC}"
    exit 1
fi

echo -e "${GREEN}CapRover server is running! Access it in your browser at http://your-server-ip:3000 or http(s)://your-server-ip ${NC}"

if [ "$BACKUP_TYPE" -eq 2 ] && [ -f /captain-volumes/volumes-backup.tar.gz ]; then
    step "Restoring volumes backup..."
    sudo tar -xzf /captain-volumes/volumes-backup.tar.gz -C /var/lib/docker/volumes
    echo -e "${GREEN}Volumes extracted successfully!${NC}"
fi

echo -e "${YELLOW}If you restored volumes, a reboot may be required. Do you want to reboot NOW? [y/N]${NC}"
read -r CHOICE
if [[ "$CHOICE" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    step "Rebooting system..."
    sudo reboot
    exit 0
fi

echo -e "${GREEN}==> Restore complete! CapRover and your apps should now be live.${NC}"
