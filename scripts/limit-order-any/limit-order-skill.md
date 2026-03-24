## v2: configurable base token

Same behavior as `../scripts/<this-folder>/`, but the **quote currency** is not hard-coded to **ETH**. Use:

| | |
|---|---|
| **PowerShell** | `-BaseToken` (default `speed`), optional `-BaseTokenSymbol` |
| **Bash** | `--base-token` (default `speed`), optional `--base-token-symbol` |

`-Amount` is in **units of the base token** (what you spend on the buy). Use `../scripts/` if you want ETH-only bots unchanged.

---

# Limit Order Skill

Complete reference for `limit-order-any.ps1` and `limit-order-any.sh` — buy once, then poll and sell when **base-token return** reaches a target gain percentage.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Flow and Math](#3-flow-and-math)
4. [Running the Scripts](#4-running-the-scripts)
5. [Reading the Output](#5-reading-the-output)
6. [Helpers (internals)](#6-helpers-internals)
7. [Pitfalls and Agent Notes](#7-pitfalls-and-agent-notes)

---

## 1. Concept

A limit-style exit: you spend **X** base token, buy the asset, then wait until a full-position sell quote shows you would receive **at least** **X × (1 + TargetPct/100)** base token back. Unlike a bracket, there is no stop-loss — if price never reaches the target, the script eventually **forces a market sell** at `-MaxIterations`.

**When to use it:**
- You want a single profit target on a buy-and-hold leg
- You accept timeout risk (forced sell) in exchange for a simple rule

**Difference from `bracket-any`:** Bracket sets take-profit **and** stop-loss. Limit order only sets the upside target (plus forced exit on max polls).

**Difference from `trailing-stop-any`:** Trailing stop exits on a **drop from peak**. Limit order exits when value **rises to** a fixed target vs entry baseline.

---

## 2. Parameters Reference

| Parameter (PS1)    | Flag (SH)           | Type    | Default  | Description |
|---|---|---|---|---|
| `-Chain`           | `--chain`           | string  | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`           | `--token`           | string  | required | Token contract address or alias. |
| `-Amount`          | `--amount`          | string  | required | **Base token** to spend on the buy (same units as `speed swap -a` for `-BaseToken`). |
| `-TargetPct`       | `--targetpct`       | float   | required | Target **gain %** vs **base spent**; sell when full-position base return ≥ `Amount × (1 + TargetPct/100)`. |
| `-TokenSymbol`     | `--tokensymbol`     | string  | `""`     | Optional display label for the token. |
| `-PollSeconds`     | `--pollseconds`     | integer | `60`     | Seconds between sell quotes. |
| `-MaxIterations`   | `--maxiterations`   | integer | `1440`   | Max polls; then **sell anyway** (no “exit without trade” after buy). |
| `-BaseToken`       | `--base-token`      | string  | `speed`  | Asset to spend and receive (`speed`, `eth`, `0x…`). If equal to `-Token`, script resolves to `eth`. |
| `-BaseTokenSymbol` | `--base-token-symbol` | string | *(empty)* | Display label for base in logs. |
| `-DryRun`          | `--dry-run`         | switch  | off      | Quote and log targets; **no** swaps execute. |

---

## 3. Flow and Math

**Order of operations (do not reorder):**

1. Resolve token decimals (RPC `decimals()`; aliases default to 18).
2. **Quote buy:** `BaseToken` → `Token` for `-Amount` base.
3. **Execute buy:** `speed swap -c <Chain> --sell <BaseToken> --buy <Token> -a <Amount> -y`.
4. **Baseline:** Quote `Token` → `BaseToken` for the bought token amount. Target base return = `Amount × (1 + TargetPct/100)` (compared in raw units in-script).
5. **Poll:** Each `-PollSeconds`, quote full position `Token` → `BaseToken`. If current ≥ target → **sell** full position and exit.
6. **Max iterations:** If target never hit, sell full position and exit.

**Success metric:** base token received on exit vs `Amount` spent (minus real-world slippage and fees).

---

## 4. Running the Scripts

### PowerShell

```powershell
.\limit-order-any.ps1 -Chain base -Token speed -Amount 0.001 -TargetPct 5
.\limit-order-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -Amount 0.002 -TargetPct 2.5
.\limit-order-any.ps1 -Chain base -Token speed -Amount 0.001 -TargetPct 5 -DryRun
```

### Bash

```bash
./limit-order-any.sh --chain base --token speed --amount 0.001 --targetpct 5
./limit-order-any.sh --chain base --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf --amount 0.002 --targetpct 2.5
chmod +x limit-order-any.sh
```

---

## 5. Reading the Output

For **Base + cbBTC + SPEED** as base, a **1000 speed** buy produces a position on the order of **~0.00000333 cbBTC**; full-position sell quotes are **~10³ speed** (baseline **~997** in one dry-run window), not ETH-scale fractions. See `../LIVE-TEST-1000-SPEED.md`.

Illustrative poll line after the buy (numbers rounded for readability):

```
[22:57:10] Poll 12/1440  current: 1020.40 speed  target: 1050.00 speed  (spent: 1000.00 speed, +5.0% target)  — waiting
```

When the target is hit:

```
[23:40:02] Target reached: 1052.10 speed >= 1050.00 speed
>>> Executing: speed swap -c base --sell 0xcbB7... --buy speed -a 0.00000333 -y
```

---

## 6. Helpers (internals)

- **Get-TokenDecimals** / RPC: `decimals()` on token; non-`0x` aliases → 18.
- **Get-Quote** / `get_quote`: `speed quote --json`; require `buyAmount`.
- **Run-Sell**: `speed swap --sell <Token> --buy <BaseToken> -a <tokenAmount> -y`.

Swaps and target checks use **raw** amounts for comparisons; human **base** labels come from `-BaseToken` / `-BaseTokenSymbol`.

---

## 7. Pitfalls and Agent Notes

| Topic | Notes |
|---|---|
| Target vs baseline | Target is computed from **Amount** spent and **TargetPct**, compared against rolling **Token → BaseToken** quotes for the **full** position size. |
| Forced sell | After `MaxIterations`, the script sells even if underwater — plan size and targets accordingly. |
| Same token as base | If `-Token` and `-BaseToken` would coincide, PS1 falls back to `eth` for the buy/sell pair — see script guard. |
| Debugging | Failures usually come from `speed quote` / `speed swap` or RPC; scripts use strict error handling on swap failure. |
