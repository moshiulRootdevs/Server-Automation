"use strict";

/**
 * MongoDB transaction health-check via Mongoose
 *
 * Tests:
 *  1. Successful transaction   — two writes commit atomically
 *  2. Rollback on error        — an intentional failure reverts both writes
 *  3. Replica-set requirement  — confirms the connection is a replica set
 *     (transactions are not available on standalone nodes)
 *
 * Usage:
 *   MONGO_URI="mongodb://admin:pass@host:27018,host:27019,host:27020/?replicaSet=rs0&authSource=admin" \
 *   node index.js
 */

const mongoose = require("mongoose");

// ---------------------------------------------------------------------------
// Configuration — override via env vars
// ---------------------------------------------------------------------------
const MONGO_URI =
  process.env.MONGO_URI ||
  "mongodb://admin:StrongPassword123@67.220.95.211:27018,67.220.95.211:27019,67.220.95.211:27020/?replicaSet=rs0&authSource=admin";

const DB_NAME = process.env.MONGO_DB || "txn_healthcheck";

// ---------------------------------------------------------------------------
// Mongoose models (temporary collections, dropped after the check)
// ---------------------------------------------------------------------------
const accountSchema = new mongoose.Schema(
  {
    owner: { type: String, required: true, unique: true, index: true },
    balance: { type: Number, required: true, min: 0 },
  },
  { timestamps: true },
);

const auditSchema = new mongoose.Schema(
  {
    action: { type: String, required: true },
    amount: { type: Number, required: true },
    fromOwner: { type: String, required: true },
    toOwner: { type: String, required: true },
  },
  { timestamps: true },
);

const Account = mongoose.model("TxnCheckAccount", accountSchema);
const AuditLog = mongoose.model("TxnCheckAuditLog", auditSchema);

// ---------------------------------------------------------------------------
// Core transaction function (industry-standard pattern)
// ---------------------------------------------------------------------------

/**
 * Transfer `amount` from `fromOwner` to `toOwner` within a single ACID
 * transaction.  Both the balance update and the audit-log write are atomic —
 * either both commit or both roll back.
 *
 * @param {string}  fromOwner
 * @param {string}  toOwner
 * @param {number}  amount
 * @param {object}  [options]
 * @param {boolean} [options.forceRollback=false]  Throw after writes to
 *                                                  simulate a mid-transaction
 *                                                  failure and verify rollback.
 */
async function transferFunds(fromOwner, toOwner, amount, options = {}) {
  const { forceRollback = false } = options;

  const session = await mongoose.startSession();
  session.startTransaction({
    // Read-your-own-writes consistency: majority read + majority write
    readConcern: { level: "snapshot" },
    writeConcern: { w: "majority" },
  });

  try {
    // --- debit sender ---
    const sender = await Account.findOneAndUpdate(
      { owner: fromOwner, balance: { $gte: amount } }, // guard: no overdraft
      { $inc: { balance: -amount } },
      { new: true, session },
    );

    if (!sender) {
      throw new Error(`Insufficient funds or account not found: ${fromOwner}`);
    }

    // --- credit receiver ---
    const receiver = await Account.findOneAndUpdate(
      { owner: toOwner },
      { $inc: { balance: amount } },
      { new: true, session },
    );

    if (!receiver) {
      throw new Error(`Receiver account not found: ${toOwner}`);
    }

    // --- write audit log (same transaction) ---
    await AuditLog.create(
      [{ action: "transfer", amount, fromOwner, toOwner }],
      { session },
    );

    // Intentional failure to verify rollback
    if (forceRollback) {
      throw new Error("Simulated mid-transaction failure (rollback test)");
    }

    await session.commitTransaction();
    return { sender, receiver };
  } catch (err) {
    await session.abortTransaction();
    throw err; // re-throw so the caller handles / logs it
  } finally {
    await session.endSession();
  }
}

