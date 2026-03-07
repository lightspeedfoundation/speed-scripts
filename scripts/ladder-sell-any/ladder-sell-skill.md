# Ladder Sell Skill

Complete reference for `ladder-sell-any.ps1` and `ladder-sell-any.sh` — ladder sell bots built on the `speed` CLI.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Rung Math](#3-rung-math)
4. [Running the Scripts](#4-running-the-scripts)
5. [Reading the Output](#5-reading-the-output)
6. [P/L Interpretation](#6-pl-interpretation)
7. [Pitfalls and Limits](#7-pitfalls-and-limits)

---

## 1. Concept

Ladder selling exits a position incrementally at multiple price targets rather than all at once. You buy once, then sell equal fractions of the position as price rises through each "rung." This solves the hardest psychological problem in trading: knowing when to take profits.

**When to use it:**
- You bought a token and expect continued upside but want guaranteed partial profits locked in
- You want to stay in a runner while de-risking as price moves in your favour
- You want a structured exit strategy instead of watching the position and second-guessing

**How profit is made:**

Each rung sells `1/N` of the original token amount when the full-position ETH return exceeds `baseline × (1 + target%)`. Rungs fire in sequence as price climbs. Any rungs not hit by `MaxIterations` are sold at the prevailing market price.

**Key difference from `limit-order-any`:** A limit order exits 100% of the position at a single target. Ladder sell exits in pieces, keeping exposure to further upside while locking in gains at each step.

**Key difference from `trailing-stop-any`:** A trailing stop follows price up and exits 100% when price reverses. Ladder sell exits portions at fixed levels, regardless of subsequent price movement.

---

## 2. Parameters Reference

| Parameter (PS1)   | Flag (SH)            | Type   | Default | Description |
|---|---|---|---|---|
| `-Chain`          | `--chain`            | string | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`          | `--token`            | string | required | Token contract address or alias (`speed`). ETH is always the quote currency. |
| `-Amount`         | `--amount`           | string | required | ETH to spend on the initial buy. |
| `-Rungs`          | `--rungs`            | integer | `4`     | Number of sell levels. The position is split into N equal tranches. |
| `-FirstRungPct`   | `--first-rung-pct`   | float  | `25`    | % gain above baseline that triggers the first sell. |
| `-RungSpacingPct` | `--rung-spacing-pct` | float  | `25`    | Additional % gain between each subsequent rung. |
| `-TokenSymbol`    | `--tokensymbol`      | string | address | Display label for the token in output. |
| `-PollSeconds`    | `--pollseconds`      | integer | `60`   | Seconds between price polls. |
| `-MaxIterations`  | `--maxiterations`    | integer | `1440` | Max polls before forcing a sell of remaining rungs (~24 h at 60 s). |

---

## 3. Rung Math

### Price oracle

The bot quotes the **full original token amount** (`tokenStr`) → ETH on every poll. This gives a single ETH return value used to check all rung targets. It is a directional price indicator, not the actual sell execution quote (which uses the rung fraction).

### Rung target formula

```
rung[i].targetRaw = baselineRaw × (1 + targetPct_i / 100)

where:
  targetPct_i = FirstRungPct + i × RungSpacingPct
  baselineRaw = quote(tokenStr → ETH) taken right after the buy
```

Worked example with defaults (`Rungs=4`, `FirstRungPct=25`, `RungSpacingPct=25`):

| Rung | Target % gain | Sell fraction | Approx ETH back (on 0.002 ETH in) |
|---|---|---|---|
| 0 | +25% | 25% of position | 0.000625 ETH |
| 1 | +50% | 25% of position | 0.000750 ETH |
| 2 | +75% | 25% of position | 0.000875 ETH |
| 3 | +100% | 25% of position | 0.001000 ETH |
| **Total** | | 100% | **0.003250 ETH** (+62.5% blended) |

### Rung sell amount

```
rungTokenStr = tokenStr / Rungs   (using token's own decimal precision)
```

All rungs sell the same token quantity. If the token amount does not divide evenly, the last rung may carry a tiny dust remainder due to floating-point formatting. This is normal and does not affect execution.

### Integer arithmetic

All rung trigger comparisons use the raw integer `buyAmount` from the quote JSON (no division). Division only occurs when formatting display values.

---

## 4. Running the Scripts

### PowerShell — common scenarios

```powershell
# SPEED, 4 rungs at +25%, +50%, +75%, +100% (defaults)
.\ladder-sell-any.ps1 -Chain base -Token speed -Amount 0.002

# cbBTC, 3 rungs at +10%, +25%, +40%
.\ladder-sell-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -Amount 0.005 -Rungs 3 -FirstRungPct 10 -RungSpacingPct 15

# Aggressive ladder: 5 rungs at +50%, +100%, +150%, +200%, +250%
.\ladder-sell-any.ps1 -Chain base -Token speed -Amount 0.001 `
    -Rungs 5 -FirstRungPct 50 -RungSpacingPct 50

# Conservative ladder: 2 rungs at +5% and +10%
.\ladder-sell-any.ps1 -Chain base -Token speed -Amount 0.003 `
    -Rungs 2 -FirstRungPct 5 -RungSpacingPct 5 -PollSeconds 30
```

### Bash — common scenarios

```bash
# SPEED, 4 rungs at +25%, +50%, +75%, +100% (defaults)
./ladder-sell-any.sh --chain base --token speed --amount 0.002

# cbBTC, 3 rungs at +10%, +25%, +40%
./ladder-sell-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --amount 0.005 --rungs 3 --first-rung-pct 10 --rung-spacing-pct 15

# Aggressive: 5 rungs at +50% spacing
./ladder-sell-any.sh --chain base --token speed --amount 0.001 \
    --rungs 5 --first-rung-pct 50 --rung-spacing-pct 50

# Make executable first (Linux/Mac)
chmod +x ladder-sell-any.sh
```

---

## 5. Reading the Output

Example console output during a poll:

```
[14:22:01] Poll 8 / 1440 - waiting 60 s...
[14:23:01] Full pos: 0.00250440 ETH  (+25.2200% vs baseline)  (0/4 sold)

Rung 0 target hit! +25.2200% gain. Selling 1/4 of position (24.5000 SPEED)...
>>> Rung 0 SELL (+25.0%): speed swap -c base --sell speed --buy eth -a 24.5000 -y
  Rung 0 sold. 1/4 rungs complete.

[14:24:01] Poll 9 / 1440 - waiting 60 s...
[14:24:31] Full pos: 0.00255120 ETH  (+27.5600% vs baseline)  (1/4 sold)
```

**Line meanings:**

| Field | Description |
|---|---|
| `Full pos: X ETH` | Current ETH return for the full original token amount (price oracle) |
| `+X% vs baseline` | % change from the post-buy baseline sell quote |
| `(N/M sold)` | How many rungs have fired vs total rungs |
| `Rung N target hit!` | Rung trigger firing; the sell swap is about to execute |
| Color green | Full position value is at or above the next unsold rung target |
| Color white | Position is profitable but below next rung target |
| Color dark red | Position is below baseline (unrealised loss) |

---

## 6. P/L Interpretation

**Actual P/L** is not tracked in the script because actual ETH received from each sell swap varies by slippage. To estimate net outcome:

```
Expected total ETH back = sum over all rungs of:
  rungTokenStr sold at each rung's target price

Net P/L ≈ total ETH received from all sells − Amount (initial buy)
```

Each rung's contribution:
- ETH in for this tranche = `Amount / Rungs`
- ETH back at rung target = `(Amount / Rungs) × (1 + targetPct / 100)`

**Blended return example** (4 rungs at 25/50/75/100%):
```
Rung 0: +25%  → contribution × 1.25
Rung 1: +50%  → contribution × 1.50
Rung 2: +75%  → contribution × 1.75
Rung 3: +100% → contribution × 2.00
Average multiplier = (1.25 + 1.50 + 1.75 + 2.00) / 4 = 1.625 (+62.5%)
```

If `MaxIterations` is reached before all rungs fire, remaining tranches are sold at market — which may be below or above their targets.

---

## 7. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| Price never reaches first rung | Token dropped after buy. MaxIterations forced sell below baseline. | Use tighter first rung (e.g. `FirstRungPct=5`) for volatile tokens, or combine with `trailing-stop-any` as a floor. |
| Rung amount too small | `Amount / Rungs` may fall below 0x dust limit (~0.0001 ETH equivalent). The sell will throw an error. | Keep `Amount / Rungs >= 0.0002` ETH equivalent. Reduce `-Rungs` or increase `-Amount`. |
| All rungs fire in one poll | If price gaps up sharply between polls, all rung conditions may be true simultaneously. All rungs are sold sequentially in that single poll. | This is correct behaviour. Use shorter `PollSeconds` if you want finer rung-by-rung execution. |
| Full-position quote used for trigger, rung-fraction used for sell | The price oracle quotes `tokenStr` (full amount), but the actual sell is `tokenStr / Rungs`. Slippage on the smaller sell will differ from the oracle quote. | Normal and expected. Smaller sells have better execution prices. |
| `MaxIterations` exits before moonshot | Conservative MaxIterations may force a sell before price reaches upper rungs. | Increase `MaxIterations`. At 60 s poll, `1440` = 24 h; `2880` = 48 h. |
| Rung sell fails | Swap error (gas, RPC, slippage). The rung stays unsold and is retried on the next poll. | Check terminal for `Warning: rung N sell failed` lines. The position is not lost; the next poll will retry. |
