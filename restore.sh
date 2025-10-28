#!/bin/bash

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

step "Updating packages..."
sudo apt-get update &>/dev/null & spinner $!

step "Installing pre-requisites..."
sudo apt-get install -y ca-certificates curl &>/dev/null & spinner $!

step "Adding Docker GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

step "Adding Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

step "Updating apt cache..."
sudo apt-get update &>/dev/null & spinner $!

step "Installing Docker..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin &>/dev/null & spinner $!

step "Checking Docker status..."
sudo systemctl status docker --no-pager

step "Creating /captain and /captain-volumes directory..."
sudo mkdir -p /captain /captain-volumes

echo -e "\n${YELLOW}==> Please upload 'backup.tar' and 'volumes-backup.tar.gz' to /captain and /captain-volumes now, then press ENTER to continue <==${NC}"
read

step "Disabling Apache server..."
sudo systemctl stop apache2 2>/dev/null || true
sudo systemctl disable apache2 2>/dev/null || true

step "Starting CapRover using Docker..."
sudo docker run -d --name caprover \
    -p 80:80 -p 443:443 -p 3000:3000 \
    -e ACCEPTED_TERMS=true \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /captain:/captain caprover/caprover

step "Restoring CapRover volumes backup (volumes-backup.tar.gz)..."
sudo tar xzvf /captain/volumes-backup.tar.gz -C /var/lib/docker/volumes

echo -e "\n${RED}Do you want to DELETE the /captain-volumes directory and the volume backup file? [y/N]${NC}"
read -r DELETECAPTAINVOLUMES
if [[ "$DELETECAPTAINVOLUMES" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    sudo rm -rf /captain-volumes
    echo -e "${GREEN}/captain volumes directory deleted.${NC}"
else
    echo -e "${YELLOW}/captain volumes directory NOT deleted. You may delete it later safely.${NC}"
fi

echo -e "\n${YELLOW}==> Restart required for volumes backup to work"
echo -en "${YELLOW}Press [r] to restart VPS now or any other key to skip: ${NC}"
read -n1 CHOICE
echo
if [[ "$CHOICE" =~ [rR] ]]; then
    step "Rebooting..."
    sudo reboot
fi

echo -e "\n${GREEN}==> Process complete! CapRover should be running. <==${NC}"
