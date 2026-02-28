#!/bin/bash

#############################################
# CONFIGURATION VARIABLES (EDIT THESE)
#############################################

MONGO_VERSION="8.2"
REPLICA_SET_NAME="rs0"

SERVER_IP="67.220.95.211"        # <<< PUT YOUR SERVER PUBLIC IP HERE

ADMIN_USER="adminUser"
ADMIN_PASS="StrongPassword123"

BASE_PORT=27017   # instances will run on 27017, 27018, 27019

#############################################
# DO NOT EDIT BELOW
#############################################

set -e

echo "===== Installing MongoDB Enterprise $MONGO_VERSION ====="

sudo apt-get update
sudo apt-get install -y gnupg curl ufw openssl

# Import MongoDB public key
curl -fsSL https://pgp.mongodb.com/server-${MONGO_VERSION}.asc | \
  sudo gpg -o /usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg \
  --dearmor

# Add repository
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg ] https://repo.mongodb.com/apt/ubuntu noble/mongodb-enterprise/${MONGO_VERSION} multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-enterprise-${MONGO_VERSION}.list

sudo apt-get update
sudo apt-get install -y mongodb-enterprise

echo "===== Creating Data Directories ====="

for i in 0 1 2
do
  PORT=$((BASE_PORT + i))
  sudo mkdir -p /data/mongo${PORT}
  sudo chown -R mongodb:mongodb /data/mongo${PORT}
done

echo "===== Creating KeyFile for Replica Authentication ====="

sudo mkdir -p /etc/mongo-keyfile
sudo openssl rand -base64 756 > /etc/mongo-keyfile/keyfile
sudo chown mongodb:mongodb /etc/mongo-keyfile/keyfile
sudo chmod 400 /etc/mongo-keyfile/keyfile

echo "===== Creating Config Files ====="

for i in 0 1 2
do
  PORT=$((BASE_PORT + i))

  sudo tee /etc/mongod-${PORT}.conf > /dev/null <<EOF
storage:
  dbPath: /data/mongo${PORT}

systemLog:
  destination: file
  path: /var/log/mongodb/mongod-${PORT}.log
  logAppend: true

net:
  port: ${PORT}
  bindIp: 127.0.0.1,${SERVER_IP}

replication:
  replSetName: ${REPLICA_SET_NAME}

security:
  authorization: enabled
  keyFile: /etc/mongo-keyfile/keyfile

processManagement:
  fork: true
EOF

done

echo "===== Starting MongoDB Instances ====="

for i in 0 1 2
do
  PORT=$((BASE_PORT + i))
  sudo -u mongodb mongod --config /etc/mongod-${PORT}.conf
done

sleep 5

echo "===== Initiating Replica Set ====="

mongosh --host ${SERVER_IP} --port ${BASE_PORT} <<EOF
rs.initiate({
  _id: "${REPLICA_SET_NAME}",
  members: [
    { _id: 0, host: "${SERVER_IP}:${BASE_PORT}" },
    { _id: 1, host: "${SERVER_IP}:$((BASE_PORT+1))" },
    { _id: 2, host: "${SERVER_IP}:$((BASE_PORT+2))" }
  ]
})
EOF

sleep 10

echo "===== Creating Admin User ====="

mongosh --host ${SERVER_IP} --port ${BASE_PORT} <<EOF
use admin
db.createUser({
  user: "${ADMIN_USER}",
  pwd: "${ADMIN_PASS}",
  roles: [ { role: "root", db: "admin" } ]
})
EOF

echo "===== Configuring Firewall ====="

sudo ufw allow ${BASE_PORT}
sudo ufw allow $((BASE_PORT+1))
sudo ufw allow $((BASE_PORT+2))
sudo ufw --force enable

echo ""
echo "======================================="
echo "MongoDB Replica Set Installed!"
echo ""
echo "Replica Set: ${REPLICA_SET_NAME}"
echo "Server IP: ${SERVER_IP}"
echo "Ports: ${BASE_PORT}, $((BASE_PORT+1)), $((BASE_PORT+2))"
echo ""
echo "Connection String:"
echo "mongodb://${ADMIN_USER}:${ADMIN_PASS}@${SERVER_IP}:${BASE_PORT},${SERVER_IP}:$((BASE_PORT+1)),${SERVER_IP}:$((BASE_PORT+2))/?replicaSet=${REPLICA_SET_NAME}&authSource=admin"
echo "======================================="