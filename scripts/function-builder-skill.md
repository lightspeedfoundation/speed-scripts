# Speed CLI — Function Builder Skill

Complete reference for building `.ps1` or `.sh` automation scripts using the `speed` CLI.
Every command, flag, output format, token alias, chain alias, and scripting pattern is documented here.

---

## Table of Contents

1. [Global Flags](#1-global-flags)
2. [Environment Variables](#2-environment-variables)
3. [Chain Reference](#3-chain-reference)
4. [Token Aliases](#4-token-aliases)
5. [Commands](#5-commands)
   - [whoami](#whoami)
   - [balance](#balance)
   - [price](#price)
   - [quote](#quote)
   - [swap](#swap)
   - [gas](#gas)
   - [send](#send)
   - [bridge](#bridge)
   - [status](#status)
   - [estimate](#estimate)
   - [dca](#dca)
   - [volume](#volume)
   - [history](#history)
   - [pending](#pending)
   - [allowance](#allowance)
   - [approve](#approve)
   - [revoke](#revoke)
   - [xp](#xp)
   - [config](#config)
6. [JSON Mode — Parsing Output in Scripts](#6-json-mode--parsing-output-in-scripts)
7. [Decimal Handling](#7-decimal-handling)
8. [RPC Endpoints](#8-rpc-endpoints)
9. [Auto-Detecting Token Decimals via RPC](#9-auto-detecting-token-decimals-via-rpc)
10. [PowerShell Patterns](#10-powershell-patterns)
11. [Bash Patterns](#11-bash-patterns)
12. [Common Pitfalls](#12-common-pitfalls)

---

## 1. Global Flags

These flags apply to **every** command and are placed **before** the subcommand name.

| Flag | Short | Description |
|---|---|---|
| `--json` | | Machine-readable JSON output to stdout. All scripts should use this. |
| `--yes` | `-y` | Skip confirmation prompts (required for non-interactive scripts). |

```
speed --json --yes swap -c base -a 0.001
speed --json balance -c base
```

---

## 2. Environment Variables

Set these before running any command. Put them in a `.env` file in the project root or export them in the shell.

| Variable | Required | Description |
|---|---|---|
| `PRIVATE_KEY` | Yes | Hex private key (with or without `0x` prefix). |
| `ZEROX_API_KEY` | Yes | 0x Swap API key (required for swap/quote/gas/volume/dca). |
| `ALCHEMY_API_KEY` | No | Alchemy key — upgrades public RPCs; enables `history` and `pending`. |
| `SQUID_INTEGRATOR_ID` | No | Required for `bridge` and `status --request-id`. |
| `RPC_URL` | No | Custom RPC override for Base (chain 8453) only. |
| `OPENSEA_API_KEY` | No | Required for SANS NFT listing features only. |

---

## 3. Chain Reference

All commands accept `-c / --chain` as either an **ID** or a **name**.

| Name aliases | Chain ID | Native token | Explorer |
|---|---|---|---|
| `base` | `8453` | ETH | basescan.org |
| `ethereum`, `eth`, `mainnet` | `1` | ETH | etherscan.io |
| `optimism`, `op` | `10` | ETH | optimistic.etherscan.io |
| `arbitrum`, `arb` | `42161` | ETH | arbiscan.io |
| `polygon`, `matic` | `137` | MATIC | polygonscan.com |
| `bnb`, `bsc` | `56` | BNB | bscscan.com |

Default chain when `-c` is omitted: **Base (8453)** (or whatever is set via `speed config set default-chain`).

---

## 4. Token Aliases

These shorthands are accepted by `--sell`, `--buy`, `--token` on all commands:

| Alias | Resolves to |
|---|---|
| `speed` | `0xB01CF1bE9568f09449382a47Cd5bF58e2A9D5922` (same on all chains) |
| `eth`, `ether`, `native` | `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` (0x native sentinel) |
| Any `0x...` address | Used as-is |

**Defaults when omitted:**
- `swap`: sell = ETH, buy = SPEED
- `dca`: token = SPEED
- `volume`: token = SPEED
- `gas`: token = wrapped native (WETH/WBNB/WPOL)

---

## 5. Commands

---

### whoami

Print the wallet address derived from `PRIVATE_KEY`. No transaction.

```
speed whoami
speed --json whoami
```

**JSON output:**
```json
{ "address": "0x..." }
```

---

### balance

Show ETH, SPEED, wrapped native, and any extra tokens.

```
speed balance
speed balance -c base
speed balance -c base -t 0xTokenAddress
speed balance -c base -t 0xAddr1 -t 0xAddr2
speed --json balance -c base
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | all chains | Query a specific chain; omit for all. |
| `-t, --token <address>` | (none) | Extra token to include. Repeatable. |

**JSON output:**
```json
{
  "address": "0x...",
  "chains": [{
    "chainId": 8453,
    "nativeSymbol": "ETH",
    "nativeBalance": "0.012345",
    "wrappedNativeBalance": "0.0",
    "wrappedNativeSymbol": "WETH",
    "tokens": [
      { "address": "0xB01C...", "symbol": "SPEED", "balance": "9200.5", "decimals": 18 }
    ]
  }]
}
```

---

### price

Get SPEED/ETH, SPEED/USD, and native/USD from on-chain Lightspeed oracles.

```
speed price
speed price -c base
speed --json price -c base
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | `8453` | Chain to query oracle on. |

**JSON output:**
```json
{
  "chainId": 8453,
  "speedPerNative": 9200000.12,
  "speedUsd": 0.00000042,
  "nativeUsd": 2500.0
}
```

Note: `speedPerNative` is SPEED per 1 ETH (raw float). `speedUsd` and `nativeUsd` are USD prices.

---

### quote

Preview a swap without executing. Returns amounts only — no transaction.

```
speed quote -c base --sell eth --buy speed -a 0.001
speed quote -c base --sell speed --buy eth -a 9000
speed quote -c base --sell eth --buy 0xTokenAddr -a 0.002
speed --json quote -c base --sell eth --buy speed -a 0.001
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | `8453` | Chain. |
| `--sell <address\|alias>` | ETH | Token to sell. |
| `--buy <address\|alias>` | SPEED | Token to buy. |
| `-a, --amount <amount>` | required | Sell amount in human units (e.g. `0.001` ETH or `9000` SPEED). |

**JSON output:**
```json
{
  "sellAmount": "1000000000000000",
  "buyAmount": "9215562271270960000000",
  "buyToken": "0xB01C...",
  "sellToken": "0xEeee...",
  "gas": "150000",
  "to": "0x..."
}
```

**Key fields:**
- `sellAmount` / `buyAmount` — raw integer strings in token's own decimals (18 for ETH/SPEED).
- `gas` — estimated gas units as a string integer.
- To convert `buyAmount` to human: `buyAmount / 10^decimals`.

---

### swap

One-shot: quote → (optional confirm) → approve if needed → execute.

```
# ETH → SPEED (defaults)
speed swap -c base -a 0.001 -y

# SPEED → ETH
speed swap -c base --sell speed --buy eth -a 9000 -y

# ETH → any token
speed swap -c base --sell eth --buy 0xTokenAddr -a 0.002 -y

# Dry run (no tx)
speed swap -c base -a 0.001 --dry-run

# JSON output for scripts
speed --json --yes swap -c base -a 0.001
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | `8453` | Chain. |
| `--sell <address\|alias>` | ETH | Sell token. |
| `--buy <address\|alias>` | SPEED | Buy token. |
| `-a, --amount <amount>` | required | Sell amount in human units. |
| `-y, --yes` / `--go` | false | Skip confirmation prompt. **Required in scripts.** |
| `--dry-run` | false | Fetch quote and print details; no approval or swap tx. |

**JSON output (success):**
```json
{ "txHash": "0x...", "explorerLink": "https://basescan.org/tx/0x..." }
```

**JSON output (dry-run):**
```json
{
  "sellAmount": "1000000000000000",
  "buyAmount": "9215562271270960000000",
  "gas": "150000",
  "needsAllowance": false
}
```

**Error exit codes:** Non-zero on any failure. Error JSON: `{ "error": "...", "code": "SWAP_ERROR" }`.

**Important limits:**
- Minimum swap: ~0.0001 ETH (dust protection from 0x).
- When selling native ETH, leave gas headroom (e.g. `-a 0.0015` not `-a 0.002` if balance is 0.002).

---

### gas

Swap a token → native ETH/MATIC/BNB to fund gas. If selling wrapped native (WETH), unwraps directly without a swap.

```
# Unwrap WETH → ETH (default)
speed gas -c base -a 0.1 -y

# Sell SPEED → ETH for gas
speed gas -c base --token speed -a 5000 -y

# Sell any token → ETH
speed gas -c base --token 0xTokenAddr -a 100 -y

speed --json --yes gas -c base -a 0.05
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | `8453` | Chain. |
| `-t, --token <address\|speed>` | wrapped native | Token to sell. Default unwraps WETH. |
| `-a, --amount <amount>` | required | Amount to sell in human units. |
| `-y, --yes` | false | Skip confirmation. |

**JSON output:**
- Unwrap path: `{ "unwrapTxHash": "0x...", "explorerLink": "...", "nativeReceived": "50000000000000000" }`
- Swap path: `{ "swapTxHash": "0x...", "unwrapTxHash": "0x...", "explorerLink": "...", "nativeReceived": "50000000000000000" }`

---

### send

ERC-20 transfer of SPEED to an address.

```
speed send -c base -t 0xRecipient -a 1000 -y
speed --json --yes send -c base -t 0xRecipient -a 500
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | `8453` | Chain. |
| `-t, --to <address>` | required | Recipient wallet address. |
| `-a, --amount <amount>` | required | SPEED amount in human units. |

**JSON output:** `{ "txHash": "0x...", "explorerLink": "..." }`

---

### bridge

Bridge SPEED cross-chain via Squid/Axelar.

```
speed bridge --from-chain base --to-chain ethereum -a 1000 -y
speed bridge --from-chain base --to-chain arbitrum -a 500 -y
speed --json --yes bridge --from-chain base --to-chain optimism -a 200
```

| Flag | Default | Description |
|---|---|---|
| `--from-chain <id\|name>` | `8453` | Source chain. |
| `--to-chain <id\|name>` | required | Destination chain. |
| `-a, --amount <amount>` | required | SPEED amount to bridge (18 decimals). |
| `--to-token <address>` | SPEED on dest | Destination token address if different from SPEED. |
| `-y, --yes` | false | Skip confirmation. |

**JSON output:**
```json
{
  "txHash": "0x...",
  "explorerLink": "https://basescan.org/tx/0x...",
  "axelarScan": "https://axelarscan.io/gmp/0x...",
  "requestId": "abc123"
}
```

Save `requestId` and `txHash` to poll bridge status with `speed status`.

---

### status

Check transaction confirmation, or poll Squid for bridge status.

```
# Regular tx
speed status --tx 0xhash -c base
speed --json status --tx 0xhash -c base

# Bridge tx (requires SQUID_INTEGRATOR_ID env var)
speed status --tx 0xhash --request-id abc123
```

| Flag | Default | Description |
|---|---|---|
| `--tx <hash>` | required | Transaction hash. |
| `-c, --chain <id\|name>` | `8453` | Chain (for non-bridge tx). |
| `--request-id <id>` | (none) | Squid request ID from bridge output. |
| `--quote-id <id>` | (none) | Squid quote ID (optional, from bridge output). |

**JSON output (regular tx):**
```json
{ "blockNumber": "12345678", "status": "confirmed" }
```
Status values: `"confirmed"`, `"reverted"`, `"pending"`.

**JSON output (bridge):**
```json
{ "status": "success", "squidTransactionStatus": "success", ... }
```

---

### estimate

Dry-run gas cost for a swap or bridge without executing.

```
speed estimate -c base --sell eth --buy speed -a 0.001
speed estimate -c base --bridge --to-chain ethereum
speed --json estimate -c base --sell eth --buy speed -a 0.001
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | `8453` | Chain. |
| `--sell <address\|alias>` | ETH | Sell token. |
| `--buy <address\|alias>` | SPEED | Buy token. |
| `-a, --amount <amount>` | (none) | Sell amount (improves gas estimate accuracy). |
| `--bridge` | false | Estimate for bridge instead of swap. |
| `--to-chain <id\|name>` | (none) | Required when `--bridge` is set. |

**JSON output:**
```json
{
  "gasEth": "0.000012",
  "gasUsd": "0.03",
  "gasLimit": "150000",
  "gasPrice": "80000000"
}
```

---

### dca

Dollar-cost average: buy a token with ETH on a fixed interval. Runs until stopped or `--count` buys complete.

```
# Buy SPEED every 5 minutes until stopped
speed dca -c base -a 0.001 --interval 5m

# Buy 10 times, every 1 hour
speed dca -c base -a 0.001 --interval 1h --count 10 -y

# Buy any token
speed dca -c base --token 0xTokenAddr -a 0.002 --interval 300 --count 5 -y

# Dry run
speed dca -c base -a 0.001 --interval 5m --count 3 --dry-run

speed --json --yes dca -c base -a 0.001 --interval 5m --count 10
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | `8453` | Chain. |
| `-t, --token <address\|speed>` | SPEED | Token to buy. |
| `-a, --amount <amount>` | required | ETH per buy in human units. Min `0.0001` ETH. |
| `--interval <s\|5m\|1h\|1d>` | `300` | Time between buys. Accepts seconds or `Nm`, `Nh`, `Nd`. |
| `--interval-jitter <fraction>` | `0` | Random ± variance on interval (e.g. `0.2` = ±20%). |
| `--count <n>` | unlimited | Number of buys to execute then exit. |
| `--dry-run` | false | Print plan; no transactions. |

**Interval format examples:** `300`, `5m`, `1h`, `1d`, `0.5h`

**JSON output (completion):**
```json
{
  "summary": { "buys": 10, "failed": 0, "totalAttempts": 10 },
  "results": [
    { "buy": 1, "txHash": "0x...", "amountWei": "1000000000000000", "explorerLink": "..." }
  ]
}
```

---

### volume

Human-like interleaved buys and sells with random walk amounts and jitter delays. Useful for generating organic-looking on-chain activity.

```
# 20 ops, initial 0.001 ETH per buy
speed volume -c base -a 0.001 --ops 20 -y

# Custom bounds and sell frequency
speed volume -c base -a 0.001 --amount-min 0.0005 --amount-max 0.003 --ops 50 --sell-frequency 0.3 -y

# With delay between ops
speed volume -c base -a 0.001 --ops 10 --delay 30 --delay-jitter 0.5 -y

speed --json --yes volume -c base -a 0.001 --ops 20
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | `8453` | Chain. |
| `-t, --token <address\|speed>` | SPEED | Token to buy/sell. |
| `--ops <n>` | `20` | Total number of operations (buys + sells). |
| `-a, --amount <amount>` | required | Initial ETH per buy. |
| `--amount-min <amount>` | 50% of initial | Minimum ETH per buy. |
| `--amount-max <amount>` | 150% of initial | Maximum ETH per buy. |
| `--amount-drift <fraction>` | `0.1` | Max relative random walk step per op (e.g. `0.1` = ±10%). |
| `--sell-frequency <0..1>` | `0.2` | Probability any given op is a sell (0 = never sell, 1 = always sell). |
| `--sell-partial-chance <0..1>` | `0.3` | When selling, probability of partial (random fraction) vs full balance. |
| `--delay <seconds>` | `0` | Center of delay between ops in seconds. |
| `--delay-jitter <fraction>` | `0.5` | Variance around delay (e.g. `0.5` = ±50%). |
| `--dry-run` | false | Print plan; no transactions. |

---

### history

List recent transactions via Alchemy. Requires `ALCHEMY_API_KEY`.

```
speed history
speed history -c base
speed history -c base -n 50
speed --json history -c base -n 20
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | all chains | Chain to query. Omit for all. |
| `-n, --limit <n>` | `20` | Max transactions per chain (max 100). |

**JSON output:**
```json
{
  "address": "0x...",
  "chains": [{
    "chainId": 8453,
    "chainName": "base",
    "transactions": [{
      "hash": "0x...",
      "from": "0x...",
      "to": "0x...",
      "value": "1000000000000000",
      "symbol": "ETH",
      "category": "external",
      "timeStamp": "2024-01-01T00:00:00Z"
    }]
  }]
}
```

---

### pending

Show in-flight bridge transfers and pending mempool txs.

```
speed pending
speed pending -c base
speed pending --no-bridges
speed pending --no-txs
speed pending --clear-done
speed --json pending
```

| Flag | Default | Description |
|---|---|---|
| `-c, --chain` | all chains | Filter pending txs to one chain. |
| `--no-bridges` | false | Skip bridge status section. |
| `--no-txs` | false | Skip pending tx list. |
| `--clear-done` | false | Remove completed/failed bridges from stored list. |

**JSON output:**
```json
{
  "bridges": [
    { "requestId": "abc", "status": "success", "fromChain": 8453, "toChain": 1, "txHash": "0x..." }
  ],
  "pendingTxs": []
}
```

---

### allowance

Check current ERC-20 allowance for a spender.

```
speed allowance -c base --token 0xTokenAddr --spender 0xSpenderAddr
speed --json allowance -c base --token 0xTokenAddr --spender 0xSpenderAddr
```

| Flag | Required | Description |
|---|---|---|
| `-c, --chain` | No (default 8453) | Chain. |
| `--token <address>` | Yes | Token contract address. |
| `--spender <address>` | Yes | Spender address (e.g. 0x AllowanceHolder). |

**JSON output:** `{ "allowance": "115792089...", "owner": "0x...", "spender": "0x...", "token": "0x..." }`

---

### approve

Set ERC-20 allowance for a spender. Used before manual swaps.

```
speed approve -c base --token 0xTokenAddr --spender 0xSpender -a 1000
speed approve -c base --token 0xTokenAddr --spender 0xSpender -a max
speed --json --yes approve -c base --token 0xTokenAddr --spender 0xSpender -a max
```

| Flag | Required | Description |
|---|---|---|
| `-c, --chain` | No (default 8453) | Chain. |
| `--token <address>` | Yes | Token contract address. |
| `--spender <address>` | Yes | Spender to approve. |
| `-a, --amount <amount\|max>` | Yes | Amount in human units, or `max` for `uint256.max`. |

**JSON output:** `{ "txHash": "0x...", "token": "0x...", "spender": "0x..." }`

---

### revoke

Set allowance back to 0 (security hygiene after scripted operations).

```
speed revoke -c base --token 0xTokenAddr --spender 0xSpenderAddr
speed --json --yes revoke -c base --token 0xTokenAddr --spender 0xSpenderAddr
```

| Flag | Required | Description |
|---|---|---|
| `-c, --chain` | No (default 8453) | Chain. |
| `--token <address>` | Yes | Token contract address. |
| `--spender <address>` | Yes | Spender to revoke. |

**JSON output:** `{ "txHash": "0x...", "token": "0x...", "spender": "0x..." }`

---

### xp

Show XP progress, level, streak, and action stats. No transaction.

```
speed xp
speed xp --reset
speed --json xp
```

| Flag | Description |
|---|---|
| `--no-title` | Omit level title display. |
| `--reset` | Clear all XP back to level 1. |

**JSON output:**
```json
{
  "totalXP": 4200,
  "level": 7,
  "title": "On-Chain Ghost",
  "streak": 3,
  "lastActivity": "2024-01-01",
  "progress": { "current": 200, "needed": 500, "fraction": 0.4 },
  "stats": {
    "swaps":     { "count": 12, "totalUSD": 500 },
    "bridges":   { "count": 2,  "totalUSD": 200 },
    "volumeOps": { "count": 40, "totalUSD": 1200 },
    "dcaBuys":   { "count": 8,  "totalUSD": 80 },
    "gasRefuels":{ "count": 3,  "totalUSD": 15 }
  },
  "recentHistory": [...]
}
```

---

### config

Read/write persistent preferences in `~/.speed/config.json`. No secrets stored.

```
speed config set default-chain 8453
speed config set default-slippage 0.5
speed config set output-format json
speed config get default-chain
speed config get
```

Valid keys:
| Key | Values | Description |
|---|---|---|
| `default-chain` | chain ID integer | Default chain when `-c` is omitted. |
| `default-slippage` | float (e.g. `0.5`) | Default slippage tolerance %. |
| `output-format` | `human` or `json` | Default output format. |

---

## 6. JSON Mode — Parsing Output in Scripts

Always pass `--json` (before the subcommand) when scripting. The CLI writes a single JSON object or array to stdout. Stderr contains spinner/progress text — safe to ignore.

### PowerShell

```powershell
# Capture JSON and parse
$raw  = speed --json quote -c base --sell eth --buy speed -a 0.001 2>&1
$line = $raw | Where-Object { $_ -match '^\{' } | Select-Object -First 1
$obj  = $line | ConvertFrom-Json
$buyAmount = [double]$obj.buyAmount

# Swap and parse tx hash
$raw2   = speed --json --yes swap -c base -a 0.001 2>&1
$line2  = $raw2 | Where-Object { $_ -match '^\{' } | Select-Object -First 1
$result = $line2 | ConvertFrom-Json
Write-Host $result.txHash
```

### Bash

```bash
# Capture JSON and extract field (no jq needed)
raw=$(speed --json quote -c base --sell eth --buy speed -a 0.001 2>&1)
json=$(echo "$raw" | grep -m1 '^{')
buy_amount=$(echo "$json" | grep -oP '"buyAmount"\s*:\s*"\K[^"]+')

# With jq (if available)
buy_amount=$(echo "$json" | jq -r '.buyAmount')

# Swap and get tx hash
raw2=$(speed --json --yes swap -c base -a 0.001 2>&1)
json2=$(echo "$raw2" | grep -m1 '^{')
tx_hash=$(echo "$json2" | grep -oP '"txHash"\s*:\s*"\K[^"]+')
```

### Error detection

Errors also come as JSON when `--json` is set:
```json
{ "error": "Insufficient ETH...", "code": "INSUFFICIENT_FUNDS" }
```

Check for the `error` field before reading success fields:
```powershell
if ($obj.PSObject.Properties.Name -contains 'error') {
    throw "CLI error: $($obj.error) [$($obj.code)]"
}
```
```bash
if echo "$json" | grep -q '"error"'; then
    err=$(echo "$json" | grep -oP '"error"\s*:\s*"\K[^"]+')
    echo "Error: $err" >&2; exit 1
fi
```

---

## 7. Decimal Handling

All raw amounts returned by `--json` are integer strings representing the value in the token's smallest unit.

| Token | Decimals | Divide raw by |
|---|---|---|
| ETH, SPEED, most ERC-20s | 18 | `1e18` (1000000000000000000) |
| WBTC, cbBTC | 8 | `1e8` (100000000) |
| USDC, USDT | 6 | `1e6` (1000000) |

### PowerShell conversion

```powershell
$DECIMALS = [double]1e18
$human = [double]$raw / $DECIMALS
# Format without scientific notation (critical for passing back to CLI)
$str = $human.ToString("F18")   # use token's own decimal count
# e.g. cbBTC (8 decimals):
$str = $human.ToString("F8")    # "0.00002915"
```

**Warning:** `"{0:F6}" -f $human` or `"G10"` can produce `0.000000` or `2.9E-05` for low-decimal tokens like cbBTC. Always use `"F{decimals}"` where `{decimals}` is the actual token decimal count.

### Bash conversion

```bash
DECIMALS=1000000000000000000
human=$(awk "BEGIN { printf \"%.18f\", $raw / $DECIMALS }")
# Format for CLI (plain decimal, no scientific notation)
str=$(awk "BEGIN { printf \"%.*f\", $decimals, $raw / (10 ^ $decimals) }")
```

---

## 8. RPC Endpoints

Public fallback RPCs used by the CLI (and available for direct `eth_call` in scripts):

| Chain | RPC URL |
|---|---|
| Base (8453) | `https://mainnet.base.org` |
| Ethereum (1) | `https://eth.llamarpc.com` |
| Optimism (10) | `https://mainnet.optimism.io` |
| Arbitrum (42161) | `https://arb1.arbitrum.io/rpc` |
| Polygon (137) | `https://polygon.llamarpc.com` |
| BNB (56) | `https://bsc-dataseed.binance.org` |

Set `ALCHEMY_API_KEY` to use Alchemy endpoints automatically.

---

## 9. Auto-Detecting Token Decimals via RPC

When working with arbitrary tokens, call the ERC-20 `decimals()` function directly — no external dependency needed.

**Selector:** `0x313ce567`

### PowerShell

```powershell
function Get-TokenDecimals {
    param([string]$tokenAddr, [string]$chainName)

    # Known aliases
    $lower = $tokenAddr.ToLower()
    if ($lower -in @('speed','eth','native','ether')) { return 18 }
    if (-not $tokenAddr.StartsWith("0x"))            { return 18 }

    $rpcMap = @{
        "base"="https://mainnet.base.org"; "8453"="https://mainnet.base.org"
        "ethereum"="https://eth.llamarpc.com"; "mainnet"="https://eth.llamarpc.com"; "1"="https://eth.llamarpc.com"
        "optimism"="https://mainnet.optimism.io"; "op"="https://mainnet.optimism.io"; "10"="https://mainnet.optimism.io"
        "arbitrum"="https://arb1.arbitrum.io/rpc"; "arb"="https://arb1.arbitrum.io/rpc"; "42161"="https://arb1.arbitrum.io/rpc"
        "polygon"="https://polygon.llamarpc.com"; "matic"="https://polygon.llamarpc.com"; "137"="https://polygon.llamarpc.com"
        "bnb"="https://bsc-dataseed.binance.org"; "bsc"="https://bsc-dataseed.binance.org"; "56"="https://bsc-dataseed.binance.org"
    }
    $rpc = $rpcMap[$chainName.ToLower()]
    if (-not $rpc) { return 18 }

    $body = '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"' + $tokenAddr + '","data":"0x313ce567"},"latest"],"id":1}'
    try {
        $resp = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
        $hex  = $resp.result -replace '^0x',''
        return [Convert]::ToInt32($hex.TrimStart('0'), 16)
    } catch {
        return 18
    }
}
```

### Bash

```bash
get_token_decimals() {
    local token="$1" chain="$2"
    local lower="${token,,}"
    [[ "$lower" =~ ^(speed|eth|ether|native)$ ]] && echo 18 && return
    [[ "$lower" != 0x* ]] && echo 18 && return

    local rpc
    case "${chain,,}" in
        base|8453)       rpc="https://mainnet.base.org" ;;
        ethereum|mainnet|eth|1) rpc="https://eth.llamarpc.com" ;;
        optimism|op|10)  rpc="https://mainnet.optimism.io" ;;
        arbitrum|arb|42161) rpc="https://arb1.arbitrum.io/rpc" ;;
        polygon|matic|137) rpc="https://polygon.llamarpc.com" ;;
        bnb|bsc|56)      rpc="https://bsc-dataseed.binance.org" ;;
        *) echo 18 && return ;;
    esac

    local body="{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$token\",\"data\":\"0x313ce567\"},\"latest\"],\"id\":1}"
    local resp hex
    resp=$(curl -sf -X POST "$rpc" -H "Content-Type: application/json" -d "$body" 2>/dev/null) || { echo 18; return; }
    hex=$(echo "$resp" | grep -oP '"result"\s*:\s*"\K[^"]+' | sed 's/^0x//' | sed 's/^0*//')
    [[ -z "$hex" ]] && echo 18 && return
    echo "obase=10; ibase=16; ${hex^^}" | bc 2>/dev/null || echo 18
}
```

---

## 10. PowerShell Patterns

### Invoke a quote safely (avoids $Args reserved variable bug)

```powershell
# CORRECT: use named parameters, not splatted arrays named $Args
function Get-Quote {
    param([string]$sellTok, [string]$buyTok, [string]$sellAmt)
    $raw  = speed quote --json -c $Chain --sell $sellTok --buy $buyTok -a $sellAmt 2>&1
    $line = $raw | Where-Object { $_ -match '^\{' } | Select-Object -First 1
    if (-not $line) { throw "No JSON from quote. Output: $($raw -join "`n")" }
    $obj  = $line | ConvertFrom-Json
    if ($obj.PSObject.Properties.Name -contains 'error') { throw "Quote error: $($obj.error)" }
    return $obj
}
```

### Format token amounts (no scientific notation)

```powershell
# Always use F + token decimal count. Never use G10 or F6 for small amounts.
$decimals   = Get-TokenDecimals $Token $Chain
$scale      = [Math]::Pow(10, $decimals)
$humanAmt   = [double]$rawAmount / $scale
$amountStr  = $humanAmt.ToString("F$decimals")   # e.g. "0.00002915" for cbBTC
```

### Multiline if-expression (must be one line in PowerShell)

```powershell
# CORRECT
$color = if ($pct -ge $target) { "Green" } elseif ($pct -gt 0) { "White" } else { "DarkRed" }

# WRONG - causes parse error
$color = if ($pct -ge $target) { "Green" }
         elseif ($pct -gt 0)   { "White" }   # <-- Unexpected token '}'
         else                   { "DarkRed" }
```

### Polling loop template

```powershell
$iteration = 0
while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $q = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
        $current = [double]$q.buyAmount
        # ... compare and act
    } catch {
        Write-Warning "Poll $iteration failed: $_ - retrying."
    }
}
```

---

## 11. Bash Patterns

### Invoke a quote safely

```bash
get_quote() {
    local sell_tok="$1" buy_tok="$2" sell_amt="$3"
    local output json
    output=$(speed quote --json -c "$CHAIN" --sell "$sell_tok" --buy "$buy_tok" -a "$sell_amt" 2>&1)
    json=$(echo "$output" | grep -m1 '^{')
    [[ -z "$json" ]] && { echo "No JSON. Output: $output" >&2; return 1; }
    echo "$json" | grep -q '"error"' && {
        local err; err=$(echo "$json" | grep -oP '"error"\s*:\s*"\K[^"]+')
        echo "Quote error: $err" >&2; return 1
    }
    echo "$json"
}
```

### Extract a JSON field (no jq)

```bash
extract_field() {
    local json="$1" field="$2"
    # Handles both "field":"value" and "field":value
    echo "$json" | grep -oP "\"$field\"\s*:\s*\"\K[^\"]+|\"$field\"\s*:\s*\K[0-9.]+" | head -1
}
buy_amount=$(extract_field "$json" "buyAmount")
tx_hash=$(extract_field "$json" "txHash")
```

### Float comparison (no bc, uses awk)

```bash
# Returns 0 (true) if $1 >= $2
awk_gte() { awk "BEGIN { exit ($1 >= $2) ? 0 : 1 }"; }

if awk_gte "$current_raw" "$target_raw"; then
    echo "Target hit!"
fi
```

### Polling loop template

```bash
iteration=0
while (( iteration < MAX_ITERATIONS )); do
    (( iteration++ )) || true
    ts=$(date +"%H:%M:%S")
    echo "[$ts] Poll $iteration / $MAX_ITERATIONS - waiting $POLL_SECONDS s..."
    sleep "$POLL_SECONDS"

    poll_json=$(get_quote "$TOKEN" "eth" "$token_str" 2>&1) || {
        echo "Warning: poll $iteration failed - retrying."
        continue
    }

    current_raw=$(extract_field "$poll_json" "buyAmount")
    [[ -z "$current_raw" ]] && { echo "Warning: empty buyAmount - retrying."; continue; }

    # compare and act
done
```

---

## 12. Common Pitfalls

| Pitfall | Fix |
|---|---|
| Script hangs waiting for confirmation | Always pass `-y` / `--yes` in scripts. |
| `$Args` is a reserved PowerShell variable | Never name a parameter `$Args`. Use `$QuoteArgs`, `$Params`, etc. |
| `elseif`/`else` on new line causes parse error in PS1 | Put `} elseif {` on the same line. |
| Scientific notation (`2.9E-05`) breaks CLI amount parsing | Use `"F{decimals}"` format, not `"G10"` or `"F6"`. |
| Zero amount after decimal conversion | Token has fewer than 18 decimals. Auto-detect with `Get-TokenDecimals`. |
| `--buy` and `--amount` required error in `quote` | Caused by `@Args` splatting a PowerShell automatic variable. Pass args as named string params. |
| Swap reverts with "slippage / minimum amount" | Amount is too small (< ~0.0001 ETH equivalent). Use larger amounts. |
| `buyAmount` missing from quote JSON | Quote returned an error object. Check for `"error"` field first. |
| Insufficient ETH for swap | When selling native ETH, reserve gas headroom. Use 90% of balance or smaller amount. |
| `history` / `pending` returns empty | `ALCHEMY_API_KEY` not set. Both commands require Alchemy. |
| `bridge` / `status --request-id` fails | `SQUID_INTEGRATOR_ID` not set in environment. |
| Token decimals wrong for WBTC/cbBTC/USDC | Call `decimals()` via RPC (selector `0x313ce567`) or hardcode: WBTC/cbBTC=8, USDC/USDT=6. |
