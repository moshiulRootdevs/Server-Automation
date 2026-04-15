#!/bin/bash
set -euo pipefail

# ============================================================
# MongoDB 8 Enterprise - 3-instance replica set on ONE server
# Ubuntu 24.04 (Noble)
#
# What this does:
#  1) Installs MongoDB Enterprise 8.0
#  2) Creates 3 mongod instances (ports 27018/27019/27020)
#  3) Initializes replica set (members advertise a REMOTE-reachable host)
#  4) Creates the FIRST admin user safely (after PRIMARY is elected)
#  5) Enables authorization only after user exists
#  6) Opens firewall ports (optionally restricted by IP)
#
# IMPORTANT:
#  - ADVERTISED_HOST MUST be reachable from remote clients (public IP or DNS)
# ============================================================

# ==============================
# CONFIGURATION (EDIT THESE)
# ==============================
MONGO_USER="admin"
MONGO_PASS="StrongPassword123"

REPLICA_NAME="rs0"

PORT1=27018
PORT2=27019
PORT3=27020

# Listen address (0.0.0.0 enables remote access; use firewall!)
BIND_IP="0.0.0.0"

# What the replica set members "advertise" to clients.
# MUST be reachable from your clients. Use public IP or DNS name.
ADVERTISED_HOST="67.220.95.211"

# Optional firewall restriction (recommended):
# Example: ALLOW_FROM_IP="203.0.113.50"
ALLOW_FROM_IP=""

# MongoDB apt repo line (MongoDB 8.0 enterprise for Ubuntu 24.04 Noble)
MONGO_REPO_LINE='deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.com/apt/ubuntu noble/mongodb-enterprise/8.0 multiverse'

# ==============================
# INTERNALS (DON'T EDIT)
# ==============================
SERVER_IP="$(hostname -I | awk '{print $1}')"
REPL_HOST="${ADVERTISED_HOST:-$SERVER_IP}"

DATA1="/data/mongo1"
DATA2="/data/mongo2"
DATA3="/data/mongo3"

LOGDIR1="/var/log/mongodb1"
LOGDIR2="/var/log/mongodb2"
LOGDIR3="/var/log/mongodb3"

LOG1="${LOGDIR1}/mongod.log"
LOG2="${LOGDIR2}/mongod.log"
LOG3="${LOGDIR3}/mongod.log"

CONF1="/etc/mongod1.conf"
CONF2="/etc/mongod2.conf"
CONF3="/etc/mongod3.conf"

KEYFILE="/etc/mongodb-keyfile"

# ==============================
# HELPERS
# ==============================
log() { echo -e "\n==> $*\n"; }

wait_for_port_noauth() {
  local port="$1"
  for _ in {1..60}; do
    if mongosh --quiet --host 127.0.0.1 --port "$port" \
      --eval "db.runCommand({ping:1}).ok" 2>/dev/null | grep -q "1"; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: MongoDB did not respond on port $port"
  exit 1
}

wait_for_port_auth() {
  local port="$1"
  for _ in {1..90}; do
    if mongosh --quiet --host 127.0.0.1 --port "$port" \
      -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
      --eval "db.runCommand({ping:1}).ok" 2>/dev/null | grep -q "1"; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: MongoDB (auth) did not respond on port $port"
  echo "Hint: Most commonly this means auth is enabled but the admin user does not exist."
  exit 1
}

wait_for_primary_noauth() {
  for _ in {1..120}; do
    if mongosh --quiet --host 127.0.0.1 --port "$PORT1" \
      --eval "db.hello().isWritablePrimary" 2>/dev/null | grep -q "true"; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Replica set did not elect a PRIMARY (noauth) in time"
  mongosh --host 127.0.0.1 --port "$PORT1" --eval "rs.status()" || true
  exit 1
}

wait_for_primary_auth() {
  for _ in {1..120}; do
    if mongosh --quiet --host 127.0.0.1 --port "$PORT1" \
      -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
      --eval "db.hello().isWritablePrimary" 2>/dev/null | grep -q "true"; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Replica set did not elect a PRIMARY (auth) in time"
  mongosh --host 127.0.0.1 --port "$PORT1" \
    -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
    --eval "rs.status()" || true
  exit 1
}

