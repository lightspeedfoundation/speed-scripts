## v2: configurable base token

Same behavior as `../scripts/<this-folder>/`, but the **quote currency** is not hard-coded to **ETH**. Use:

| | |
|---|---|
| **PowerShell** | `-BaseToken` (default `speed`), optional `-BaseTokenSymbol` |
| **Bash** | `--base-token` (default `speed`), optional `--base-token-symbol` |

Spend/quote amounts (e.g. `-Amount`, `-TotalAmount`, `-BasePerGrid`, `-BasePerRung`) are in **units of the base token**. Use `../scripts/` if you want ETH-only bots unchanged.

---

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
- You want defined risk (fixed **base token** per rung) with capital staged into N tranches
- You want an optional trailing stop to exit after **N** rungs fill, or after **all** rungs when using `-TrailAfterFilled`

**How profit is made:**

If price recovers after enough rungs fill, the exit occurs via the optional trailing stop when `-TrailAfterN` (or `-TrailAfterFilled`) is set, or via a manual sell / downstream script. The average entry price is lower than the price at startup due to buying at successively cheaper levels.

**Key difference from `grid-trade-any`:** Grid trading cycles indefinitely — it sells filled cells as price recovers, then re-buys if price drops again. Ladder buy is a one-way accumulation pattern: each rung fires once, and the position is held until the trailing stop or MaxIterations forced exit.

---

## 2. Parameters Reference

| Parameter (PS1)     | Flag (SH)             | Type   | Default | Description |
|---|---|---|---|---|
| `-Chain`            | `--chain`             | string | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`            | `--token`             | string | required | Token contract address or alias (asset being accumulated). |
| `-BasePerRung`      | `--eth-per-rung`      | string | required | Base token spent at each buy trigger. Bash keeps the legacy flag name `--eth-per-rung`; value matches PS1 `-BasePerRung`. Min ~0.0001 ETH-equivalent on 0x. |
| `-BaseToken`        | `--base-token`        | string | `speed` | Quote token (`speed`, `eth`, …). |
| `-BaseTokenSymbol`  | `--base-token-symbol` | string | (optional) | Display label for base token. |
| `-Rungs`            | `--rungs`             | integer | `4`    | Number of buy levels below current price. |
| `-RungSpacingPct`   | `--rung-spacing-pct`  | float  | `5`     | % price drop between adjacent rung triggers. |
| `-TrailPct`         | `--trail-pct`         | float  | `5`     | Trailing stop % on the accumulated position once trail mode arms. |
| `-TrailAfterN`      | `--trail-after-n`     | integer | `0`    | Arm trailing after **N** rungs have filled (`0` = disabled). Example: `4` rungs and `-TrailAfterN 2` → trail starts after 2 buys. |
| `-TrailAfterFilled` | `--trail-after-filled` | switch | off    | Back-compat: when `-TrailAfterN` is `0` (default), sets `-TrailAfterN` to `Rungs` so the trail arms only after **all** rungs fill. If you pass `-TrailAfterN` explicitly, that value is used. |
| `-TokenSymbol`      | `--tokensymbol`       | string | `""`    | Optional display label for the token. |
| `-PollSeconds`      | `--pollseconds`       | integer | `60`   | Seconds between price polls. |
| `-MaxIterations`    | `--maxiterations`     | integer | `2880` | Max polls before forcing a sell of all accumulated tokens (~48 h at 60 s). |
| `-DryRun`           | `--dry-run`           | switch | off     | Simulate without executing swaps. Quotes still run. |

**Total capital required (worst case):** `BasePerRung × Rungs` in **base token** — if all rungs fill simultaneously (plus gas).

---

## 3. Rung Math

### Price oracle

Price is measured as: **how much base token is returned for a fixed reference token amount** (`refTokenStr`).

`refTokenStr` is determined at startup by quoting `BasePerRung` **base token** → Token. This quantity is then used as the stable reference for all subsequent Token → base token price polls.

### Trigger level formula

```
refTokenStr = quote(BasePerRung BaseToken → Token)
baseRaw     = quote(refTokenStr Token → BaseToken)

