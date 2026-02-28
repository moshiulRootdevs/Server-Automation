#!/bin/bash

set -e

echo "Updating system..."
sudo apt update && sudo apt upgrade -y

echo "Installing required base packages..."
sudo apt install -y curl software-properties-common

# -----------------------
# Install Nginx
# -----------------------
echo "Installing Nginx..."
sudo apt install -y nginx

sudo systemctl enable nginx
sudo systemctl start nginx

echo "Removing default Nginx site..."
sudo rm -rf /etc/nginx/sites-available/default
sudo rm -rf /etc/nginx/sites-enabled/default

sudo systemctl restart nginx

echo "Nginx installed and configured."

# -----------------------
# Install Redis
# -----------------------
echo "Installing Redis Server..."
sudo apt install -y redis-server

sudo systemctl enable redis-server
sudo systemctl start redis-server

echo "Redis installed and started."

# -----------------------
# Install Node.js 22
# -----------------------
echo "Installing Node.js 22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

echo "Installing PM2 globally..."
sudo npm install -g pm2

echo "Node.js version:"
node -v
npm -v

# -----------------------
# Install Certbot
# -----------------------
echo "Installing Certbot with Nginx plugin..."
sudo apt install -y certbot python3-certbot-nginx

echo "Installation complete!"