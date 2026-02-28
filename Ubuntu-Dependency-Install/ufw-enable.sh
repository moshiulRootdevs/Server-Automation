#!/bin/bash

set -e

# ----------------------------
# Define Ports To Open Here
# ----------------------------
PORTS=(
    "22"        # SSH
    "80"        # HTTP (Nginx)
    "443"       # HTTPS
)

echo "Installing UFW if not installed..."
sudo apt update -y
sudo apt install -y ufw

echo "Allowing selected ports..."

for PORT in "${PORTS[@]}"
do
    echo "Opening port $PORT..."
    sudo ufw allow $PORT
done

echo "Enabling UFW..."
sudo ufw --force enable

echo "Reloading UFW..."
sudo ufw reload

echo "UFW Status:"
sudo ufw status numbered

echo "Done!"