---
name: trailing-stop-any
description: Runs the trailing stop-loss flow: buy any token with ETH via speed CLI, poll Token->ETH, sell when ETH return drops TrailPct% below the running peak. Use when automating trailing stop-loss, buy-then-sell with a trailing floor, or when the user refers to trailing-stop-any.ps1/.sh or "trailing stop" with ETH/token.
---

# Trailing Stop-Loss (ETH → Token → ETH)

Scripts: `trailing-stop-any.ps1` (PowerShell), `trailing-stop-any.sh` (Bash). Buy with ETH, then sell when the **ETH return** drops **TrailPct%** below the **running peak**. The floor trails the peak upward and never moves down.

## When to use

- User wants to run or modify the trailing stop-loss flow (buy token with ETH, sell when value drops TrailPct% below the highest seen).
- User asks about `trailing-stop-any.ps1`, `trailing-stop-any.sh`, "trailing stop", or "trailing stop-loss" with ETH.
- User needs parameter or flow documentation for these scripts.

## Flow (do not reorder)

1. **Resolve token decimals**  
   On-chain RPC `decimals()` for token address; aliases (e.g. `speed`) and non-0x inputs default to 18.

2. **Quote buy**  
   `speed quote --json` ETH → Token for `-Amount` / `--amount` ETH. Derive token amount (human-readable) and validate &gt; 0.

3. **Execute buy**  
   `speed swap -c $Chain --sell eth --buy $Token -a $Amount -y`. Exit on failure.

4. **Baseline sell quote → initial peak and floor**  
   Quote Token → ETH for the token amount from step 2. Set **peak** = baseline ETH (raw wei). Set **floor** = peak × (1 − TrailPct/100). Floor and peak are in raw wei for comparisons.

5. **Poll until floor breach or max iterations**  
   Every `-PollSeconds` / `--pollseconds`: quote Token → ETH.
   - If **current &gt; peak**: set peak = current, floor = peak × (1 − TrailPct/100). (Floor only ever rises.)
   - If **current ≤ floor**: sell immediately and exit.
   - Otherwise continue polling.
   If `-MaxIterations` / `--maxiterations` reached without selling, sell anyway and exit.

6. **Sell**  
   `speed swap -c $Chain --sell $Token --buy eth -a $tokenStr -y`. Script exits after this.

## Parameters

| Parameter        | Required | PowerShell           | Bash                 | Meaning |
|------------------|----------|----------------------|----------------------|--------|
| Chain            | Yes      | `-Chain`             | `--chain`            | Chain name or id: base, mainnet/ethereum/1, optimism/10, arbitrum/42161, polygon/137, bsc/56 |
| Token            | Yes      | `-Token`             | `--token`            | Token contract address (0x...) or alias (e.g. `speed`) |
| Amount           | Yes      | `-Amount`            | `--amount`           | ETH amount to spend (e.g. "0.001") |
| TrailPct         | Yes      | `-TrailPct`          | `--trailpct`         | % drop from peak that triggers sell (e.g. 5 = sell when value is 5% below peak) |
| TokenSymbol      | No       | `-TokenSymbol`       | `--tokensymbol`      | Display label (default: token address or alias) |
| PollSeconds      | No       | `-PollSeconds`       | `--pollseconds`      | Seconds between sell quotes (default: 60) |
| MaxIterations    | No       | `-MaxIterations`     | `--maxiterations`    | Max poll count before forced sell (default: 1440) |

## Helpers (script internals)

- **Get token decimals**: RPC `eth_call` to token `decimals()`; aliases/non-0x → 18.
- **Get-Quote / get_quote**: `speed quote --json`; parse first JSON line; require `buyAmount`.
- **Run-Sell / run_sell**: Runs `speed swap` Token → ETH with given token amount, then exits.
- **Peak/floor**: Stored in raw wei; floor = peak × (1 − TrailPct/100); peak (and thus floor) only increase when a new high is seen.

## Examples

**PowerShell:**
```powershell
.\trailing-stop-any.ps1 -Chain base -Token speed -Amount 0.001 -TrailPct 5
.\trailing-stop-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.002 -TrailPct 3
.\trailing-stop-any.ps1 -Chain base -Token 0x... -TokenSymbol PEPE -Amount 0.01 -TrailPct 10 -PollSeconds 30
```

**Bash:**
```bash
./trailing-stop-any.sh --chain base --token speed --amount 0.001 --trailpct 5
./trailing-stop-any.sh --chain base --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf --tokensymbol cbBTC --amount 0.002 --trailpct 3
./trailing-stop-any.sh --chain base --token 0x... --tokensymbol PEPE --amount 0.01 --trailpct 10 --pollseconds 30
```

## RPC / chains

Scripts use built-in RPC URLs for decimals only (Base, Ethereum, Optimism, Arbitrum, Polygon, BSC). Swap execution is via `speed` CLI.

## Agent guidance

- **Modifying the script**: Preserve the order of steps (quote buy → buy → baseline peak/floor → poll → sell). Do not sell before the buy succeeds. Keep peak/floor logic: floor = peak × (1 − TrailPct/100); floor only updates when peak updates (on new high).
- **Adding features**: Keep all comparisons in raw wei for consistency; convert to human ETH only for display.
- **Debugging**: Failures are usually from `speed quote`/`speed swap` or RPC; scripts use strict error handling and exit on buy failure.
