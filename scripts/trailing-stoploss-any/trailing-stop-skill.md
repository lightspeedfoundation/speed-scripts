## v2: configurable base token

Same behavior as `../scripts/<this-folder>/`, but the **quote currency** is not hard-coded to **ETH**. Use:

| | |
|---|---|
| **PowerShell** | `-BaseToken` (default `speed`), optional `-BaseTokenSymbol` |
| **Bash** | `--base-token` (default `speed`), optional `--base-token-symbol` |

`-Amount` is in **units of the base token** you spend on the initial buy. Use `../scripts/` if you want ETH-only bots unchanged.

---

# Trailing Stop-Loss Skill

Complete reference for `trailing-stop-any.ps1` and `trailing-stop-any.sh` — buy the asset with base token, then sell when **base-token return** for the position drops **TrailPct%** below the **running peak**. The floor moves up with new highs and never ratchets down.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Flow](#3-flow)
4. [Running the Scripts](#4-running-the-scripts)
5. [Reading the Output](#5-reading-the-output)
6. [Helpers (internals)](#6-helpers-internals)
7. [Agent Notes](#7-agent-notes)

---

## 1. Concept

After entry, every poll quotes **Token → BaseToken** for the fixed position size. **Peak** is the highest base return seen; **floor** = peak × (1 − TrailPct/100). When current ≤ floor, the script sells the full position.

**When to use it:**
- You want to ride upside but cap give-back from the top
- You are fine exiting on a timeout forced sell if the trail never breaks

Peak and floor are tracked in **raw** integer units; display uses the base token’s decimals.

---

## 2. Parameters Reference

| Parameter (PS1)    | Flag (SH)            | Type    | Default  | Description |
|---|---|---|---|---|
| `-Chain`           | `--chain`            | string  | required | Chain name or ID. |
| `-Token`           | `--token`            | string  | required | Token contract address or alias. |
| `-Amount`          | `--amount`           | string  | required | **Base token** to spend on the buy. |
| `-TrailPct`        | `--trailpct`         | float   | required | % drop from **peak** base return that triggers sell. |
| `-TokenSymbol`     | `--tokensymbol`      | string  | `""`     | Optional display label for the token. |
| `-PollSeconds`     | `--pollseconds`      | integer | `60`     | Seconds between quotes. |
| `-MaxIterations`   | `--maxiterations`    | integer | `1440`   | Max polls; then **forced sell** if not already sold. |
| `-BaseToken`       | `--base-token`       | string  | `speed`  | Quote asset (`speed`, `eth`, …). If same as `-Token`, script resolves to `eth`. |
| `-BaseTokenSymbol` | `--base-token-symbol` | string | *(empty)* | Label for base in logs. |
| `-DryRun`          | `--dry-run`          | switch  | off      | No swaps; logs peak/floor logic only. |

---

## 3. Flow

1. Resolve token decimals.
2. Quote **BaseToken → Token** for `-Amount`.
3. **Buy:** `speed swap --sell <BaseToken> --buy <Token> -a <Amount> -y`.
4. **Baseline:** Quote **Token → BaseToken** for the position size; set **peak** = that return; **floor** = peak × (1 − TrailPct/100).
5. **Poll:** Each interval, quote **Token → BaseToken** for the same token amount.  
   - If current **>** peak → peak = current, recompute floor.  
   - If current **≤** floor → sell and exit.  
   - If **MaxIterations** → sell and exit.
6. **Sell:** `speed swap --sell <Token> --buy <BaseToken> -a <tokenAmount> -y`.

---

## 4. Running the Scripts

**PowerShell:**

```powershell
.\trailing-stop-any.ps1 -Chain base -Token speed -Amount 0.001 -TrailPct 5
.\trailing-stop-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.002 -TrailPct 3
.\trailing-stop-any.ps1 -Chain base -Token speed -Amount 0.001 -TrailPct 5 -DryRun
```

**Bash** (`--trailpct` is one word, matching the script):

```bash
./trailing-stop-any.sh --chain base --token speed --amount 0.001 --trailpct 5
./trailing-stop-any.sh --chain base --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf --tokensymbol cbBTC --amount 0.002 --trailpct 3
./trailing-stop-any.sh --chain base --token speed --amount 0.001 --trailpct 5 --dry-run
chmod +x trailing-stop-any.sh
```

---

## 5. Reading the Output

With **`-Amount 1000` speed**, **cbBTC**, and **`-TrailPct 5`**, a dry-run window in `../LIVE-TEST-1000-SPEED.md` showed **peak ~995.55 speed** and **floor ~945.78 speed** for the **~0.00000333 cbBTC** position — again **~10³ speed** oracle lines.

Illustrative polls:

```
[22:57:10] Poll 3/1440  current: 995.55 speed  peak: 995.55 speed  floor: 945.77 speed  (trail 5.0%)
[22:58:10] Poll 4/1440  current: 1012.30 speed  peak: 1012.30 speed  floor: 961.69 speed  (new peak)
[22:59:10] Poll 5/1440  current: 942.00 speed  peak: 1012.30 speed  floor: 961.69 speed  — TRAIL EXIT
>>> Executing: speed swap -c base --sell 0xcbB7... --buy speed -a 0.00000333 -y
```

---

## 6. Helpers (internals)

- Decimals via RPC for `0x` tokens; aliases treated as 18 where applicable.
- Quotes: `speed quote --json`; **peak/floor** comparisons use **raw** scaled integers.
- Sell helper runs `speed swap` Token → BaseToken then exits.

---

## 7. Agent Notes

- Do not sell before a successful buy.
- Floor only updates when **peak** updates (on a strictly higher base return).
- **Debugging:** typical failures are `speed quote` / `speed swap` or RPC connectivity.
