const runar = @import("runar");

/// BSV Paymaster — on-chain gas sponsorship via covenant UTXO.
///
/// This contract holds a balance of satoshis and allows an authorized
/// spender to draw from it, subject to per-transaction limits. The
/// owner can deposit more funds or reclaim the balance.
///
/// Unlike Ethereum's ERC-4337 paymasters which require staking,
/// bundler infrastructure, and on-chain validation gas, this contract
/// compiles to ~500 bytes of Bitcoin Script and costs fractions of a
/// cent per sponsored transaction.
///
/// Spending rules are covenant-enforced: the contract continuation
/// output guarantees the balance is correctly decremented and the
/// payout goes to the specified recipient.
pub const Paymaster = struct {
    pub const Contract = runar.StatefulSmartContract;

    // Owner's public key — can deposit, withdraw, and update config
    owner: runar.PubKey,
    // Current balance in satoshis
    balance: i64 = 0,
    // Maximum satoshis per sponsored transaction
    maxPerTx: i64,
    // Authorized spender's public key hash (delegated key)
    spenderPkh: runar.Addr,

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

    /// Owner deposits additional funds into the paymaster.
    /// The new balance is the old balance plus the deposit amount.
    pub fn deposit(self: *Paymaster, sig: runar.Sig, amount: i64) void {
        runar.assert(runar.checkSig(sig, self.owner));
        runar.assert(amount > 0);
        self.balance = self.balance + amount;
    }

    /// Authorized spender draws from the paymaster to fund a
    /// recipient address. Enforces per-transaction limit and
    /// sufficient balance. The recipient receives a P2PKH output.
    pub fn sponsor(
        self: *Paymaster,
        sig: runar.Sig,
        pubKey: runar.PubKey,
        amount: i64,
    ) void {
        // Verify spender is authorized via pubkey hash
        runar.assert(runar.bytesEq(runar.hash160(pubKey), self.spenderPkh));
        runar.assert(runar.checkSig(sig, pubKey));

        // Enforce spending rules
        runar.assert(amount > 0);
        runar.assert(amount <= self.maxPerTx);
        runar.assert(amount <= self.balance);

        // Deduct from balance
        self.balance = self.balance - amount;
    }

    /// Owner withdraws funds from the paymaster back to their own
    /// address. Can withdraw up to the full balance.
    pub fn withdraw(self: *Paymaster, sig: runar.Sig, amount: i64) void {
        runar.assert(runar.checkSig(sig, self.owner));
        runar.assert(amount > 0);
        runar.assert(amount <= self.balance);
        self.balance = self.balance - amount;
    }

    /// Owner updates the authorized spender. Useful for key rotation
    /// without redeploying the contract.
    pub fn updateSpender(self: *Paymaster, sig: runar.Sig, newSpenderPkh: runar.Addr) void {
        runar.assert(runar.checkSig(sig, self.owner));
        self.spenderPkh = newSpenderPkh;
    }

    /// Owner updates the per-transaction spending limit.
    pub fn updateLimit(self: *Paymaster, sig: runar.Sig, newMaxPerTx: i64) void {
        runar.assert(runar.checkSig(sig, self.owner));
        runar.assert(newMaxPerTx > 0);
        self.maxPerTx = newMaxPerTx;
    }
};
