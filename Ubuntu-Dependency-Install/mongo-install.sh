#!/bin/bash

# ==============================
# CONFIGURATION (EDIT THESE)
# ==============================
MONGO_USER="admin"
MONGO_PASS="StrongPassword123"
PORT1=27018
PORT2=27019
REPLICA_NAME="rs0"
BIND_IP="0.0.0.0"

set -e

echo "Updating system..."
sudo apt update

echo "Installing dependencies..."
sudo apt install -y gnupg curl ufw

echo "Adding MongoDB 8 GPG key..."
curl -fsSL https://pgp.mongodb.com/server-8.0.asc | \
  sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg \
  --dearmor

echo "Adding MongoDB repository..."
echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.com/apt/ubuntu noble/mongodb-enterprise/8.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-enterprise-8.0.list

sudo apt update
sudo apt install -y mongodb-enterprise

# ==============================
# CREATE DATA & LOG DIRECTORIES
# ==============================

sudo mkdir -p /data/mongo1 /data/mongo2
sudo mkdir -p /var/log/mongodb1 /var/log/mongodb2

sudo chown -R mongodb:mongodb /data /var/log/mongodb1 /var/log/mongodb2

# ==============================
# CREATE KEYFILE
# ==============================

echo "Creating replica keyfile..."
sudo openssl rand -base64 756 | sudo tee /etc/mongodb-keyfile > /dev/null
sudo chmod 400 /etc/mongodb-keyfile
sudo chown mongodb:mongodb /etc/mongodb-keyfile

# ==============================
# CREATE CONFIG FILES
# ==============================

echo "Creating config for instance 1..."
sudo tee /etc/mongod1.conf > /dev/null <<EOF
storage:
  dbPath: /data/mongo1

systemLog:
  destination: file
  path: /var/log/mongodb1/mongod.log
  logAppend: true

net:
  port: $PORT1
  bindIp: $BIND_IP

replication:
  replSetName: $REPLICA_NAME

security:
  authorization: enabled
  keyFile: /etc/mongodb-keyfile

processManagement:
  fork: false
EOF

echo "Creating config for instance 2..."
sudo tee /etc/mongod2.conf > /dev/null <<EOF
storage:
  dbPath: /data/mongo2

systemLog:
  destination: file
  path: /var/log/mongodb2/mongod.log
  logAppend: true

net:
  port: $PORT2
  bindIp: $BIND_IP

replication:
  replSetName: $REPLICA_NAME

security:
  authorization: enabled
  keyFile: /etc/mongodb-keyfile

processManagement:
  fork: false
EOF

# ==============================
# CREATE SYSTEMD SERVICES
# ==============================

echo "Creating systemd services..."

sudo tee /etc/systemd/system/mongod1.service > /dev/null <<EOF
[Unit]
Description=MongoDB Instance 1
After=network.target

[Service]
User=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongod1.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/mongod2.service > /dev/null <<EOF
[Unit]
Description=MongoDB Instance 2
After=network.target

[Service]
User=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongod2.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mongod1 mongod2
sudo systemctl start mongod1 mongod2

sleep 5

# ==============================
# FIREWALL CONFIG
# ==============================

echo "Configuring firewall..."
sudo ufw allow $PORT1
sudo ufw allow $PORT2
sudo ufw --force enable

# ==============================
# INIT REPLICA SET
# ==============================

echo "Initializing replica set..."

mongosh --port $PORT1 <<EOF
rs.initiate({
  _id: "$REPLICA_NAME",
  members: [
    { _id: 0, host: "$(hostname -I | awk '{print $1}'):$PORT1" },
    { _id: 1, host: "$(hostname -I | awk '{print $1}'):$PORT2" }
  ]
})
EOF

sleep 5

# ==============================
# CREATE ADMIN USER
# ==============================

echo "Creating admin user..."

mongosh --port $PORT1 <<EOF
use admin
db.createUser({
  user: "$MONGO_USER",
  pwd: "$MONGO_PASS",
  roles: [ { role: "root", db: "admin" } ]
})
EOF

echo ""
echo "=============================================="
echo "MongoDB 8 Replica Set Ready (Remote Enabled)"
echo "Replica Set: $REPLICA_NAME"
echo "Ports: $PORT1 , $PORT2"
echo "Admin User: $MONGO_USER"
echo "=============================================="
echo ""
echo "Connection String:"
echo "mongodb://$MONGO_USER:$MONGO_PASS@SERVER_IP:$PORT1,SERVER_IP:$PORT2/?replicaSet=$REPLICA_NAME"
echo ""
echo "Replace SERVER_IP with your public/server IP."