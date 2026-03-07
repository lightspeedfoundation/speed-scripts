# Mean-Reversion Buy Skill

Complete reference for `mean-revert-any.ps1` and `mean-revert-any.sh` — mean-reversion entry bots built on the `speed` CLI.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Price Window, Dip Math, and Exit Math](#3-price-window-dip-math-and-exit-math)
4. [Script Phases](#4-script-phases)
5. [Running the Scripts](#5-running-the-scripts)
6. [Reading the Output](#6-reading-the-output)
7. [P/L Interpretation](#7-pl-interpretation)
8. [Pitfalls and Limits](#8-pitfalls-and-limits)
9. [Two-Regime System](#9-two-regime-system)

---

## 1. Concept

Mean reversion is the philosophical opposite of momentum trading. Where `momentum-any` buys when price breaks to a **new high**, `mean-revert-any` buys when price drops to a **new low relative to its rolling average**. The core assumption: price will return toward its mean after a temporary dip.

**When to use it:**
- The token is ranging (oscillating around a relatively stable mean) rather than trending strongly
- You want conditional entry: capital is never deployed unless the market confirms a dip
- You want to buy weakness, not strength — the opposite of trend-following

**The two-phase structure:**
1. **Watch phase** — observe price without committing capital. Build a rolling mean of N price samples. Wait for a dip below the mean by `DipPct%`.
2. **Hold phase** — after dip entry, manage the exit via mean-recovery or trailing stop.

**Key difference from `ladder-buy-any`:** `ladder-buy-any` uses a static baseline established at script start — all dip levels are anchored to the price when the script launched. `mean-revert-any` recalculates the mean on every poll. If the market drifts up or down, the entry zone follows it. This prevents stale dip levels from triggering entries far outside the current market range.

**Key difference from `trailing-stop-any`:** `trailing-stop-any` buys immediately on launch regardless of price direction. `mean-revert-any` waits for a confirmed statistical deviation below the rolling mean before buying.

**Key difference from `momentum-any`:** Entry condition is inverted. Momentum buys new highs; mean-revert buys dips. They can run simultaneously on the same token to cover both market regimes.

**If no dip occurs:** The script exits cleanly at `MaxIterations` without having spent any ETH.

---

## 2. Parameters Reference

| Parameter (PS1)   | Flag (SH)          | Type    | Default  | Description |
|---|---|---|---|---|
| `-Chain`          | `--chain`          | string  | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`          | `--token`          | string  | required | Token contract address or alias (`speed`). ETH is always the quote currency. |
| `-Amount`         | `--amount`         | string  | required | ETH to spend when a dip is confirmed. |
| `-WindowPolls`    | `--window-polls`   | integer | `20`     | Number of polls in the rolling SMA window. Also controls warm-up length. |
| `-DipPct`         | `--dip-pct`        | float   | `3`      | % below rolling mean required to confirm a dip entry. |
| `-RecoverPct`     | `--recover-pct`    | float   | `1`      | Mean-recovery exit: sell when price >= mean × (1 − RecoverPct/100). `0` = sell at mean. Negative = sell above mean. Only used when `TrailPct = 0`. |
| `-StopPct`        | `--stop-pct`       | float   | `10`     | Hard stop-loss: % below entry price that triggers an immediate sell. Always active regardless of exit mode. |
| `-TrailPct`       | `--trail-pct`      | float   | `0`      | If > 0: use a trailing stop post-entry instead of mean-recovery. |
| `-TokenSymbol`    | `--tokensymbol`    | string  | address  | Display label for the token in output. |
| `-PollSeconds`    | `--pollseconds`    | integer | `60`     | Seconds between price polls. |
| `-MaxIterations`  | `--maxiterations`  | integer | `1440`   | Max total polls (watch + hold). If no dip by this limit, exits without trading. |
| `-DryRun`         | `--dry-run`        | switch  | off      | Log dip signals without buying. |

---

## 3. Price Window, Dip Math, and Exit Math

### Price oracle

Price is measured as: **ETH returned for a fixed reference token amount** (`refTokenStr`).

`refTokenStr` is determined once at startup by quoting `Amount` ETH → Token. The same amount is used throughout all phases. A higher ETH return = higher price.

### Rolling window (SMA)

The window is a FIFO queue of `WindowPolls` most recent price observations (raw integer `buyAmount` values).

```
rollingMean = average(window)
```

On each poll, the newest price is added to the end and the oldest is removed from the front. This means the mean continuously shifts with the market — entry zones are never stale.

### Dip condition

```
dipThresh  = rollingMean × (1 − DipPct / 100)
dipPct     = (rollingMean − currentPrice) / rollingMean × 100

Entry fires when: currentPrice <= dipThresh
             i.e. dipPct >= DipPct
```

### Exit mode A: Mean-recovery (default, TrailPct = 0)

```
recoveryTarget = rollingMean × (1 − RecoverPct / 100)

Sell fires when: currentPrice >= recoveryTarget
```

The mean keeps updating during the hold period. The recovery target follows the current market mean, not the mean at entry time. If the mean drifts up while you hold, the target rises with it.

**RecoverPct examples:**
| RecoverPct | Target | Effect |
|---|---|---|
| `1` (default) | mean × 0.99 | Sell 1% below mean. Captures the dip-bounce without waiting for exact mean touch. |
| `0` | mean × 1.00 | Sell exactly at the rolling mean. |
| `-2` | mean × 1.02 | Sell 2% above the mean. Ride an overshoot. |

**Expected gross profit** with DipPct=3, RecoverPct=1:
```
Entry at mean × 0.97, exit at mean × 0.99
Gross gain = (0.99 − 0.97) / 0.97 ≈ +2.06%
```

### Exit mode B: Trailing stop (TrailPct > 0)

After the dip buy executes:

```
peakRaw  = quote(refTokenStr → ETH) immediately after buy
floorRaw = peakRaw × (1 − TrailPct / 100)

Each poll: re-quote refTokenStr → ETH
  If currentRaw > peakRaw: peak and floor rise
  If currentRaw ≤ floorRaw: sell immediately
```

Use this when you expect the dip recovery to overshoot the mean significantly. The trailing stop lets profits run while still protecting against reversals.

### Hard stop (always active)

```
stopThresh = entryRaw × (1 − StopPct / 100)

Sell fires when: currentPrice <= stopThresh
```

`entryRaw` is the ETH sell-back value for `refTokenStr` at the moment of entry (immediately after the buy). The stop is anchored to entry value, not the rolling mean. This protects against trending-down markets where mean reversion fails — without a hard stop, a mean-reversion bot will keep holding a position that never recovers.

### Warm-up phase

The first `WindowPolls − 1` polls are warm-up only. No dip detection occurs until the window is full.

```
Total warm-up time ≈ (WindowPolls − 1) × PollSeconds
e.g. WindowPolls=20, PollSeconds=60 → 19 minutes warm-up
```

---

## 4. Script Phases

```
Phase 1 — Warm-up
  Poll WindowPolls times, building rolling price window
  No entry possible

Phase 2 — Monitoring
  Each poll: update window, compute rollingMean
  Check: currentRaw <= rollingMean × (1 − DipPct/100)
  No entry: loop continues until dip or MaxIterations
  Dip detected → Phase 3

Phase 3 — Entry
  Execute: speed swap -c Chain --sell eth --buy Token -a Amount -y
  Quote post-buy price to anchor entryRaw, stopThresh, trail peak (if enabled)

Phase 4 — Exit management (mean-recovery OR trailing stop + hard stop)
  Each poll: re-quote refTokenStr → ETH
  Hard stop check first (always): sell if below entryRaw × (1 - StopPct/100)
  Mean-recovery: sell if above rollingMean × (1 − RecoverPct/100)
  Trailing stop: update peak/floor, sell if below floor
  MaxIterations reached → sell at market
```

---

## 5. Running the Scripts

### PowerShell — common scenarios

```powershell
# SPEED: mean-recovery exit (default)
.\mean-revert-any.ps1 -Chain base -Token speed -Amount 0.002 -WindowPolls 20 -DipPct 3 -RecoverPct 1 -StopPct 10

# cbBTC: tighter dip, faster polls
.\mean-revert-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -Amount 0.012 -WindowPolls 20 -DipPct 2 -RecoverPct 0.5 -StopPct 8 -PollSeconds 60

# Trailing stop exit: ride the recovery past the mean
.\mean-revert-any.ps1 -Chain base -Token speed -Amount 0.002 `
    -DipPct 3 -TrailPct 3 -StopPct 10

# Sell above mean (overshoot capture): RecoverPct negative
.\mean-revert-any.ps1 -Chain base -Token speed -Amount 0.002 `
    -DipPct 3 -RecoverPct -2 -StopPct 10

# Dry run: observe dip signals without buying
.\mean-revert-any.ps1 -Chain base -Token speed -Amount 0.002 -WindowPolls 20 -DipPct 3 -DryRun

# Long-running watcher: 2-hour window, 30-minute polls
.\mean-revert-any.ps1 -Chain base -Token speed -Amount 0.005 `
    -WindowPolls 4 -PollSeconds 1800 -DipPct 3 -RecoverPct 1 -StopPct 15 -MaxIterations 96
```

### Bash — common scenarios

```bash
# SPEED: mean-recovery exit
./mean-revert-any.sh --chain base --token speed --amount 0.002 \
    --window-polls 20 --dip-pct 3 --recover-pct 1 --stop-pct 10

# cbBTC: tighter dip, faster polls
./mean-revert-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --amount 0.012 --window-polls 20 --dip-pct 2 --recover-pct 0.5 --stop-pct 8 --pollseconds 60

# Trailing stop exit
./mean-revert-any.sh --chain base --token speed --amount 0.002 \
    --dip-pct 3 --trail-pct 3 --stop-pct 10

# Dry run
./mean-revert-any.sh --chain base --token speed --amount 0.002 \
    --window-polls 20 --dip-pct 3 --dry-run

# Make executable first (Linux/Mac)
chmod +x mean-revert-any.sh
```

---

## 6. Reading the Output

### Warm-up phase

```
[09:00:01] Warm-up 1/19 - waiting 60 s...
[09:01:01] Price: 0.00041200 ETH  mean: 0.00041800  (dip: +1.44%)  [2 samples]
[09:02:01] Warm-up 2/19 - waiting 60 s...
[09:02:31] Price: 0.00041500 ETH  mean: 0.00041633  (dip: +0.32%)  [3 samples]
...
Warm-up complete. Rolling mean: 0.00042500 ETH  (20 polls)
Dip entry threshold : 0.00041225 ETH  (mean - 3%)
```

### Monitoring phase (pre-entry)

```
[09:20:01] Poll 1 / 1440 - waiting 60 s...
[09:21:01] Price: 0.00042100 ETH  mean: 0.00042500  dip: -0.9412%  trigger: 3.00%  (thresh: +2.13% away)
[09:22:01] Poll 2 / 1440 - waiting 60 s...
[09:22:31] Price: 0.00041600 ETH  mean: 0.00042480  dip: +2.0750%  trigger: 3.00%  (thresh: +0.96% away)
[09:24:01] Price: 0.00041100 ETH  mean: 0.00042400  dip: +3.0660%  trigger: 3.00%  (thresh: -0.02% away)

DIP detected! Price 0.00041100 ETH <= threshold 0.00041128 ETH  (3.0660% below mean)
```

**Field meanings (pre-entry):**

| Field | Description |
|---|---|
| `Price` | Current price in ETH |
| `mean` | Current rolling SMA |
| `dip: +X%` | Price is X% below the mean (positive = below mean) |
| `dip: -X%` | Price is X% above the mean (above mean, not dipping) |
| `trigger: X%` | The DipPct threshold required to enter |
| `thresh: +X% away` | Price is X% above the dip threshold (needs to fall more) |
| `thresh: -X% away` | Price is X% below the dip threshold (triggered) |
| Color gray | Price above mean — no dip |
| Color white | Price below mean, less than 50% of DipPct depth |
| Color yellow | Price dipping 50–100% of the way to trigger |
| Color green | DIP triggered — entry fires |

### Post-entry: mean-recovery mode

```
[09:35:01] POST-ENTRY  recov: 0.00041200 ETH  mean: 0.00042460  target: 0.00042035  (-2.0284% vs target)  stop<0.00036990
[09:36:01] POST-ENTRY  recov: 0.00041700 ETH  mean: 0.00042500  target: 0.00042075  (-0.8930% vs target)  stop<0.00036990
[09:37:01] POST-ENTRY  recov: 0.00042100 ETH  mean: 0.00042500  target: 0.00042075  (+0.0594% vs target)  stop<0.00036990

Recovery target reached! 0.00042100 ETH back  (+2.44% vs entry cost)
>>> speed swap -c base --sell speed --buy eth -a 98000.00 -y
```

**Field meanings (post-entry, mean-recovery):**

| Field | Description |
|---|---|
| `recov` | Current ETH return for the held position |
| `mean` | Current rolling mean (updates each poll) |
| `target` | Recovery target = mean × (1 − RecoverPct/100) |
| `% vs target` | How far current price is from target (positive = above = near exit) |
| `stop<X` | Hard stop price — sell immediately if price falls below this |
| Color green | Recovery target reached — sell fires |
| Color dark red | Price approaching hard stop |
| Color white | Holding, recovering |

### Post-entry: trailing stop mode

```
[09:35:01] POST-ENTRY  trail: 0.00041200 ETH  peak: 0.00041200  floor: 0.00039964  (+0.0000% from peak)  stop<0.00036990
[09:36:01] POST-ENTRY  trail: 0.00042100 ETH  peak: 0.00042100  floor: 0.00040837  (+0.0000% from peak)  stop<0.00036990
[09:37:01] POST-ENTRY  trail: 0.00041950 ETH  peak: 0.00042100  floor: 0.00040837  (-0.3562% from peak)  stop<0.00036990

Trail floor breached! ...
```

Same field meanings as `momentum-any` post-entry trailing stop.

---

## 7. P/L Interpretation

**Entry cost:** `Amount` ETH

**Exit value:** ETH received from sell

**Net P/L:**
```
P/L % = (ethReceived − Amount) / Amount × 100
```

**Theoretical gross profit range** (before fees, assuming exact mean reversion):

| DipPct | RecoverPct | Entry vs Mean | Exit vs Mean | Gross Gain |
|---|---|---|---|---|
| `2` | `1` | −2.00% | −1.00% | ~+1.02% |
| `3` | `1` | −3.00% | −1.00% | ~+2.06% |
| `3` | `0` | −3.00% | 0.00% | ~+3.09% |
| `3` | `-2` | −3.00% | +2.00% | ~+5.15% |
| `5` | `0` | −5.00% | 0.00% | ~+5.26% |

Swap fees are approximately 0.1–0.15% per leg (0x + gas). Round-trip ≈ 0.2–0.3%. Factor this into your `DipPct` / `RecoverPct` settings: a 3% dip with 1% recovery target gives ~2.06% gross, minus ~0.3% fees = ~1.76% net.

**Hard stop impact:** If the stop fires, maximum loss is approximately `StopPct%` of entry value plus entry slippage. Choose `StopPct` to be meaningfully larger than typical noise but smaller than a trend-failure move. For most tokens, `StopPct = 2 × DipPct` is a reasonable starting point.

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| Dip fires into a trend reversal | If the token starts a sustained downtrend, the mean will slowly fall but the dip entry will keep triggering as price falls through the mean. This is where the hard stop is critical. | Always set `StopPct`. Never run without it. Consider `StopPct = 2 × DipPct` as a minimum. |
| Mean lags during fast moves | The SMA is a lagging indicator. In a sharp spike down, the mean hasn't adjusted yet, making the dip look deeper than it is relative to the "true" current mean. | Use a smaller `WindowPolls` for faster mean response (more noise), or larger for slower response (more lag). Calibrate per token volatility. |
| Warm-up time is long | 20 polls at 60 s each = 19 minutes before any entry is possible. | Reduce `WindowPolls` or `PollSeconds`. Trade-off: less stable mean, more false signals. |
| RecoverPct = 0 may never fire | If the mean is drifting downward during recovery, the target (mean × 1.00) may keep moving out of reach. | Use `RecoverPct = 1` (default) to sell at 99% of mean, which is easier to reach, or use `TrailPct` instead. |
| Dry-run shows repeated dip signals | In dry-run, no buy is executed, so if price stays below the threshold, a dip signal prints every poll. | Expected behaviour. Dry-run is for calibration only. |
| `refTokenStr` mismatch after entry | The trailing stop and mean-recovery both quote `refTokenStr → ETH`. This was computed at startup. After a large price move, the actual tokens received from the buy may differ slightly. | Consistent with `momentum-any`. The sell executes `refTokenStr` as the sell amount. Tiny amounts may remain unsold if actual received was higher. |
| Low-liquidity tokens | On thin orderbooks, quotes can vary significantly between polls, causing false dip signals or premature exits. | Use wider `DipPct` and `StopPct` for low-liquidity tokens. |

---

## 9. Two-Regime System

`mean-revert-any` and `momentum-any` are designed to complement each other. They implement opposite entry philosophies on the same infrastructure:

| | `momentum-any` | `mean-revert-any` |
|---|---|---|
| Entry condition | Price breaks to new window **high** | Price dips below rolling **mean** |
| Market regime | Trending (breakouts) | Ranging (oscillation) |
| Entry direction | Buy strength | Buy weakness |
| Default exit | Trailing stop | Mean-recovery |
| Fails when | Price spikes then reverses immediately | Price trends down without recovering |
| Hard stop | Optional (TrailPct is the natural exit) | Mandatory (mean reversion can fail) |

**Running both simultaneously** on the same token with appropriate position sizing covers both regimes. In a trending market, momentum fires repeatedly; mean-revert either never triggers or the hard stop limits losses. In a ranging market, momentum signals are false breakouts; mean-revert captures the oscillation.

This is a complete two-sided conditional entry system. Neither script commits capital unless its specific market condition is confirmed.
