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

# Select backup type
echo -e "${YELLOW}Select restore/install mode:${NC}"
echo -e "1. CapRover backup only (no volumes)"
echo -e "2. CapRover + volumes backup"
echo -e "3. Fresh install (no backup)"
read -rp "Enter [1/2/3]: " BACKUP_TYPE

if [[ ! "$BACKUP_TYPE" =~ ^[123]$ ]]; then
    echo -e "${RED}Invalid selection.${NC}"
    exit 1
fi

# Prepare upload folders right after selection
if [ "$BACKUP_TYPE" -eq 1 ]; then
    step "Creating /captain directory for CapRover backup only..."
    sudo mkdir -p /captain
    echo -e "\n${YELLOW}==> Please upload 'backup.tar' to /captain. Press ENTER when done...${NC}"
elif [ "$BACKUP_TYPE" -eq 2 ]; then
    step "Creating /captain and /captain-volumes directories for full backup restore..."
    sudo mkdir -p /captain /captain-volumes
    echo -e "\n${YELLOW}==> Please upload 'backup.tar' to /captain and 'volumes-backup.tar.gz' to /captain-volumes."
    echo -e "Press ENTER when you have uploaded BOTH files...${NC}"
else
    step "Fresh install. Skipping backup/restore steps."
fi

# Start background apt-get update and preparation (while uploading)
step "Updating packages in background..."
sudo apt-get update &>/dev/null &
UPDATE_PID=$!

echo -ne "${YELLOW}You can upload files now if needed. "
read -rp "Press ENTER to continue when uploads are finished.${NC}"

# Wait for update to finish if it has not
wait $UPDATE_PID

# Install other dependencies (hide apt update output)
step "Installing pre-requisites..."
sudo apt-get install -y ca-certificates curl &>/dev/null & pid=$!; spinner $pid

step "Adding Docker GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

step "Adding Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

step "Updating apt cache..."
sudo apt-get update &>/dev/null & pid=$!; spinner $pid

step "Installing Docker..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin &>/dev/null & pid=$!; spinner $pid

step "Checking Docker status..."
if systemctl is-active --quiet docker; then
  echo -e "${GREEN}Docker is running.${NC}"
else
  echo -e "${RED}Docker is NOT running. Press Enter to continue script execution...${NC}"
  read
fi

step "Disabling Apache server..."
sudo systemctl stop apache2 2>/dev/null || true
sudo systemctl disable apache2 2>/dev/null || true

step "Starting CapRover using Docker..."
sudo docker run -d --name caprover \
    -p 80:80 -p 443:443 -p 3000:3000 \
    -e ACCEPTED_TERMS=true \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /captain:/captain caprover/caprover

# Only extract volumes if type 2 selected
if [ "$BACKUP_TYPE" -eq 2 ]; then
    while [[ ! -f /captain-volumes/volumes-backup.tar.gz ]]; do
        echo -e "${RED}File /captain-volumes/volumes-backup.tar.gz NOT found!${NC}"
        echo -e "${YELLOW}Please upload the 'volumes-backup.tar.gz' file to /captain-volumes, then press ENTER to continue...${NC}"
        read
    done

    step "Extracting volumes-backup (this might take a while)..."
    sudo sudo tar -xzf /captain-volumes/volumes-backup.tar.gz -C /var/lib/docker/volumes &>/dev/null
    echo -e "${GREEN}Volumes extraction successful.${NC}"

    echo -e "\n${RED}Do you want to DELETE the /captain-volumes directory and the volume backup file? [y/N]${NC}"
    read -r DELETECAPTAINVOLUMES
    if [[ "$DELETECAPTAINVOLUMES" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        sudo rm -rf /captain-volumes
        echo -e "${GREEN}/captain-volumes directory deleted.${NC}"
    else
        echo -e "${YELLOW}/captain-volumes directory NOT deleted. You may delete it later safely.${NC}"
    fi

    echo -e "\n${YELLOW}==> Restart required for volumes backup to work"
    echo -en "${YELLOW}Press [r] to restart VPS now or any other key to skip: ${NC}"
    read -n1 CHOICE
    echo
    if [[ "$CHOICE" =~ [rR] ]]; then
        step "Rebooting..."
        sudo rm /caproverrestore.sh
        sleep 2
        sudo reboot
        exit 0
    fi
else
    sudo rm /caproverrestore.sh    
fi

echo -e "\n${GREEN}==> Process complete! CapRover should be running. <==${NC}"