rung[i].triggerRaw = baseRaw × (1 − (i+1) × RungSpacingPct / 100)
```

Worked example with `BasePerRung=0.001`, `Rungs=4`, `RungSpacingPct=5` (default base `speed`):

| Rung | Price drop | Trigger base return | Base spent |
|---|---|---|---|
| 0 | −5% from base | `baseRaw × 0.95` | 0.001 |
| 1 | −10% from base | `baseRaw × 0.90` | 0.001 |
| 2 | −15% from base | `baseRaw × 0.85` | 0.001 |
| 3 | −20% from base | `baseRaw × 0.80` | 0.001 |
| **Total outlay** | | | **0.004** base |

### Trailing stop (after trail mode arms)

When `filledCount >= TrailAfterN` (and `TrailAfterN > 0`), or after **all** rungs fill if `-TrailAfterFilled` mapped `TrailAfterN` to `Rungs`:

```
trailPeakRaw  = quote(accumulatedTokenStr → BaseToken)   at arm time
trailFloorRaw = trailPeakRaw × (1 − TrailPct / 100)

Sell when: quote(accumulatedTokenStr → BaseToken) ≤ trailFloorRaw
```

The floor rises as price recovers past the peak, but never moves down.

---

## 4. Cell State Model

Each rung follows this lifecycle:

```
waiting
   |
   | price drops to triggerRaw => invoke_buy(BasePerRung)
   |
   v
filled  (TokenStr = quoted amount, base spent = BasePerRung)

[no further state changes — rung does not reset]
```

When `TrailAfterN` rungs have filled (or all rungs, per alias), the script enters trailing stop mode on the accumulated position.

---

## 5. Running the Scripts

### PowerShell — common scenarios

```powershell
# SPEED, 4 rungs at -5%, -10%, -15%, -20% (defaults)
.\ladder-buy-any.ps1 -Chain base -Token speed -BasePerRung 0.001 -Rungs 4 -RungSpacingPct 5

# SPEED: trail after 2 of 4 rungs fill
.\ladder-buy-any.ps1 -Chain base -Token speed `
    -BasePerRung 0.001 -Rungs 4 -RungSpacingPct 5 `
    -TrailAfterN 2 -TrailPct 4

# SPEED with trailing stop exit after full accumulation (alias)
.\ladder-buy-any.ps1 -Chain base -Token speed `
    -BasePerRung 0.001 -Rungs 4 -RungSpacingPct 5 `
    -TrailAfterFilled -TrailPct 4

# cbBTC, tighter spacing, trailing stop
.\ladder-buy-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -BasePerRung 0.002 -Rungs 3 -RungSpacingPct 3 `
    -TrailAfterFilled -TrailPct 4 -PollSeconds 30

# Dry run to preview ladder before committing
.\ladder-buy-any.ps1 -Chain base -Token speed `
    -BasePerRung 0.001 -Rungs 5 -RungSpacingPct 3 -DryRun
```

### Bash — common scenarios

```bash
# SPEED, 4 rungs at -5%, -10%, -15%, -20%  (--eth-per-rung = base token spend)
./ladder-buy-any.sh --chain base --token speed --eth-per-rung 0.001 --rungs 4 --rung-spacing-pct 5

# SPEED: trail after 2 fills
./ladder-buy-any.sh --chain base --token speed \
    --eth-per-rung 0.001 --rungs 4 --rung-spacing-pct 5 \
    --trail-after-n 2 --trail-pct 4

# SPEED with trailing stop after all rungs (alias)
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

Example magnitudes match Base **`cbBTC`**, **250 speed × 4 rungs = 1000 speed** dry-run family in `../LIVE-TEST-1000-SPEED.md` (**~248.5 speed** reference price per rung setup).

