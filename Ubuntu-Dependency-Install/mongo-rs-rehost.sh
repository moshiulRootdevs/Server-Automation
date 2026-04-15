#!/bin/bash
set -euo pipefail

# ============================================================
# mongo-rs-rehost.sh
#
# Run this ON THE SERVER when remote clients can't connect.
# Root cause: RS members were initialized advertising a private
# or loopback IP. This script reconfigures them to advertise
# the correct public IP so remote clients can reach the primary.
#
# Usage (run on the server as a user with sudo):
#   sudo bash mongo-rs-rehost.sh
#
# Or with explicit values:
#   PUBLIC_IP=67.220.95.211 MONGO_PASS=mypass bash mongo-rs-rehost.sh
# ============================================================

MONGO_USER="${MONGO_USER:-admin}"
MONGO_PASS="${MONGO_PASS:-StrongPassword123}"
REPLICA_NAME="${REPLICA_NAME:-rs0}"
PORT1="${PORT1:-27018}"
PORT2="${PORT2:-27019}"
PORT3="${PORT3:-27020}"

# Detect public IP automatically, fall back to first interface IP
PUBLIC_IP="${PUBLIC_IP:-$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"

log() { echo -e "\n==> $*\n"; }

# ── 1. Show current RS config ──────────────────────────────────────────────
log "[1/3] Current replica set member hosts"
mongosh --quiet --host 127.0.0.1 --port "$PORT1" \
  -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
  --eval "
var cfg = rs.conf();
cfg.members.forEach(function(m) { print('  _id=' + m._id + '  host=' + m.host); });
"

# ── 2. Reconfigure RS members to advertise PUBLIC_IP ──────────────────────
log "[2/3] Reconfiguring RS members → ${PUBLIC_IP}:${PORT1}, ${PUBLIC_IP}:${PORT2}, ${PUBLIC_IP}:${PORT3}"
mongosh --quiet --host 127.0.0.1 --port "$PORT1" \
  -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
  --eval "
var cfg = rs.conf();

// Update all three member hosts
cfg.members[0].host = '${PUBLIC_IP}:${PORT1}';
cfg.members[1].host = '${PUBLIC_IP}:${PORT2}';
cfg.members[2].host = '${PUBLIC_IP}:${PORT3}';

// force:true allows reconfig even when the set can't reach the old hosts
rs.reconfig(cfg, { force: true });
print('Reconfig submitted.');
"

# Wait for the set to stabilise after reconfig
echo "Waiting for RS to stabilise (up to 30s)..."
for i in {1..30}; do
  STATE="$(mongosh --quiet --host 127.0.0.1 --port "$PORT1" \
    -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
    --eval "db.hello().isWritablePrimary" 2>/dev/null | tail -1 || echo "false")"
  if [[ "$STATE" == "true" ]]; then
    break
  fi
  sleep 1
done

# ── 3. Show updated config ─────────────────────────────────────────────────
log "[3/3] Updated replica set member hosts"
mongosh --quiet --host 127.0.0.1 --port "$PORT1" \
  -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
  --eval "
var cfg = rs.conf();
cfg.members.forEach(function(m) { print('  _id=' + m._id + '  host=' + m.host); });
print('');
var hello = db.hello();
print('Primary        : ' + hello.primary);
print('isWritablePrimary: ' + hello.isWritablePrimary);
"

echo ""
echo "=============================================="
echo " RS rehost complete. Test remote connection:"
echo ""
echo " mongosh \"mongodb://${MONGO_USER}:${MONGO_PASS}@${PUBLIC_IP}:${PORT1},${PUBLIC_IP}:${PORT2},${PUBLIC_IP}:${PORT3}/?replicaSet=${REPLICA_NAME}&authSource=admin\""
echo "=============================================="
