#!/bin/bash
set -euo pipefail

# ============================================================
# MongoDB 8 Enterprise - 3-instance replica set on ONE server
# Ubuntu 24.04 (Noble)
#
# What this does:
#  1) Installs MongoDB Enterprise 8.0
#  2) Creates 3 mongod instances (ports 27018/27019/27020)
#  3) Initializes replica set (members advertise ADVERTISED_HOST)
#  4) Creates the first admin user via localhost exception
#  5) Enables authorization only AFTER user exists
#  6) Opens firewall ports (optionally restricted by IP)
#
# IMPORTANT:
#  - ADVERTISED_HOST must be reachable from remote clients
#    (set to public IP or DNS name of this server)
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

# Address replica set members advertise to clients.
# MUST be reachable from your application servers.
# Use your server's public IP or a DNS name.
ADVERTISED_HOST="$(hostname -I | awk '{print $1}')"

# Optional: restrict firewall to a specific IP (recommended).
# Leave empty "" to allow from anywhere.
# Example: ALLOW_FROM_IP="203.0.113.50"
ALLOW_FROM_IP=""

# MongoDB apt repo (MongoDB 8.0 Enterprise, Ubuntu 24.04 Noble)
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

# Wait for mongod to respond on a port (no auth — used before auth is enabled)
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

# Wait for mongod to respond on a port (with auth — used after auth is enabled)
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
  echo "Hint: admin user may not exist or credentials are wrong."
  exit 1
}

# Wait for PRIMARY election (no auth)
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

# Wait for PRIMARY election (with auth)
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