Example console output:

```
[09:12:01] Poll 4 / 2880 - waiting 60 s...
[09:13:01] Price: 229.40 speed  (-7.70% from base)  Filled: 1/4

  Rung 1: BUY triggered (price 229.40 <= trigger 235.10, -10.0%)
  >>> speed swap -c base --sell speed --buy <Token> -a 250 -y
  TX: 0xabc...

[09:14:01] Poll 5 / 2880 - waiting 60 s...
[09:14:31] Price: 223.95 speed  (-9.89% from base)  Filled: 2/4
```

After trail mode arms (e.g. all rungs with `-TrailAfterFilled`):

```
All 4 rungs filled! Switching to trailing stop mode...
  Accumulated: 0.00000264 cbBTC  (cost: 1000.00 speed)
  Trail peak  : 1018.50 speed
  Trail floor : 967.58 speed  (-5%)

[10:05:01] TRAIL MODE — acc pos: 1025.40 speed  peak: 1025.40  floor: 974.13  (+0.0000% from peak)
```

**Field meanings:**

| Field | Description |
|---|---|
| `Price: X <base>` | Current base-token return for the reference token amount |
| `% from base` | Price change vs the startup baseline |
| `Filled: N/M` | Rungs that have executed buys |
| `BUY triggered` | Rung trigger firing; swap is about to execute |
| `TRAIL MODE — acc pos` | Base-token return for total accumulated position |
| `peak / floor` | Current trailing stop peak and floor levels |
| Color magenta | Buy trigger firing |
| Color green (trail) | Accumulated position at a new high |
| Color dark red (trail) | Accumulated position within 25% of trail distance to floor |

---

## 7. P/L Interpretation

**Cost basis:**
```
Average entry base per token = totalBaseSpent / accumulatedTokenHuman
```

**Current value:** `quote(accumulatedTokenStr → BaseToken)`

**P/L:**
```
P/L = currentValueBase − totalBaseSpent
```

P/L is negative during accumulation (capital deployed, no sell yet). After trail stop fires:
```
Net gain/loss % = (baseReceived − totalBaseSpent) / totalBaseSpent × 100
```

**Break-even:** Because the ladder buys at progressively lower prices, break-even for the full position is below the startup price. The % above the lowest rung trigger needed to break even depends on the spread of rung prices.

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| `BasePerRung` too small | 0x rejects swaps below ~0.0001 ETH-equivalent. Rung buy skips with a warning. | Use `BasePerRung >= 0.0002` in base units (or raise until accepted). |
| All rungs fill between two polls | If price gaps down sharply, multiple rungs can trigger in one poll. All eligible pending rungs are bought in that pass. | Normal behaviour. Use shorter `PollSeconds` for finer rung-by-rung execution. |
| All rungs fill, no trailing stop set | Script continues polling until `MaxIterations`, then sells all at market. | Add `-TrailAfterN <n> -TrailPct <pct>` or `-TrailAfterFilled -TrailPct <pct>` for automatic exit, or pair with a downstream script. |
| Trailing stop fires immediately | Price dropped further after all rungs filled, immediately breaching trail floor. | Use a tighter `RungSpacingPct` so rungs fill deeper into the dip, or increase `TrailPct`. |
| Price never reaches any rung | Token rose instead of falling. No buys executed. | Script exits at `MaxIterations` with 0 tokens accumulated and no loss. |
| Dry-run P/L is an estimate | Dry-run uses current quote prices, not actual fill prices. Real P/L will differ by slippage. | Use `-DryRun` to preview rung levels and capital requirements only. |
| Reference token amount changes intra-session | `refTokenStr` is calculated once at startup. If price moves dramatically, the reference quote price may differ from actual buy execution prices. | This is intentional — the reference is a stable oracle. Actual base spent per rung is always exactly `BasePerRung` regardless of quote drift. |
