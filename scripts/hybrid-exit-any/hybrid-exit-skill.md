# Hybrid Exit Skill

Complete reference for `hybrid-exit-any.ps1` and `hybrid-exit-any.sh` — the highest Sharpe exit structure in the suite, combining a fixed partial take-profit with a trailing stop on the remainder.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Exit Structure Math](#3-exit-structure-math)
4. [Script Phases](#4-script-phases)
5. [Running the Scripts](#5-running-the-scripts)
6. [Reading the Output](#6-reading-the-output)
7. [P/L Interpretation](#7-pl-interpretation)
8. [Pitfalls and Limits](#8-pitfalls-and-limits)

---

## 1. Concept

Every other exit structure in the suite is binary: either a fixed single target (`limit-order-any`, `bracket-any`) or a pure trailing stop (`trailing-stop-any`). The hybrid exit combines both:

1. **Phase A — Fixed take:** hold the full position and wait for price to reach `TakePct%` above baseline. When it fires, sell `ExitFraction%` (default 50%) at market. This half is locked at a guaranteed profit.
2. **Phase C — Trail the remainder:** trail the remaining `(100 - ExitFraction)%` with a `TrailPct%` trailing stop. This half captures continued upside if the move extends.

The fixed first sell eliminates the "gave back all gains" scenario. The trailing second sell eliminates the "sold too early" scenario. Together they produce a better expected value than either alone across almost all price paths.

**Why this is the highest Sharpe structure:**

- Pure trailing stop: if price reverses from entry before peaking, you lose. If you win, the trail fires on the way down — you give back `TrailPct%` of the peak gain.
- Pure fixed target: you always exit exactly at `TakePct%`. If the move extends 3x, you left it all on the table.
- Hybrid: the first half exits at a known profit. The second half gets the tail of the move if it exists, capped by `TrailPct%` of the peak gain.

**Hard stop:** active in both phases. In Phase A it fires on the full position. In Phase C it fires on the remainder only. The hard stop prevents catastrophic loss on the full position before any profit is secured.

**How it differs from `ladder-sell-any`:**

`ladder-sell-any` sells fixed tranches at fixed rungs — all exits are pre-defined targets. The hybrid exit trails the second half, letting the market determine the top exit rather than pre-committing to a price.

---

## 2. Parameters Reference

| Parameter (PS1)  | Flag (SH)           | Type    | Default  | Description |
|---|---|---|---|---|
| `-Chain`         | `--chain`           | string  | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`         | `--token`           | string  | required | Token contract address or alias (`speed`). ETH is always the quote currency. |
| `-Amount`        | `--amount`          | string  | required | ETH to spend on the initial buy. |
| `-TakePct`       | `--take-pct`        | float   | required | % above baseline to trigger the first partial sell. |
| `-ExitFraction`  | `--exit-fraction`   | float   | `50`     | % of position to sell at the take target. Valid: 1-99. Remainder is `100 - ExitFraction`. |
| `-TrailPct`      | `--trail-pct`       | float   | `5`      | Trailing stop % applied to the remainder after partial exit. |
| `-StopPct`       | `--stop-pct`        | float   | `10`     | Hard stop: % below baseline triggering full sell (Phase A) or remainder sell (Phase C). |
| `-TokenSymbol`   | `--tokensymbol`     | string  | address  | Display label for the token in output. |
| `-PollSeconds`   | `--pollseconds`     | integer | `60`     | Seconds between price polls. |
| `-MaxIterations` | `--maxiterations`   | integer | `1440`   | Max total polls (Phase A + Phase C). Falls back to market sell on timeout. |
| `-DryRun`        | `--dry-run`         | switch  | off      | Simulate all phases without executing any swaps. |

---

## 3. Exit Structure Math

### Baseline

`baselineRaw` = post-buy sell quote for `refTokenStr` → ETH. This is the anchor for all exit levels, consistent with `bracket-any` and `trailing-stop-any`.

### Phase A levels

```
takeTargetRaw  = baselineRaw * (1 + TakePct / 100)
stopThreshRaw  = baselineRaw * (1 - StopPct / 100)

Phase A fires when:
  currentRaw >= takeTargetRaw  (take profit -> Phase B)
  OR
  currentRaw <= stopThreshRaw  (hard stop -> sell full position, exit)
```

### Phase B (instantaneous)

```
partialTokenStr   = refTokenStr * (ExitFraction / 100)
remainderTokenStr = refTokenStr * (1 - ExitFraction / 100)

Sell partialTokenStr at market.
Anchor trail on remainder: peakRaw = quote(remainderTokenStr -> ETH)
```

### Phase C levels

```
floorRaw = peakRaw * (1 - TrailPct / 100)

Each poll:
  If currentRaw > peakRaw: peak rises, floor rises
  If currentRaw <= floorRaw: trail fires -> sell remainderTokenStr
  If currentRaw <= stopThreshRaw * remainderFraction: hard stop fires -> sell remainderTokenStr
```

### P/L breakdown

```
Phase A win (partial):
  profit_A = (takeTargetETH - Amount * partialFrac) / (Amount * partialFrac)

Phase C outcome depends on how far the trail runs:
  best:  trail fires near the post-take peak
  worst: trail fires immediately at floorRaw (= peakRaw * (1 - TrailPct/100))

Combined P/L approximation:
  P/L = (ethFromPartialSell + ethFromRemainderSell - Amount) / Amount * 100
```

---

## 4. Script Phases

```
Step 1 — Buy
  Quote Amount ETH -> Token (preview)
  Execute: speed swap --sell eth --buy Token -a Amount -y
  
Step 2 — Baseline quote
  Quote refTokenStr -> ETH = baselineRaw
  Compute: takeTargetRaw, stopThreshRaw, partialTokenStr, remainderTokenStr
  Display all levels

Step 3 — Phase A: poll loop
  Each poll: quote refTokenStr -> ETH
    If currentRaw <= stopThreshRaw: HARD STOP -> sell full refTokenStr, exit
    If currentRaw < takeTargetRaw:  display progress, continue
    If currentRaw >= takeTargetRaw: TAKE TARGET reached -> Phase B

  Phase B (inline):
    Sell partialTokenStr at market
    Quote remainderTokenStr -> ETH = peakRaw
    Set floorRaw = peakRaw * (1 - TrailPct/100)
    phase_b_done = true

  Phase C (same loop, phaseB_done = true):
    Each poll: quote remainderTokenStr -> ETH
    Hard stop on remainder: if rRaw <= stopThreshRaw * remainderFrac -> sell, exit
    Update peak/floor if new high
    If rRaw <= floorRaw: TRAIL fires -> sell remainderTokenStr, exit

Step 4 — Timeout
  MaxIterations reached:
    If phase_b_done: sell remainderTokenStr
    Else: sell full refTokenStr
```

---

## 5. Running the Scripts

### PowerShell — common scenarios

```powershell
# Default split: 50/50, +10% take, 5% trail, 10% hard stop
.\hybrid-exit-any.ps1 -Chain base -Token speed -Amount 0.002 -TakePct 10

# Aggressive split: exit 60% at +5%, trail 40% with tight 3% stop
.\hybrid-exit-any.ps1 -Chain base -Token speed -Amount 0.002 -TakePct 5 -ExitFraction 60 -TrailPct 3 -StopPct 8

# Conservative split: exit 33% early, let 67% run with 8% trail
.\hybrid-exit-any.ps1 -Chain base -Token speed -Amount 0.002 -TakePct 15 -ExitFraction 33 -TrailPct 8 -StopPct 12

# cbBTC: tighter levels, 60s polls
.\hybrid-exit-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -Amount 0.012 -TakePct 5 -ExitFraction 50 -TrailPct 3 -StopPct 7

# Dry run: observe all phase transitions without executing
.\hybrid-exit-any.ps1 -Chain base -Token speed -Amount 0.001 -TakePct 10 -DryRun
```

### Bash — common scenarios

```bash
# Default split
./hybrid-exit-any.sh --chain base --token speed --amount 0.002 --take-pct 10

# Aggressive split
./hybrid-exit-any.sh --chain base --token speed --amount 0.002 \
    --take-pct 5 --exit-fraction 60 --trail-pct 3 --stop-pct 8

# cbBTC
./hybrid-exit-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --amount 0.012 --take-pct 5 --exit-fraction 50 --trail-pct 3 --stop-pct 7

# Dry run
./hybrid-exit-any.sh --chain base --token speed --amount 0.002 --take-pct 10 --dry-run

# Make executable first (Linux/Mac)
chmod +x hybrid-exit-any.sh
```

---

## 6. Reading the Output

### Phase A (watching for take target)

```
[09:01:00] PHASE-A  price: 0.00044000 ETH  baseline: 0.00042000  (+4.7619% vs baseline)  take: +10%  (+5.2381% away)
[09:02:00] PHASE-A  price: 0.00045200 ETH  baseline: 0.00042000  (+7.6190% vs baseline)  take: +10%  (+2.3810% away)
[09:03:00] PHASE-A  price: 0.00046400 ETH  baseline: 0.00042000  (+10.4762% vs baseline)  take: +10%  (+0.4762% away)

Take target reached! 0.00046400 ETH  (+10.4762% vs baseline)
Selling 50% of position (0.023810 TOKEN)...
```

**Fields:**
- `price` — current ETH return for the full reference position
- `baseline` — the post-buy anchor price
- `(+X% vs baseline)` — how far above baseline current price is
- `take: +X%` — the required take-profit level
- `(+X% away)` — still needs this much more to reach target; negative when past it

Color: gray = below baseline, white = above baseline but below 50% of target, yellow = 50%+ of target, green = target reached.

### Phase C (trailing the remainder)

```
[09:04:00] PHASE-C  remainder: 0.00023400 ETH  peak: 0.00023400  floor: 0.00022230  (+0.0000% from peak)
[09:05:00] PHASE-C  remainder: 0.00024100 ETH  peak: 0.00024100  floor: 0.00022895  (+0.0000% from peak)
[09:06:00] PHASE-C  remainder: 0.00023200 ETH  peak: 0.00024100  floor: 0.00022895  (-3.7344% from peak)

Trail floor breached! Remainder: 0.00022800 ETH back
```

---

## 7. P/L Interpretation

**Entry cost:** `Amount` ETH

**Phase A exit:** ETH received from the partial sell (`ExitFraction%` of position at `TakePct%` above baseline). This portion is always profitable if take target is reached before hard stop.

**Phase C exit:** ETH received from the remainder sell. Outcome range:
- Best: price continued rising after Phase B; trail fires near a new peak
- Neutral: price stalled at the take target; trail fires near `peakRaw` (same level as the take target)
- Worst: price reversed immediately after partial sell; hard stop fires on remainder at `StopPct%` below baseline

**Break-even on full position:**

```
Required for break-even =
  (Amount - partial_ETH_received) / remainderFrac
```

If Phase A sold 50% at +10%, the remainder only needs to recover the original entry cost on its 50% share to break even overall — which means Phase C can fire at a loss on the remainder and the overall trade still profits.

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| Hard stop fires before take target | If price drops to `StopPct%` below baseline before reaching `TakePct%`, the full position is sold at a loss. No partial exit occurs. | Size `StopPct` wide enough to survive normal volatility. The gap between `TakePct` and `StopPct` defines your risk/reward. |
| Partial sell then hard stop on remainder | It's possible to lock in profit on the first half but then lose more than that on the remainder via the hard stop. | Keep `ExitFraction` >= 50 to ensure the locked profit covers a worst-case remainder loss. |
| Take target too tight | If `TakePct` is smaller than normal price oscillation, the take fires on the first bounce rather than a genuine move. | Set `TakePct` wider than your observed typical noise range. |
| Trail too tight on remainder | If `TrailPct` < typical volatility, the trail fires on the first normal dip after Phase B. | Use a wider `TrailPct` for the remainder than you would for a single-position trail, since the remainder represents smaller capital. |
| TokenAmount rounding | Token amounts are computed from the buy preview quote, not the actual fill. Actual received tokens may differ slightly. | The scripts use `refTokenStr` from the buy preview throughout, which mirrors `trailing-stop-any`'s approach. |