# Write mongod config (keyFile only — authorization enabled implicitly by MongoDB
# when keyFile is present; localhost exception allows first-user creation)
write_conf() {
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

# Add explicit authorization: enabled to a config (idempotent)
enable_auth_in_conf() {
  local conf="$1"
  # Only add if not already present
  if ! sudo grep -q "authorization: enabled" "$conf"; then
    sudo sed -i '/^security:/a\  authorization: enabled' "$conf"
  fi
}

# Create a systemd service for a mongod instance
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
log "[1/10] Installing dependencies + adding MongoDB repo"
sudo apt-get update
sudo apt-get install -y gnupg curl ufw

curl -fsSL https://pgp.mongodb.com/server-8.0.asc \
  | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

echo "$MONGO_REPO_LINE" | sudo tee /etc/apt/sources.list.d/mongodb-enterprise-8.0.list >/dev/null

sudo apt-get update
log "[2/10] Installing MongoDB Enterprise 8.0"
sudo apt-get install -y mongodb-enterprise

# Disable the default mongod service — we use custom instances instead
sudo systemctl disable mongod 2>/dev/null || true
sudo systemctl stop mongod 2>/dev/null || true

# ==============================
# 2) DIRECTORIES + KEYFILE
# ==============================
log "[3/10] Creating data/log directories"
sudo mkdir -p "$DATA1" "$DATA2" "$DATA3"
sudo mkdir -p "$LOGDIR1" "$LOGDIR2" "$LOGDIR3"
sudo chown -R mongodb:mongodb "$DATA1" "$DATA2" "$DATA3" \
  "$LOGDIR1" "$LOGDIR2" "$LOGDIR3"

log "[4/10] Creating keyfile for internal replica set auth"
if [[ ! -f "$KEYFILE" ]]; then
  sudo openssl rand -base64 756 | sudo tee "$KEYFILE" >/dev/null
  sudo chmod 400 "$KEYFILE"
  sudo chown mongodb:mongodb "$KEYFILE"
fi

# ==============================
# 3) WRITE CONFIGS
# ==============================
log "[5/10] Writing mongod configs (auth enabled via keyFile)"
write_conf "$CONF1" "$DATA1" "$LOG1" "$PORT1"
write_conf "$CONF2" "$DATA2" "$LOG2" "$PORT2"
write_conf "$CONF3" "$DATA3" "$LOG3" "$PORT3"

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
# 6) INITIALIZE REPLICA SET
# ==============================
log "[8/10] Initializing replica set (idempotent)"
# Members advertise REPL_HOST so remote clients can reach them.
# 3 members = proper majority voting for automatic failover.
mongosh --quiet --host 127.0.0.1 --port "$PORT1" --eval "
try {
  var s = rs.status();
  print('Replica set already initialized: ' + s.set);
} catch (e) {
  print('Initiating replica set...');
  rs.initiate({
    _id: '$REPLICA_NAME',
    members: [
      { _id: 0, host: '${REPL_HOST}:${PORT1}' },
      { _id: 1, host: '${REPL_HOST}:${PORT2}' },
      { _id: 2, host: '${REPL_HOST}:${PORT3}' }
    ]
  });
  print('Replica set initiated.');
}
"

wait_for_primary_noauth

# ==============================
# 7) CREATE ADMIN USER
# ==============================
log "[9/10] Creating admin user if missing (localhost exception)"
# keyFile enables auth but the localhost exception allows first-user creation
# when connecting from 127.0.0.1 and no users exist in admin yet.
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
"

# Safety check: refuse to restart with auth if user doesn't exist
log "Verifying admin user exists before enforcing authorization..."
USER_CHECK="$(mongosh --quiet --host 127.0.0.1 --port "$PORT1" \
  --eval "print(!!db.getSiblingDB('admin').getUser('$MONGO_USER'))" 2>/dev/null || echo "false")"
if [[ "$USER_CHECK" != "true" ]]; then
  echo "ERROR: Admin user was not created. Refusing to enable authorization."
  echo "Check mongod logs: sudo journalctl -u mongod1 -n 50"
  exit 1
fi

# ==============================
# 8) ENABLE EXPLICIT AUTHORIZATION + RESTART
# ==============================
log "[10/10] Enabling explicit authorization in configs + restarting"
enable_auth_in_conf "$CONF1"
enable_auth_in_conf "$CONF2"
enable_auth_in_conf "$CONF3"

sudo systemctl restart mongod1 mongod2 mongod3

# After restart, all connections require credentials
wait_for_port_auth "$PORT1"
wait_for_port_auth "$PORT2"
wait_for_port_auth "$PORT3"
wait_for_primary_auth

# ==============================
# FINAL VERIFICATION
# ==============================
log "Final connection check (authenticated)"
mongosh --quiet \
  "mongodb://${MONGO_USER}:${MONGO_PASS}@127.0.0.1:${PORT1},127.0.0.1:${PORT2},127.0.0.1:${PORT3}/?replicaSet=${REPLICA_NAME}&authSource=admin" \
  --eval "db.runCommand({connectionStatus:1})" >/dev/null

echo ""
echo "===================================================="
echo " MongoDB 8 Enterprise Replica Set READY"
echo "===================================================="
echo " Replica Set:     ${REPLICA_NAME}"
echo " Bind IP:         ${BIND_IP}"
echo " Advertised Host: ${REPL_HOST}"
echo " Ports:           ${PORT1}, ${PORT2}, ${PORT3}"
echo " Server IP:       ${SERVER_IP}"
echo " Admin User:      ${MONGO_USER}"
echo "===================================================="
echo ""
echo "LOCAL connect (replica-aware):"
echo "mongosh \"mongodb://${MONGO_USER}:${MONGO_PASS}@127.0.0.1:${PORT1},127.0.0.1:${PORT2},127.0.0.1:${PORT3}/?replicaSet=${REPLICA_NAME}&authSource=admin\""
echo ""
echo "REMOTE connect:"
echo "mongosh \"mongodb://${MONGO_USER}:${MONGO_PASS}@${REPL_HOST}:${PORT1},${REPL_HOST}:${PORT2},${REPL_HOST}:${PORT3}/?replicaSet=${REPLICA_NAME}&authSource=admin\""
echo ""
echo "Service management:"
echo "  systemctl status mongod1 mongod2 mongod3"
echo "  systemctl restart mongod1 mongod2 mongod3"
echo ""
echo "Logs:"
echo "  sudo journalctl -u mongod1 -f"
echo "  sudo tail -f ${LOG1}"
echo ""
echo "Note: Ensure ${REPL_HOST} is reachable from your application servers."
