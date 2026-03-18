const runar = @import("runar");

/// BSV Paymaster — on-chain gas sponsorship via covenant UTXO.
///
/// ## How it works
///
/// The paymaster is a single UTXO locked by this contract's Bitcoin Script.
/// When someone wants to spend from it, they build a transaction that:
///
///   1. Spends the paymaster UTXO as input (providing the method args in scriptSig)
///   2. Creates a continuation output with the same locking script but updated state
///   3. Optionally creates additional outputs (payouts, change, etc.)
///
/// The locking script enforces all the rules — who can spend, how much,
/// and that the continuation output has the correct decremented balance.
/// This is called a "covenant" because the script constrains its own future.
///
/// ## Transaction structure
///
/// Deploy (create the paymaster):
///
///   Input 0:  Funding UTXO (any source)
///   Output 0: [paymaster locking script + initial state] (holds the balance)
///   Output 1: Change
///
/// Sponsor (spender draws funds):
///
///   Input 0:  Paymaster UTXO (scriptSig: <sig> <pubkey> <amount> <method_index>)
///   Output 0: Paymaster continuation (same script, balance -= amount)
///   Output 1: Change to wherever the spender directs it
///
/// Withdraw (owner reclaims):
///
///   Input 0:  Paymaster UTXO (scriptSig: <owner_sig> <amount> <method_index>)
///   Output 0: Paymaster continuation (same script, balance -= amount)
///   Output 1: P2PKH to owner's address
///
/// ## State encoding
///
/// The contract state (balance, maxPerTx, spenderPkh) is serialized into
/// the locking script as push-data constants. Each method call produces a
/// new UTXO with updated state baked into the script. The Runar compiler
/// handles this automatically via the StatefulSmartContract model.
///
/// ## Comparison to ERC-4337
///
/// On Ethereum, paymasters require:
///   - A deployed EntryPoint contract ($$$)
///   - ETH staked as anti-griefing deposit
///   - A bundler to relay UserOperations
///   - Gas for validatePaymasterUserOp on every sponsored tx
///
/// On BSV, this contract:
///   - Compiles to ~500 bytes of Bitcoin Script
///   - Costs < 0.001 USD per transaction
///   - Needs no infrastructure beyond the Bitcoin network
///   - Enforces all rules in the locking script itself
pub const Paymaster = struct {
    pub const Contract = runar.StatefulSmartContract;

    /// Owner's compressed public key (33 bytes).
    /// Only the owner can deposit, withdraw, and update configuration.
    /// This field is immutable — to change ownership, deploy a new paymaster.
    owner: runar.PubKey,

    /// Current balance in satoshis.
    /// Incremented by deposit(), decremented by sponsor() and withdraw().
    /// The covenant enforces that the continuation output carries the
    /// correct updated balance — the spender cannot lie about it.
    balance: i64 = 0,

    /// Maximum satoshis allowed per sponsored transaction.
    /// Prevents a compromised spender key from draining the entire balance
    /// in a single transaction. Can be updated by the owner.
    maxPerTx: i64,

    /// HASH160 of the authorized spender's public key (20 bytes).
    /// We store the hash rather than the full pubkey so the spender can
    /// rotate their actual key without an on-chain update — as long as
    /// the new key hashes to the same value. In practice, the owner
    /// calls updateSpender() to authorize a new key.
    spenderPkh: runar.Addr,

    /// Constructor — sets initial state when deploying the paymaster.
    ///
    /// Typical deploy: owner funds with 1,000,000 sats, sets max 50,000
    /// per tx, and authorizes their app's API key as spender.
    pub fn init(
        owner: runar.PubKey,
        balance: i64,
        maxPerTx: i64,
        spenderPkh: runar.Addr,
    ) Paymaster {
        return .{
            .owner = owner,
            .balance = balance,
            .maxPerTx = maxPerTx,
            .spenderPkh = spenderPkh,
        };
    }

    /// Deposit — owner adds more satoshis to the paymaster.
    ///
    /// The amount is a logical value tracked in the contract state.
    /// The actual satoshis must be provided in the transaction's
    /// output value. The covenant ensures the state and output match.
    ///
    /// Compiled Bitcoin Script (simplified):
    ///   <sig> <owner_pubkey> OP_CHECKSIGVERIFY
    ///   <amount> OP_0 OP_GREATERTHAN OP_VERIFY
    ///   <old_balance> <amount> OP_ADD → new_balance
    pub fn deposit(self: *Paymaster, sig: runar.Sig, amount: i64) void {
        // Only the owner can deposit — verified via ECDSA signature
        runar.assert(runar.checkSig(sig, self.owner));
        // Must deposit a positive amount
        runar.assert(amount > 0);
        // Update the balance in contract state
        self.balance = self.balance + amount;
    }

    /// Sponsor — authorized spender draws funds to pay for someone's transaction.
    ///
    /// This is the core paymaster operation. The spender proves authorization
    /// via their public key (which must hash to spenderPkh), then draws up
    /// to maxPerTx satoshis from the balance.
    ///
    /// The covenant ensures:
    ///   1. The spender's pubkey hashes to the stored spenderPkh
    ///   2. The spender's signature is valid (CHECKSIG)
    ///   3. The amount is positive and within limits
    ///   4. The continuation output has balance decremented by exactly amount
    ///
    /// Compiled Bitcoin Script (simplified):
    ///   <sig> <pubkey> <amount>
    ///   OP_OVER OP_HASH160 <spenderPkh> OP_EQUALVERIFY  // check pubkey hash
    ///   OP_ROT OP_ROT OP_CHECKSIGVERIFY                  // check signature
    ///   OP_DUP OP_0 OP_GREATERTHAN OP_VERIFY             // amount > 0
    ///   OP_DUP <maxPerTx> OP_LESSTHANOREQUAL OP_VERIFY   // amount <= maxPerTx
    ///   OP_DUP <balance> OP_LESSTHANOREQUAL OP_VERIFY    // amount <= balance
    ///   <balance> OP_SWAP OP_SUB → new_balance            // balance -= amount
    pub fn sponsor(
        self: *Paymaster,
        sig: runar.Sig,
        pubKey: runar.PubKey,
        amount: i64,
    ) void {
        // Verify spender is authorized: their pubkey must hash to spenderPkh.
        // This is like P2PKH but for the delegated spender, not the owner.
        runar.assert(runar.bytesEq(runar.hash160(pubKey), self.spenderPkh));
        // Verify the spender actually signed this transaction
        runar.assert(runar.checkSig(sig, pubKey));

        // Enforce spending rules — these compile to simple OP_GREATERTHAN
        // and OP_LESSTHANOREQUAL checks in Bitcoin Script
        runar.assert(amount > 0);
        runar.assert(amount <= self.maxPerTx);
        runar.assert(amount <= self.balance);

        // Deduct from balance. The covenant ensures the continuation
        // output carries this exact new balance in its state.
        self.balance = self.balance - amount;
    }

    /// Withdraw — owner reclaims funds from the paymaster.
    ///
    /// Same authorization as deposit (owner signature), but decrements
    /// the balance instead of incrementing it. The withdrawn satoshis
    /// go to whatever output the owner constructs in the transaction.
    pub fn withdraw(self: *Paymaster, sig: runar.Sig, amount: i64) void {
        runar.assert(runar.checkSig(sig, self.owner));
        runar.assert(amount > 0);
        runar.assert(amount <= self.balance);
        self.balance = self.balance - amount;
    }

    /// Update spender — owner rotates the authorized spender key.
    ///
    /// Useful when an API key is compromised or when transferring
    /// sponsorship authority to a new service. No need to redeploy
    /// the contract or move funds — just update the hash.
    pub fn updateSpender(self: *Paymaster, sig: runar.Sig, newSpenderPkh: runar.Addr) void {
        runar.assert(runar.checkSig(sig, self.owner));
        self.spenderPkh = newSpenderPkh;
    }

    /// Update limit — owner adjusts the per-transaction cap.
    ///
    /// Can increase or decrease the limit. Setting it higher lets
    /// the spender fund larger transactions; setting it lower
    /// reduces risk if the spender key is compromised.
    pub fn updateLimit(self: *Paymaster, sig: runar.Sig, newMaxPerTx: i64) void {
        runar.assert(runar.checkSig(sig, self.owner));
        runar.assert(newMaxPerTx > 0);
        self.maxPerTx = newMaxPerTx;
    }
};
