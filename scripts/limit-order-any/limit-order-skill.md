---
name: limit-order-any
description: Runs the limit-order flow: buy any token with ETH via speed CLI, then poll and sell when ETH return reaches target percentage. Use when automating limit-order style trades, buy-then-sell scripts, or when the user refers to limit-order-any.ps1 or "limit order" with ETH/token.
---

# Limit Order (ETH → Token → ETH)

Script: `scripts/limit-order-any.ps1`. Success is measured in ETH: spend X ETH, sell when you get back X × (1 + TargetPct/100) ETH.

## When to use

- User wants to run or modify the limit-order flow (buy token with ETH, sell when ETH return hits target %).
- User asks about `limit-order-any.ps1`, "limit order" with ETH, or polling sell-on-target behavior.
- User needs parameter or flow documentation for this script.

## Flow (do not reorder)

1. **Resolve token decimals**  
   On-chain RPC `decimals()` for token address; aliases (e.g. `speed`) and non-0x inputs default to 18.

2. **Quote buy**  
   `speed quote --json` ETH → Token for `-Amount` ETH. Derive token amount (human-readable) and validate &gt; 0.

3. **Execute buy**  
   `speed swap -c $Chain --sell eth --buy $Token -a $Amount -y`. Exit on failure.

4. **Baseline sell quote**  
   Quote Token → ETH for the token amount from step 2. Compute target ETH = Amount × (1 + TargetPct/100).

5. **Poll until target or max iterations**  
   Every `-PollSeconds`: quote Token → ETH; if ETH return ≥ target → run sell and exit. If `-MaxIterations` reached → sell anyway (no exit before sell).

6. **Sell**  
   `speed swap -c $Chain --sell $Token --buy eth -a $tokenStr -y`. Script exits after this.

## Parameters

| Parameter        | Required | Meaning |
|------------------|----------|--------|
| `Chain`          | Yes      | Chain name or id: base, mainnet/ethereum/1, optimism/10, arbitrum/42161, polygon/137, bsc/56 |
| `Token`          | Yes      | Token contract address (0x...) or alias (e.g. `speed`) |
| `Amount`         | Yes      | ETH amount to spend (string, e.g. "0.001") |
| `TargetPct`      | Yes      | Target gain in %; sell when ETH back ≥ Amount × (1 + TargetPct/100) |
| `TokenSymbol`    | No       | Display label (default: token address or alias) |
| `PollSeconds`    | No       | Seconds between sell quotes (default: 60) |
| `MaxIterations`  | No       | Max poll count before forced sell (default: 1440) |

## Helpers (script internals)

- **Get-TokenDecimals**: RPC `eth_call` to token `decimals()`; aliases/non-0x → 18.
- **Get-Quote**: `speed quote --json`; parse first JSON line; require `buyAmount`.
- **Run-Sell**: Runs `speed swap` Token → ETH with given token amount, then exits.

## Examples

```powershell
.\limit-order-any.ps1 -Chain base -Token speed -Amount 0.001 -TargetPct 5
.\limit-order-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -Amount 0.002 -TargetPct 2.5
```

## RPC / chains

Script uses built-in `$RPC_URLS` for decimals only (Base, Ethereum, Optimism, Arbitrum, Polygon, BSC). Swap execution is via `speed` CLI.

## Agent guidance

- **Modifying the script**: Preserve the order of steps (quote buy → buy → baseline → poll → sell). Do not sell before the buy succeeds.
- **Adding features**: Keep success definition in ETH (target = Amount × (1 + TargetPct/100)); quote and compare in raw wei then convert for display.
- **Debugging**: Failures are usually from `speed quote`/`speed swap` or RPC; script uses `-ErrorActionPreference Stop` and exits on swap failure.