// ---------------------------------------------------------------------------
// Health-check runner
// ---------------------------------------------------------------------------
async function runTransactionHealthCheck() {
  const results = {
    replicaSet: false,
    successfulTransaction: false,
    rollbackOnError: false,
    dataIntegrityAfterRollback: false,
  };

  // ── 1. Connect ──────────────────────────────────────────────────────────
  console.log("Connecting to MongoDB…");
  await mongoose.connect(MONGO_URI, { dbName: DB_NAME });
  console.log(`Connected  →  ${mongoose.connection.host}`);

  // ── 2. Replica-set check ─────────────────────────────────────────────────
  console.log("\n[TEST 1] Replica-set detection");
  const adminDb = mongoose.connection.db.admin();
  const hello = await adminDb.command({ hello: 1 });

  if (!hello.setName) {
    throw new Error(
      "Not connected to a replica set. " +
        "Transactions require a replica set. " +
        "Check your MONGO_URI.",
    );
  }

  results.replicaSet = true;
  console.log(`  ✓ Replica set "${hello.setName}" detected`);
  console.log(`    Primary  : ${hello.primary}`);
  console.log(`    Members  : ${(hello.hosts || []).join(", ")}`);

  // ── Seed test accounts ───────────────────────────────────────────────────
  await Account.deleteMany({});
  await AuditLog.deleteMany({});

  await Account.insertMany([
    { owner: "alice", balance: 1000 },
    { owner: "bob", balance: 500 },
  ]);

  // ── 3. Successful transaction ────────────────────────────────────────────
  console.log("\n[TEST 2] Successful transaction (alice → bob, $200)");

  const before = await Account.find().lean();
  printBalances("Before", before);

  const { sender, receiver } = await transferFunds("alice", "bob", 200);
  printBalances("After ", [sender.toObject(), receiver.toObject()]);

  const auditEntry = await AuditLog.findOne({ fromOwner: "alice" }).lean();
  if (!auditEntry) throw new Error("Audit log entry missing after commit");

  if (sender.balance !== 800 || receiver.balance !== 700) {
    throw new Error(
      `Balance mismatch: alice=${sender.balance} bob=${receiver.balance}`,
    );
  }

  results.successfulTransaction = true;
  console.log("  ✓ Balances updated correctly");
  console.log("  ✓ Audit log entry created");

  // ── 4. Rollback test ─────────────────────────────────────────────────────
  console.log(
    "\n[TEST 3] Rollback on mid-transaction error (alice → bob, $100)",
  );

  const beforeRollback = {
    alice: (await Account.findOne({ owner: "alice" }).lean()).balance,
    bob: (await Account.findOne({ owner: "bob" }).lean()).balance,
    auditCount: await AuditLog.countDocuments(),
  };
  console.log(
    `  Before: alice=${beforeRollback.alice}  bob=${beforeRollback.bob}  audits=${beforeRollback.auditCount}`,
  );

  let rollbackErrorCaught = false;
  try {
    await transferFunds("alice", "bob", 100, { forceRollback: true });
  } catch (err) {
    if (err.message.includes("Simulated mid-transaction failure")) {
      rollbackErrorCaught = true;
      console.log(`  ✓ Error caught: "${err.message}"`);
    } else {
      throw err;
    }
  }

  if (!rollbackErrorCaught) {
    throw new Error("Expected rollback error was not thrown");
  }

  results.rollbackOnError = true;

  // ── 5. Data-integrity check after rollback ───────────────────────────────
  console.log("\n[TEST 4] Data integrity after rollback");

  const afterRollback = {
    alice: (await Account.findOne({ owner: "alice" }).lean()).balance,
    bob: (await Account.findOne({ owner: "bob" }).lean()).balance,
    auditCount: await AuditLog.countDocuments(),
  };
  console.log(
    `  After : alice=${afterRollback.alice}  bob=${afterRollback.bob}  audits=${afterRollback.auditCount}`,
  );

  const balancesUnchanged =
    afterRollback.alice === beforeRollback.alice &&
    afterRollback.bob === beforeRollback.bob;

  const auditUnchanged = afterRollback.auditCount === beforeRollback.auditCount;

  if (!balancesUnchanged) {
    throw new Error(
      `Rollback FAILED — balances changed: ` +
        `alice ${beforeRollback.alice}→${afterRollback.alice}, ` +
        `bob ${beforeRollback.bob}→${afterRollback.bob}`,
    );
  }

  if (!auditUnchanged) {
    throw new Error(
      `Rollback FAILED — audit count changed: ` +
        `${beforeRollback.auditCount}→${afterRollback.auditCount}`,
    );
  }

  results.dataIntegrityAfterRollback = true;
  console.log("  ✓ Balances unchanged (transaction rolled back correctly)");
  console.log("  ✓ Audit log unchanged (partial write reverted)");

  return results;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function printBalances(label, accounts) {
  const map = Object.fromEntries(accounts.map((a) => [a.owner, a.balance]));
  const parts = Object.entries(map)
    .map(([owner, bal]) => `${owner}=${bal}`)
    .join("  ");
  console.log(`  ${label}: ${parts}`);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
(async () => {
  let exitCode = 0;

  try {
    const results = await runTransactionHealthCheck();

    console.log("\n══════════════════════════════════════════");
    console.log(" TRANSACTION HEALTH-CHECK RESULTS");
    console.log("══════════════════════════════════════════");
    for (const [test, passed] of Object.entries(results)) {
      const icon = passed ? "✓" : "✗";
      console.log(`  ${icon}  ${test}`);
    }

    const allPassed = Object.values(results).every(Boolean);
    console.log("──────────────────────────────────────────");
    console.log(allPassed ? "  ALL TESTS PASSED" : "  SOME TESTS FAILED");
    console.log("══════════════════════════════════════════\n");

    exitCode = allPassed ? 0 : 1;
  } catch (err) {
    console.error("\n[FATAL]", err.message);
    exitCode = 2;
  } finally {
    // Clean up test collections regardless of outcome
    try {
      await Account.collection.drop();
      await AuditLog.collection.drop();
    } catch (_) {
      // collections may not exist on a fatal-path exit — ignore
    }
    await mongoose.disconnect();
    process.exit(exitCode);
  }
})();