write_conf_noauth() {
  local conf="$1" dbpath="$2" logfile="$3" port="$4"
  sudo tee "$conf" >/dev/null <<EOF
storage:
  dbPath: $dbpath
systemLog:
  destination: file
  path: $logfile
  logAppend: true
net:
  port: $port
  bindIp: $BIND_IP
replication:
  replSetName: $REPLICA_NAME
security:
  keyFile: $KEYFILE
processManagement:
  fork: false
EOF
}

enable_authorization_in_conf() {
  local conf="$1"
  sudo perl -0777 -i -pe \
    's/security:\n  keyFile: \/etc\/mongodb-keyfile/security:\n  authorization: enabled\n  keyFile: \/etc\/mongodb-keyfile/g' \
    "$conf"
}

create_systemd_service() {
  local name="$1" conf="$2" port="$3"
  sudo tee "/etc/systemd/system/${name}.service" >/dev/null <<EOF
[Unit]
Description=MongoDB Instance (${port})
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config ${conf}
Restart=always
RestartSec=2
LimitNOFILE=64000

[Install]
WantedBy=multi-user.target
EOF
}

# ==============================
# 1) INSTALL MONGODB
# ==============================
log "[1/10] Installing dependencies + MongoDB repo"
sudo apt-get update
sudo apt-get install -y gnupg curl ufw

curl -fsSL https://pgp.mongodb.com/server-8.0.asc \
  | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

echo "$MONGO_REPO_LINE" | sudo tee /etc/apt/sources.list.d/mongodb-enterprise-8.0.list >/dev/null

sudo apt-get update
log "[2/10] Installing MongoDB Enterprise"
sudo apt-get install -y mongodb-enterprise

# ==============================
# 2) DIRS + KEYFILE
# ==============================
log "[3/10] Creating data/log directories"
sudo mkdir -p "$DATA1" "$DATA2" "$DATA3"
sudo mkdir -p "$LOGDIR1" "$LOGDIR2" "$LOGDIR3"
sudo chown -R mongodb:mongodb "$DATA1" "$DATA2" "$DATA3" "$LOGDIR1" "$LOGDIR2" "$LOGDIR3"

log "[4/10] Creating keyfile"
if [[ ! -f "$KEYFILE" ]]; then
  sudo openssl rand -base64 756 | sudo tee "$KEYFILE" >/dev/null
  sudo chmod 400 "$KEYFILE"
  sudo chown mongodb:mongodb "$KEYFILE"
fi

# ==============================
# 3) CONFIGS (AUTH OFF FIRST)
# ==============================
log "[5/10] Writing mongod configs (authorization OFF initially)"
write_conf_noauth "$CONF1" "$DATA1" "$LOG1" "$PORT1"
write_conf_noauth "$CONF2" "$DATA2" "$LOG2" "$PORT2"
write_conf_noauth "$CONF3" "$DATA3" "$LOG3" "$PORT3"

# ==============================
# 4) SYSTEMD SERVICES
# ==============================
log "[6/10] Creating systemd services + starting instances"
create_systemd_service "mongod1" "$CONF1" "$PORT1"
create_systemd_service "mongod2" "$CONF2" "$PORT2"
create_systemd_service "mongod3" "$CONF3" "$PORT3"

sudo systemctl daemon-reload
sudo systemctl enable mongod1 mongod2 mongod3
sudo systemctl restart mongod1 mongod2 mongod3

wait_for_port_noauth "$PORT1"
wait_for_port_noauth "$PORT2"
wait_for_port_noauth "$PORT3"

# ==============================
# 5) FIREWALL
# ==============================
log "[7/10] Configuring firewall (ufw)"
if [[ -n "$ALLOW_FROM_IP" ]]; then
  sudo ufw allow from "$ALLOW_FROM_IP" to any port "$PORT1"
  sudo ufw allow from "$ALLOW_FROM_IP" to any port "$PORT2"
  sudo ufw allow from "$ALLOW_FROM_IP" to any port "$PORT3"
else
  sudo ufw allow "$PORT1"
  sudo ufw allow "$PORT2"
  sudo ufw allow "$PORT3"
fi
sudo ufw --force enable

