const std = @import("std");
const runar = @import("runar");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Ripemd160 = std.crypto.hash.ripemd160.Ripemd160;

// Compile-check: verify the contract passes the Runar frontend pipeline.
test "compile-check Paymaster.runar.zig" {
    const source = @embedFile("Paymaster.runar.zig");
    const result = try runar.compileCheckSource(
        std.testing.allocator,
        source,
        "Paymaster.runar.zig",
    );
    defer result.deinit(std.testing.allocator);

    if (!result.ok()) {
        for (result.messages) |message| {
            std.debug.print("compile-check: {s}\n", .{message});
        }
    }
    try std.testing.expect(result.ok());
}

// Mirror struct for testing contract logic in valid Zig.
// This reimplements the Paymaster's business rules without DSL semantics.
const MirrorPaymaster = struct {
    owner_pkh: [20]u8,
    balance: i64,
    max_per_tx: i64,
    spender_pkh: [20]u8,

    const Error = error{
        Unauthorized,
        InvalidAmount,
        ExceedsLimit,
        InsufficientBalance,
    };

    fn init(owner: [20]u8, balance: i64, max_per_tx: i64, spender: [20]u8) MirrorPaymaster {
        return .{
            .owner_pkh = owner,
            .balance = balance,
            .max_per_tx = max_per_tx,
            .spender_pkh = spender,
        };
    }

    fn deposit(self: *MirrorPaymaster, is_owner: bool, amount: i64) Error!void {
        if (!is_owner) return error.Unauthorized;
        if (amount <= 0) return error.InvalidAmount;
        self.balance += amount;
    }

    fn sponsor(self: *MirrorPaymaster, spender_hash: [20]u8, amount: i64) Error!void {
        if (!std.mem.eql(u8, &spender_hash, &self.spender_pkh)) return error.Unauthorized;
        if (amount <= 0) return error.InvalidAmount;
        if (amount > self.max_per_tx) return error.ExceedsLimit;
        if (amount > self.balance) return error.InsufficientBalance;
        self.balance -= amount;
    }

    fn withdraw(self: *MirrorPaymaster, is_owner: bool, amount: i64) Error!void {
        if (!is_owner) return error.Unauthorized;
        if (amount <= 0) return error.InvalidAmount;
        if (amount > self.balance) return error.InsufficientBalance;
        self.balance -= amount;
    }

    fn updateSpender(self: *MirrorPaymaster, is_owner: bool, new_pkh: [20]u8) Error!void {
        if (!is_owner) return error.Unauthorized;
        self.spender_pkh = new_pkh;
    }

    fn updateLimit(self: *MirrorPaymaster, is_owner: bool, new_limit: i64) Error!void {
        if (!is_owner) return error.Unauthorized;
        if (new_limit <= 0) return error.InvalidAmount;
        self.max_per_tx = new_limit;
    }
};

fn hash160(data: []const u8) [20]u8 {
    var sha_out: [32]u8 = undefined;
    Sha256.hash(data, &sha_out, .{});
    var ripe_out: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &ripe_out, .{});
    return ripe_out;
}

// Deterministic test keys — distinct fixed byte patterns to avoid comptime hash
const owner_pkh = [_]u8{0x01} ** 20;
const spender_pkh = [_]u8{0x02} ** 20;
const other_pkh = [_]u8{0x03} ** 20;

test "paymaster init stores all fields" {
    const pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try std.testing.expectEqual(@as(i64, 100_000), pm.balance);
    try std.testing.expectEqual(@as(i64, 10_000), pm.max_per_tx);
    try std.testing.expect(std.mem.eql(u8, &owner_pkh, &pm.owner_pkh));
    try std.testing.expect(std.mem.eql(u8, &spender_pkh, &pm.spender_pkh));
}

test "owner can deposit funds" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try pm.deposit(true, 50_000);
    try std.testing.expectEqual(@as(i64, 150_000), pm.balance);
}

