## v2: configurable base token

This watcher is **quote-only** (no swaps). It supports **any target token** and **any base token**.

| | |
|---|---|
| **PowerShell** | `-BaseToken` (default `speed`), optional `-BaseTokenSymbol` |
| **Bash** | `--base-token` (default `speed`), optional `--base-token-symbol` |

If `Token == BaseToken`, the script guards by switching base to `eth` for quotes.

---

# Market Watch Skill

Reference for `market-watch-any.ps1` and `market-watch-any.sh`.

The function:
1. Builds a fixed reference target position by quoting `BaseToken -> Token` for `Amount`.
2. Uses that reference amount to poll `Token -> BaseToken`.
3. Prints current value, `% vs baseline`, and session `[H/L]`.
4. Executes **no trades**.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Flow](#3-flow)
4. [Running the Scripts](#4-running-the-scripts)
5. [Reading the Output](#5-reading-the-output)
6. [Pitfalls and Notes](#6-pitfalls-and-notes)

---

## 1. Concept

Use this when you want live market monitoring in base-token terms without opening or closing positions.

- Baseline = first `Token -> BaseToken` quote after reference amount is derived.
- Each poll shows:
  - current base value for that reference position
  - `% vs baseline`
  - session high / low values

This is ideal for validating pair behavior and scale before running strategy scripts.

---

## 2. Parameters Reference

| Parameter (PS1) | Flag (SH) | Type | Default | Description |
|---|---|---|---|---|
| `-Chain` | `--chain` | string | required | Chain name or ID (`base`, `1`, `arbitrum`, etc.) |
| `-Token` | `--token` | string | required | Target token address or alias |
| `-Amount` | `--amount` | string | required | Base-token amount used to build reference position |
| `-TokenSymbol` | `--tokensymbol` | string | `""` | Optional label for target token in logs |
| `-BaseToken` | `--base-token` | string | `speed` | Base token for valuation |
| `-BaseTokenSymbol` | `--base-token-symbol` | string | `""` | Optional label for base token in logs |
| `-PollSeconds` | `--pollseconds` | integer | `60` | Poll interval |
| `-MaxIterations` | `--maxiterations` | integer | `0` | `0` = infinite loop; otherwise stop after N polls |

---

## 3. Flow

1. Resolve decimals for target and base token (`decimals()` for `0x` tokens, aliases default to 18).
2. Quote `BaseToken -> Token` for `Amount` to get `refTokenAmount`.
3. Quote `Token -> BaseToken` for `refTokenAmount` to set baseline.
4. Loop:
   - quote `Token -> BaseToken` for the same `refTokenAmount`
   - print current value, `% vs baseline`, session high and low

No approvals, no swaps, no state changes on-chain.

---

## 4. Running the Scripts

### PowerShell

```powershell
.\market-watch-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -Amount 1000
.\market-watch-any.ps1 -Chain base -Token speed -Amount 0.001 -BaseToken eth -PollSeconds 15
.\market-watch-any.ps1 -Chain base -Token speed -Amount 1000 -MaxIterations 50
```

### Bash

```bash
./market-watch-any.sh --chain base --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf --amount 1000
./market-watch-any.sh --chain base --token speed --amount 0.001 --base-token eth --pollseconds 15
./market-watch-any.sh --chain base --token speed --amount 1000 --maxiterations 50
chmod +x market-watch-any.sh
```

---

## 5. Reading the Output

Example shape:

```
=== Speed Market Watch (Quotes Only) ===
  Target token  : cbBTC
  Base token    : speed
  Reference buy : 1000 speed

Step 1 - Building reference position from quote (speed -> cbBTC)...
  Ref position  : 0.00000333 cbBTC

Step 2 - Baseline quote (cbBTC -> speed)...
  Baseline      : 997.05035889 speed

[22:58:10] 1002.42000000 speed  (+0.5388% vs baseline)  [H 1002.42000000 / L 997.05035889]
[22:59:10] 992.14000000 speed   (-0.4925% vs baseline)  [H 1002.42000000 / L 992.14000000]
```

Color convention:
- green = above baseline
- red = below baseline

---

## 6. Pitfalls and Notes

| Topic | Notes |
|---|---|
| Same token for base and target | Script switches base leg to `eth` to avoid a noop quote pair. |
| Small quote amounts | Very small `Amount` can produce noisy or dust-scale quotes. |
| Infinite mode | `MaxIterations=0` runs until interrupted (`Ctrl+C`). |
| Quote failures | Temporary API/RPC issues are logged; loop continues on next poll. |