# ==============================
# 6) INIT REPLICA SET (REMOTE-SAFE HOSTS)
# ==============================
log "[8/10] Initializing replica set (idempotent)"
mongosh --quiet --host 127.0.0.1 --port "$PORT1" --eval "
try {
  var s = rs.status();
  print('Replica set already initialized: ' + s.set);
} catch (e) {
  if (e.code !== 94 && e.codeName !== 'NotYetInitialized') {
    throw new Error('rs.status() failed unexpectedly: [' + e.codeName + '] ' + e.message);
  }
  print('Initiating replica set...');
  rs.initiate({
    _id: '$REPLICA_NAME',
    members: [
      { _id: 0, host: '$REPL_HOST:$PORT1' },
      { _id: 1, host: '$REPL_HOST:$PORT2' },
      { _id: 2, host: '$REPL_HOST:$PORT3' }
    ]
  });
}
"

wait_for_primary_noauth

# ==============================
# 7) CREATE ADMIN USER (FIXED: NO "use admin" IN --eval)
# ==============================
log "[9/10] Creating admin user if missing (on PRIMARY)"
mongosh --quiet --host 127.0.0.1 --port "$PORT1" --eval "
var adminDb = db.getSiblingDB('admin');
var existing = adminDb.getUser('$MONGO_USER');

if (existing) {
  print('User already exists: $MONGO_USER');
} else {
  adminDb.createUser({
    user: '$MONGO_USER',
    pwd: '$MONGO_PASS',
    roles: [ { role: 'root', db: 'admin' } ]
  });
  print('Created user: $MONGO_USER');
}

printjson(adminDb.getUser('$MONGO_USER'));
"

# Safety check: if user still missing, STOP before enabling auth
log "Verifying admin user exists before enabling authorization..."
USER_CHECK="$(mongosh --quiet --host 127.0.0.1 --port "$PORT1" --eval "var a=db.getSiblingDB('admin'); print(!!a.getUser('$MONGO_USER'))")"
if [[ "$USER_CHECK" != "true" ]]; then
  echo "ERROR: Admin user was not created. Refusing to enable authorization."
  exit 1
fi

# ==============================
# 8) ENABLE AUTHORIZATION + RESTART
# ==============================
log "[10/10] Enabling authorization in configs + restarting"
enable_authorization_in_conf "$CONF1"
enable_authorization_in_conf "$CONF2"
enable_authorization_in_conf "$CONF3"

sudo systemctl restart mongod1 mongod2 mongod3

# After enabling auth, check ports with auth
wait_for_port_auth "$PORT1"
wait_for_port_auth "$PORT2"
wait_for_port_auth "$PORT3"
wait_for_primary_auth

# ==============================
# FINAL OUTPUT
# ==============================
log "Final checks (authenticated)"
mongosh --quiet \
  "mongodb://${MONGO_USER}:${MONGO_PASS}@127.0.0.1:${PORT1},127.0.0.1:${PORT2},127.0.0.1:${PORT3}/?replicaSet=${REPLICA_NAME}&authSource=admin" \
  --eval "db.runCommand({connectionStatus:1})" >/dev/null

echo ""
echo "===================================================="
echo "MongoDB 8 Enterprise Replica Set READY (3 instances)"
echo "Replica Set:     ${REPLICA_NAME}"
echo "Bind IP:         ${BIND_IP}"
echo "Advertised Host: ${REPL_HOST}"
echo "Ports:           ${PORT1}, ${PORT2}, ${PORT3}"
echo "Server IP:       ${SERVER_IP}"
echo "Admin User:      ${MONGO_USER}"
echo "===================================================="
echo ""
echo "LOCAL connect:"
echo "mongosh \"mongodb://${MONGO_USER}:${MONGO_PASS}@127.0.0.1:${PORT1},127.0.0.1:${PORT2},127.0.0.1:${PORT3}/?replicaSet=${REPLICA_NAME}&authSource=admin\""
echo ""
echo "REMOTE connect:"
echo "mongosh \"mongodb://${MONGO_USER}:${MONGO_PASS}@${REPL_HOST}:${PORT1},${REPL_HOST}:${PORT2},${REPL_HOST}:${PORT3}/?replicaSet=${REPLICA_NAME}&authSource=admin\""
echo ""
echo "Services:"
echo "  systemctl status mongod1"
echo "  systemctl status mongod2"
echo "  systemctl status mongod3"
echo ""
echo "Note: Ensure ${REPL_HOST} is reachable from your client network."