test "non-owner cannot deposit" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try std.testing.expectError(error.Unauthorized, pm.deposit(false, 50_000));
}

test "deposit rejects zero or negative amount" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try std.testing.expectError(error.InvalidAmount, pm.deposit(true, 0));
    try std.testing.expectError(error.InvalidAmount, pm.deposit(true, -1));
}

test "authorized spender can sponsor within limits" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try pm.sponsor(spender_pkh, 5_000);
    try std.testing.expectEqual(@as(i64, 95_000), pm.balance);
}

test "spender can sponsor up to max per tx" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try pm.sponsor(spender_pkh, 10_000);
    try std.testing.expectEqual(@as(i64, 90_000), pm.balance);
}

test "spender cannot exceed max per tx" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try std.testing.expectError(error.ExceedsLimit, pm.sponsor(spender_pkh, 10_001));
}

test "spender cannot exceed balance" {
    var pm = MirrorPaymaster.init(owner_pkh, 5_000, 10_000, spender_pkh);
    try std.testing.expectError(error.InsufficientBalance, pm.sponsor(spender_pkh, 6_000));
}

test "unauthorized key cannot sponsor" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try std.testing.expectError(error.Unauthorized, pm.sponsor(other_pkh, 5_000));
}

test "multiple sponsorships drain balance correctly" {
    var pm = MirrorPaymaster.init(owner_pkh, 30_000, 10_000, spender_pkh);
    try pm.sponsor(spender_pkh, 10_000);
    try pm.sponsor(spender_pkh, 10_000);
    try pm.sponsor(spender_pkh, 10_000);
    try std.testing.expectEqual(@as(i64, 0), pm.balance);
    try std.testing.expectError(error.InsufficientBalance, pm.sponsor(spender_pkh, 1));
}

test "owner can withdraw" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try pm.withdraw(true, 60_000);
    try std.testing.expectEqual(@as(i64, 40_000), pm.balance);
}

test "owner cannot withdraw more than balance" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try std.testing.expectError(error.InsufficientBalance, pm.withdraw(true, 100_001));
}

test "owner can update spender" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try pm.updateSpender(true, other_pkh);
    // Old spender no longer authorized
    try std.testing.expectError(error.Unauthorized, pm.sponsor(spender_pkh, 5_000));
    // New spender works
    try pm.sponsor(other_pkh, 5_000);
    try std.testing.expectEqual(@as(i64, 95_000), pm.balance);
}

test "owner can update limit" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try pm.updateLimit(true, 50_000);
    // Can now sponsor up to new limit
    try pm.sponsor(spender_pkh, 50_000);
    try std.testing.expectEqual(@as(i64, 50_000), pm.balance);
}

test "non-owner cannot update spender or limit" {
    var pm = MirrorPaymaster.init(owner_pkh, 100_000, 10_000, spender_pkh);
    try std.testing.expectError(error.Unauthorized, pm.updateSpender(false, other_pkh));
    try std.testing.expectError(error.Unauthorized, pm.updateLimit(false, 50_000));
}

test "deposit then sponsor then withdraw lifecycle" {
    var pm = MirrorPaymaster.init(owner_pkh, 0, 10_000, spender_pkh);

    // Start empty — can't sponsor
    try std.testing.expectError(error.InsufficientBalance, pm.sponsor(spender_pkh, 1_000));

    // Owner deposits
    try pm.deposit(true, 50_000);
    try std.testing.expectEqual(@as(i64, 50_000), pm.balance);

    // Spender sponsors 3 transactions
    try pm.sponsor(spender_pkh, 8_000);
    try pm.sponsor(spender_pkh, 8_000);
    try pm.sponsor(spender_pkh, 8_000);
    try std.testing.expectEqual(@as(i64, 26_000), pm.balance);

    // Owner withdraws remainder
    try pm.withdraw(true, 26_000);
    try std.testing.expectEqual(@as(i64, 0), pm.balance);
}
