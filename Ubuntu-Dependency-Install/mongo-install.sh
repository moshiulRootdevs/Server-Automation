#!/bin/bash
set -euo pipefail

# ==============================
# CONFIGURATION (EDIT THESE)
# ==============================
MONGO_USER="admin"
MONGO_PASS="StrongPassword123"
PORT1=27018
PORT2=27019
REPLICA_NAME="rs0"

# Remote access:
# - Best practice: set this to your server's private IP (e.g. 10.x / 192.168.x)
# - For open remote access: 0.0.0.0 (use firewall restrictions!)
BIND_IP="0.0.0.0"

# Firewall restriction (optional):
# Leave empty "" to allow from anywhere (not recommended).
# Example: ALLOW_FROM_IP="203.0.113.50"
ALLOW_FROM_IP=""

# MongoDB apt repo line (MongoDB 8.0 enterprise for Ubuntu 24.04 Noble)
MONGO_REPO_LINE='deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.com/apt/ubuntu noble/mongodb-enterprise/8.0 multiverse'

# ==============================
# HELPERS
# ==============================
SERVER_IP="$(hostname -I | awk '{print $1}')"

mongo_rs_uri_local() {
  # Replica-aware URI so mongosh routes to PRIMARY
  echo "mongodb://127.0.0.1:${PORT1},127.0.0.1:${PORT2}/?replicaSet=${REPLICA_NAME}"
}

wait_for_mongo_port() {
  local port="$1"
  for i in {1..60}; do
    if mongosh --quiet --host 127.0.0.1 --port "$port" --eval "db.runCommand({ping:1}).ok" 2>/dev/null | grep -q "1"; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: MongoDB did not respond on port $port"
  exit 1
}

wait_for_primary() {
  local uri
  uri="$(mongo_rs_uri_local)"
  for i in {1..90}; do
    # isWritablePrimary is the modern field; ismaster may still exist in some outputs
    if mongosh --quiet "$uri" --eval "db.hello().isWritablePrimary" 2>/dev/null | grep -q "true"; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Replica set did not elect a PRIMARY in time"
  mongosh "$uri" --eval "rs.status()" || true
  exit 1
}

# ==============================
# INSTALL MONGODB
# ==============================
echo "[1/9] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y gnupg curl ufw

echo "[2/9] Adding MongoDB 8 GPG key..."
curl -fsSL https://pgp.mongodb.com/server-8.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

echo "[3/9] Adding MongoDB repository..."
echo "$MONGO_REPO_LINE" | sudo tee /etc/apt/sources.list.d/mongodb-enterprise-8.0.list >/dev/null

sudo apt-get update
echo "[4/9] Installing MongoDB Enterprise..."
sudo apt-get install -y mongodb-enterprise

# ==============================
# DIRECTORIES + KEYFILE
# ==============================
echo "[5/9] Creating data/log directories..."
sudo mkdir -p /data/mongo1 /data/mongo2
sudo mkdir -p /var/log/mongodb1 /var/log/mongodb2
sudo chown -R mongodb:mongodb /data/mongo1 /data/mongo2 /var/log/mongodb1 /var/log/mongodb2

echo "[6/9] Creating keyfile..."
if [[ ! -f /etc/mongodb-keyfile ]]; then
  sudo openssl rand -base64 756 | sudo tee /etc/mongodb-keyfile >/dev/null
  sudo chmod 400 /etc/mongodb-keyfile
  sudo chown mongodb:mongodb /etc/mongodb-keyfile
fi

# ==============================
# CONFIG FILES (NO auth at first boot)
# Why: easiest/most reliable way to create the first admin user.
# Then we enable authorization and restart.
# ==============================
echo "[7/9] Writing MongoDB configs..."

sudo tee /etc/mongod1.conf >/dev/null <<EOF
storage:
  dbPath: /data/mongo1
systemLog:
  destination: file
  path: /var/log/mongodb1/mongod.log
  logAppend: true
net:
  port: ${PORT1}
  bindIp: ${BIND_IP}
replication:
  replSetName: ${REPLICA_NAME}
security:
  keyFile: /etc/mongodb-keyfile
processManagement:
  fork: false
EOF

sudo tee /etc/mongod2.conf >/dev/null <<EOF
storage:
  dbPath: /data/mongo2
systemLog:
  destination: file
  path: /var/log/mongodb2/mongod.log
  logAppend: true
net:
  port: ${PORT2}
  bindIp: ${BIND_IP}
replication:
  replSetName: ${REPLICA_NAME}
security:
  keyFile: /etc/mongodb-keyfile
processManagement:
  fork: false
