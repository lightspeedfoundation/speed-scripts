# Ladder Buy Skill

Complete reference for `ladder-buy-any.ps1` and `ladder-buy-any.sh` — ladder buy (accumulation) bots built on the `speed` CLI.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Rung Math](#3-rung-math)
4. [Cell State Model](#4-cell-state-model)
5. [Running the Scripts](#5-running-the-scripts)
6. [Reading the Output](#6-reading-the-output)
7. [P/L Interpretation](#7-pl-interpretation)
8. [Pitfalls and Limits](#8-pitfalls-and-limits)

---

## 1. Concept

Ladder buying accumulates a position at multiple price levels as the token drops. Instead of buying all at once and hoping for the best entry, the bot waits for each successive dip to trigger a buy. This systematically lowers the average cost basis while keeping capital staged rather than fully deployed.

**When to use it:**
- You believe a token is oversold or will recover, but you want to average into a dip rather than buy all at once
- You want defined risk (fixed ETH per level) with capital staged into N tranches
- You want an automatic trailing stop to exit after full accumulation

**How profit is made:**

If price recovers after filling all rungs, the exit occurs either via the optional `-TrailAfterFilled` trailing stop (automatic) or via a manual sell / downstream script. The average entry price is lower than the price at startup due to buying at successively cheaper levels.

**Key difference from `grid-trade-any`:** Grid trading cycles indefinitely — it sells filled cells as price recovers, then re-buys if price drops again. Ladder buy is a one-way accumulation pattern: each rung fires once, and the position is held until the trailing stop or MaxIterations forced exit.

---

## 2. Parameters Reference

| Parameter (PS1)     | Flag (SH)             | Type   | Default | Description |
|---|---|---|---|---|
| `-Chain`            | `--chain`             | string | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`            | `--token`             | string | required | Token contract address or alias (`speed`). ETH is always the quote currency. |
| `-EthPerRung`       | `--eth-per-rung`      | string | required | ETH to spend at each buy trigger. Min ~0.0001 ETH. |
| `-Rungs`            | `--rungs`             | integer | `4`    | Number of buy levels below current price. |
| `-RungSpacingPct`   | `--rung-spacing-pct`  | float  | `5`     | % price drop between adjacent rung triggers. |
| `-TrailPct`         | `--trail-pct`         | float  | `5`     | Trailing stop % applied to accumulated position after all rungs fill. Only active with `-TrailAfterFilled`. |
| `-TrailAfterFilled` | `--trail-after-filled` | switch | off    | When set, start a trailing stop on the total position after all rungs execute. |
| `-TokenSymbol`      | `--tokensymbol`       | string | address | Display label for the token in output. |
| `-PollSeconds`      | `--pollseconds`       | integer | `60`   | Seconds between price polls. |
| `-MaxIterations`    | `--maxiterations`     | integer | `2880` | Max polls before forcing a sell of all accumulated tokens (~48 h at 60 s). |
| `-DryRun`           | `--dry-run`           | switch | off     | Simulate without executing swaps. Quotes still run. |

**Total capital required (worst case):** `EthPerRung × Rungs` ETH — if all rungs fill simultaneously.

---

## 3. Rung Math

### Price oracle

Price is measured as: **how much ETH is returned for a fixed reference token amount** (`refTokenStr`).

`refTokenStr` is determined at startup by quoting `EthPerRung` ETH → Token. This quantity is then used as the stable reference for all subsequent Token → ETH price polls.

### Trigger level formula

```
refTokenStr = quote(EthPerRung ETH → Token)
baseRaw     = quote(refTokenStr Token → ETH)

rung[i].triggerRaw = baseRaw × (1 − (i+1) × RungSpacingPct / 100)
```

Worked example with `EthPerRung=0.001`, `Rungs=4`, `RungSpacingPct=5`:

| Rung | Price drop | Trigger ETH return | ETH spent |
|---|---|---|---|
| 0 | −5% from base | `baseRaw × 0.95` | 0.001 |
| 1 | −10% from base | `baseRaw × 0.90` | 0.001 |
| 2 | −15% from base | `baseRaw × 0.85` | 0.001 |
| 3 | −20% from base | `baseRaw × 0.80` | 0.001 |
| **Total outlay** | | | **0.004 ETH** |

### Trailing stop (after all rungs filled)

Once all `Rungs` have executed:

```
trailPeakRaw  = quote(accumulatedTokenStr → ETH)   at the moment of full fill
trailFloorRaw = trailPeakRaw × (1 − TrailPct / 100)

Sell when: quote(accumulatedTokenStr → ETH) ≤ trailFloorRaw
```

The floor rises as price recovers past the peak, but never moves down.

---

## 4. Cell State Model

Each rung follows this lifecycle:

```
waiting
   |
   | price drops to triggerRaw => invoke_buy(EthPerRung)
   |
   v
filled  (TokenStr = quoted amount, EthSpent = EthPerRung)

[no further state changes — rung does not reset]
```

When all rungs reach `filled` state and `-TrailAfterFilled` is set, the script enters trailing stop mode on the total accumulated position.

---

## 5. Running the Scripts

### PowerShell — common scenarios

```powershell
# SPEED, 4 rungs at -5%, -10%, -15%, -20% (defaults)
.\ladder-buy-any.ps1 -Chain base -Token speed -EthPerRung 0.001 -Rungs 4 -RungSpacingPct 5

# SPEED with trailing stop exit after full accumulation
.\ladder-buy-any.ps1 -Chain base -Token speed `
    -EthPerRung 0.001 -Rungs 4 -RungSpacingPct 5 `
    -TrailAfterFilled -TrailPct 4

# cbBTC, tighter spacing, trailing stop
.\ladder-buy-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -EthPerRung 0.002 -Rungs 3 -RungSpacingPct 3 `
    -TrailAfterFilled -TrailPct 4 -PollSeconds 30

# Dry run to preview ladder before committing
.\ladder-buy-any.ps1 -Chain base -Token speed `
    -EthPerRung 0.001 -Rungs 5 -RungSpacingPct 3 -DryRun
```

### Bash — common scenarios

```bash
# SPEED, 4 rungs at -5%, -10%, -15%, -20%
./ladder-buy-any.sh --chain base --token speed --eth-per-rung 0.001 --rungs 4 --rung-spacing-pct 5

# SPEED with trailing stop
./ladder-buy-any.sh --chain base --token speed \
    --eth-per-rung 0.001 --rungs 4 --rung-spacing-pct 5 \
    --trail-after-filled --trail-pct 4

# cbBTC, tight spacing
./ladder-buy-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --eth-per-rung 0.002 --rungs 3 --rung-spacing-pct 3 \
    --trail-after-filled --trail-pct 4 --pollseconds 30

# Dry run
./ladder-buy-any.sh --chain base --token speed \
    --eth-per-rung 0.001 --rungs 5 --rung-spacing-pct 3 --dry-run

# Make executable first (Linux/Mac)
chmod +x ladder-buy-any.sh
```

---

## 6. Reading the Output

Example console output:

```
[09:12:01] Poll 4 / 2880 - waiting 60 s...
[09:13:01] Price: 0.00001754 ETH  (-7.68% from base)  Filled: 1/4

  Rung 1: BUY triggered (price 0.00001754 <= trigger 0.00001805, -10.0%)
  >>> speed swap -c base --sell eth --buy speed -a 0.001 -y
  TX: 0xabc...

[09:14:01] Poll 5 / 2880 - waiting 60 s...
[09:14:31] Price: 0.00001712 ETH  (-9.89% from base)  Filled: 2/4
```

After all rungs fill with `-TrailAfterFilled`:

```
All 4 rungs filled! Switching to trailing stop mode...
  Accumulated: 228400.00 SPEED  (cost: 0.00400000 ETH)
  Trail peak  : 0.00380000 ETH
  Trail floor : 0.00361000 ETH  (-5%)

[10:05:01] TRAIL MODE — acc pos: 0.00395000 ETH  peak: 0.00395000  floor: 0.00375250  (+0.0000% from peak)
```

**Field meanings:**

| Field | Description |
|---|---|
| `Price: X ETH` | Current ETH return for the reference token amount |
| `% from base` | Price change vs the startup baseline |
| `Filled: N/M` | Rungs that have executed buys |
| `BUY triggered` | Rung trigger firing; swap is about to execute |
| `TRAIL MODE — acc pos` | ETH return for total accumulated position |
| `peak / floor` | Current trailing stop peak and floor levels |
| Color magenta | Buy trigger firing |
| Color green (trail) | Accumulated position at a new high |
| Color dark red (trail) | Accumulated position within 25% of trail distance to floor |

---

## 7. P/L Interpretation

**Cost basis:**
```
Average entry ETH per token = totalEthSpent / accumulatedTokenHuman
```

**Current value:** `quote(accumulatedTokenStr → ETH)`

**P/L:**
```
P/L = currentValueETH − totalEthSpent
```

P/L is negative during accumulation (capital deployed, no sell yet). After trail stop fires:
```
Net gain/loss % = (ethReceived − totalEthSpent) / totalEthSpent × 100
```

**Break-even:** Because the ladder buys at progressively lower prices, break-even for the full position is below the startup price. The % above the lowest rung trigger needed to break even depends on the spread of rung prices.

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| `EthPerRung` too small | 0x rejects swaps below ~0.0001 ETH. Rung buy skips with a warning. | Use `EthPerRung >= 0.0002` ETH. |
| All rungs fill between two polls | If price gaps down sharply, multiple rungs can trigger in one poll. All eligible pending rungs are bought in that pass. | Normal behaviour. Use shorter `PollSeconds` for finer rung-by-rung execution. |
| All rungs fill, no trailing stop set | Script continues polling until `MaxIterations`, then sells all at market. | Add `-TrailAfterFilled -TrailPct <n>` for automatic exit, or pair with a downstream script. |
| Trailing stop fires immediately | Price dropped further after all rungs filled, immediately breaching trail floor. | Use a tighter `RungSpacingPct` so rungs fill deeper into the dip, or increase `TrailPct`. |
| Price never reaches any rung | Token rose instead of falling. No buys executed. | Script exits at `MaxIterations` with 0 tokens accumulated and no loss. |
| Dry-run P/L is an estimate | Dry-run uses current quote prices, not actual fill prices. Real P/L will differ by slippage. | Use `-DryRun` to preview rung levels and capital requirements only. |
| Reference token amount changes intra-session | `refTokenStr` is calculated once at startup. If price moves dramatically, the reference quote price may differ from actual buy execution prices. | This is intentional — the reference is a stable oracle. Actual ETH spent per rung is always exactly `EthPerRung` regardless of quote drift. |
