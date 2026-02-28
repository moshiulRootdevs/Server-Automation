#!/bin/bash
set -euo pipefail

# ==============================
# CONFIG
# ==============================
MONGO_USER="admin"
MONGO_PASS="StrongPassword123"

PORT1=27018
PORT2=27019
PORT3=27020

REPLICA_NAME="rs0"

BIND_IP="0.0.0.0"
ADVERTISED_HOST="67.220.95.211"   # MUST be reachable by remote clients
ALLOW_FROM_IP=""

# ==============================
# HELPERS
# ==============================

wait_for_port() {
  local port="$1"
  for i in {1..60}; do
    if mongosh --quiet --host 127.0.0.1 --port "$port" \
      --eval "db.runCommand({ping:1}).ok" 2>/dev/null | grep -q 1; then
      return 0
    fi
    sleep 1
  done
  echo "MongoDB not responding on $port"
  exit 1
}

wait_for_primary() {
  for i in {1..90}; do
    if mongosh --quiet --host 127.0.0.1 --port "$PORT1" \
      --eval "db.hello().isWritablePrimary" 2>/dev/null | grep -q true; then
      return 0
    fi
    sleep 1
  done
  echo "PRIMARY election timeout"
  exit 1
}

# ==============================
# START SERVICES (already installed assumed)
# ==============================

sudo systemctl daemon-reload
sudo systemctl enable mongod1 mongod2 mongod3
sudo systemctl restart mongod1 mongod2 mongod3

wait_for_port $PORT1
wait_for_port $PORT2
wait_for_port $PORT3

# ==============================
# INIT REPLICA SET
# ==============================

echo "Initializing replica set..."

mongosh --quiet --host 127.0.0.1 --port $PORT1 --eval "
try {
  rs.status();
  print('Replica already initialized');
} catch (e) {
  rs.initiate({
    _id: '$REPLICA_NAME',
    members: [
      { _id: 0, host: '$ADVERTISED_HOST:$PORT1' },
      { _id: 1, host: '$ADVERTISED_HOST:$PORT2' },
      { _id: 2, host: '$ADVERTISED_HOST:$PORT3' }
    ]
  });
}
"

wait_for_primary

echo "Replica PRIMARY ready."

# ==============================
# CREATE ADMIN USER (SAFE)
# ==============================

echo "Ensuring admin user exists..."

mongosh --quiet --host 127.0.0.1 --port $PORT1 --eval "
use admin;
if (!db.getUser('$MONGO_USER')) {
  db.createUser({
    user: '$MONGO_USER',
    pwd: '$MONGO_PASS',
    roles: [{ role: 'root', db: 'admin' }]
  });
  print('Admin user created.');
} else {
  print('Admin user already exists.');
}
"

# Verify user creation
mongosh --quiet --host 127.0.0.1 --port $PORT1 --eval "
use admin;
printjson(db.getUser('$MONGO_USER'));
"

# ==============================
# ENABLE AUTH
# ==============================

echo "Enabling authorization..."

for conf in /etc/mongod1.conf /etc/mongod2.conf /etc/mongod3.conf; do
  sudo perl -0777 -i -pe \
    's/security:\n  keyFile: \/etc\/mongodb-keyfile/security:\n  authorization: enabled\n  keyFile: \/etc\/mongodb-keyfile/g' \
    "$conf"
done

sudo systemctl restart mongod1 mongod2 mongod3

sleep 5

# ==============================
# FINAL CHECK
# ==============================

echo "Testing authenticated connection..."

mongosh "mongodb://$MONGO_USER:$MONGO_PASS@127.0.0.1:$PORT1,127.0.0.1:$PORT2,127.0.0.1:$PORT3/?replicaSet=$REPLICA_NAME&authSource=admin" --eval "db.runCommand({connectionStatus:1})"

echo ""
echo "======================================"
echo "MongoDB 3-Node Replica Set READY"
echo "Replica: $REPLICA_NAME"
echo "Host: $ADVERTISED_HOST"
echo "Ports: $PORT1, $PORT2, $PORT3"
echo "======================================"
echo ""
echo "Remote connect:"
echo "mongosh \"mongodb://$MONGO_USER:$MONGO_PASS@$ADVERTISED_HOST:$PORT1,$ADVERTISED_HOST:$PORT2,$ADVERTISED_HOST:$PORT3/?replicaSet=$REPLICA_NAME&authSource=admin\""