EOF

# ==============================
# SYSTEMD SERVICES
# ==============================
echo "[8/9] Creating systemd services..."

sudo tee /etc/systemd/system/mongod1.service >/dev/null <<EOF
[Unit]
Description=MongoDB Instance 1 (${PORT1})
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongod1.conf
Restart=always
RestartSec=2
LimitNOFILE=64000

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/mongod2.service >/dev/null <<EOF
[Unit]
Description=MongoDB Instance 2 (${PORT2})
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongod2.conf
Restart=always
RestartSec=2
LimitNOFILE=64000

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mongod1 mongod2
sudo systemctl restart mongod1 mongod2

# Wait for both instances to answer
wait_for_mongo_port "${PORT1}"
wait_for_mongo_port "${PORT2}"

# ==============================
# FIREWALL
# ==============================
echo "[9/9] Configuring firewall..."
if [[ -n "${ALLOW_FROM_IP}" ]]; then
  sudo ufw allow from "${ALLOW_FROM_IP}" to any port "${PORT1}"
  sudo ufw allow from "${ALLOW_FROM_IP}" to any port "${PORT2}"
else
  sudo ufw allow "${PORT1}"
  sudo ufw allow "${PORT2}"
fi
sudo ufw --force enable

# ==============================
# INIT REPLICA SET (idempotent-ish)
# ==============================
echo "Initializing replica set (if not already initialized)..."
# Use local loopback members to avoid public-IP DNS/routing weirdness on a single box.
# Remote clients still connect via public IP, but RS internal members can stay on 127.0.0.1.
mongosh --quiet --host 127.0.0.1 --port "${PORT1}" --eval '
try {
  var s = rs.status();
  print("Replica set already initialized: " + s.set);
} catch (e) {
  print("Initiating replica set...");
  rs.initiate({
    _id: "'"${REPLICA_NAME}"'",
    members: [
      { _id: 0, host: "127.0.0.1:'"${PORT1}"'" },
      { _id: 1, host: "127.0.0.1:'"${PORT2}"'" }
    ]
  });
}
'

# Wait for PRIMARY election
wait_for_primary

# ==============================
# CREATE ADMIN USER (if missing)
# ==============================
echo "Creating admin user (if not exists)..."
mongosh --quiet "$(mongo_rs_uri_local)" --eval '
use admin;
var existing = db.getUser("'"${MONGO_USER}"'");
if (existing) {
  print("User already exists: '"${MONGO_USER}"'");
} else {
  db.createUser({
    user: "'"${MONGO_USER}"'",
    pwd: "'"${MONGO_PASS}"'",
    roles: [ { role: "root", db: "admin" } ]
  });
  print("Created user: '"${MONGO_USER}"'");
}
'

# ==============================
# ENABLE AUTHORIZATION + RESTART
# ==============================
echo "Enabling authorization in configs..."
sudo perl -0777 -i -pe 's/security:\n  keyFile: \/etc\/mongodb-keyfile/security:\n  authorization: enabled\n  keyFile: \/etc\/mongodb-keyfile/g' /etc/mongod1.conf
sudo perl -0777 -i -pe 's/security:\n  keyFile: \/etc\/mongodb-keyfile/security:\n  authorization: enabled\n  keyFile: \/etc\/mongodb-keyfile/g' /etc/mongod2.conf

sudo systemctl restart mongod1 mongod2
wait_for_mongo_port "${PORT1}"
wait_for_mongo_port "${PORT2}"
wait_for_primary

echo ""
echo "=============================================="
echo "MongoDB 8 Replica Set Ready (Remote Enabled)"
echo "Replica Set: ${REPLICA_NAME}"
echo "Instance Ports: ${PORT1}, ${PORT2}"
echo "Server IP (detected): ${SERVER_IP}"
echo "Admin User: ${MONGO_USER}"
echo "=============================================="
echo ""
echo "Local connect (replica-aware):"
echo "mongosh \"mongodb://${MONGO_USER}:${MONGO_PASS}@127.0.0.1:${PORT1},127.0.0.1:${PORT2}/?replicaSet=${REPLICA_NAME}&authSource=admin\""
echo ""
echo "Remote connect (replace SERVER_IP):"
echo "mongosh \"mongodb://${MONGO_USER}:${MONGO_PASS}@SERVER_IP:${PORT1},SERVER_IP:${PORT2}/?replicaSet=${REPLICA_NAME}&authSource=admin\""
echo ""
echo "Services to check:"
echo "  systemctl status mongod1"
echo "  systemctl status mongod2"
echo "Note: mongod.service is unused in this 2-instance setup."