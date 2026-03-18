# BSV Paymaster

On-chain gas sponsorship for Bitcoin SV — a covenant-based alternative to Ethereum's ERC-4337 paymasters.

## What This Is

A [Runar](https://github.com/icellan/runar) smart contract that holds a balance of satoshis and lets an authorized spender draw from it, subject to per-transaction limits. All spending rules are covenant-enforced in Bitcoin Script.

## How It Compares

| | ERC-4337 Paymaster (Ethereum) | BSV Paymaster (this) | Droplit (hosted) |
|---|---|---|---|
| **Trust model** | Trustless (on-chain contract) | Trustless (on-chain covenant) | Custodial (hosted wallet) |
| **Cost per sponsored tx** | ~$0.50-5.00 gas + validation | < $0.001 (BSV fee) | < $0.001 (BSV fee) |
| **Infrastructure** | Bundler + EntryPoint + staking | Just the UTXO | API server + wallet |
| **Validation overhead** | On-chain gas for every check | Zero (rules in locking script) | Off-chain API |
| **Key rotation** | Redeploy contract | `updateSpender` method | API key rotation |
| **Rate limiting** | Custom contract logic | `maxPerTx` field | API-level |
| **Script size** | N/A (EVM bytecode) | ~500 bytes Bitcoin Script | N/A |

## Contract

`Paymaster.runar.zig` — a `StatefulSmartContract` with 5 methods:

| Method | Who | What |
|--------|-----|------|
| `deposit` | Owner | Add funds to the paymaster |
| `sponsor` | Authorized spender | Draw funds to sponsor a transaction |
| `withdraw` | Owner | Reclaim funds |
| `updateSpender` | Owner | Rotate the authorized spender key |
| `updateLimit` | Owner | Adjust the per-transaction cap |

### State Fields

| Field | Type | Description |
|-------|------|-------------|
| `owner` | PubKey | Owner's public key (immutable) |
| `balance` | i64 | Current satoshi balance |
| `maxPerTx` | i64 | Maximum satoshis per sponsored transaction |
| `spenderPkh` | Addr | Authorized spender's pubkey hash |

## Build & Test

```bash
zig build test
```

Requires `runar-zig` (resolved via `build.zig.zon` local path dependency).

## How It Works

1. **Deploy**: Owner creates the paymaster UTXO with initial balance and config
2. **Sponsor**: App/agent calls `sponsor` with the spender key — covenant enforces the limit and deducts from balance
3. **Continue**: The contract UTXO continues with the updated balance (stateful covenant)
4. **Manage**: Owner can deposit more, withdraw, rotate spender keys, or adjust limits — all on-chain

The locking script enforces all rules. No server, no API, no trust assumptions beyond the Bitcoin network itself.

## License

MIT
