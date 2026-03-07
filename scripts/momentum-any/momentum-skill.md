# Momentum Buy Skill

Complete reference for `momentum-any.ps1` and `momentum-any.sh` — momentum breakout entry bots built on the `speed` CLI.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Price Window and Breakout Math](#3-price-window-and-breakout-math)
4. [Script Phases](#4-script-phases)
5. [Running the Scripts](#5-running-the-scripts)
6. [Reading the Output](#6-reading-the-output)
7. [P/L Interpretation](#7-pl-interpretation)
8. [Pitfalls and Limits](#8-pitfalls-and-limits)

---

## 1. Concept

Momentum trading only enters a position when a trend is already confirmed — specifically, when price breaks to a new high above the recent price window. This eliminates the problem of buying into a downtrend. Once in, a trailing stop manages the exit.

**When to use it:**
- You want to trade breakouts rather than dips (opposite philosophy to `ladder-buy-any`)
- You want conditional entry: capital is never deployed unless the market confirms momentum
- You want a hands-free, parameter-driven trend entry + exit cycle

**The two-phase structure:**
1. **Watch phase** — observe price without committing capital. Build a window of N price samples. Wait for a breakout.
2. **Hold phase** — after breakout entry, run a trailing stop (same logic as `trailing-stop-any`).

**Key difference from `trailing-stop-any`:** `trailing-stop-any` buys immediately on launch, regardless of price direction. `momentum-any` waits for confirmation that price is making new highs before buying.

**Key difference from `limit-order-any`:** A limit order buys at a specific price level (a dip). Momentum buys when price is at a *new high* — when the market is showing strength, not weakness.

**If no breakout occurs:** The script exits cleanly at `MaxIterations` without having spent any ETH.

---

## 2. Parameters Reference

| Parameter (PS1)   | Flag (SH)         | Type   | Default | Description |
|---|---|---|---|---|
| `-Chain`          | `--chain`         | string | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`          | `--token`         | string | required | Token contract address or alias (`speed`). ETH is always the quote currency. |
| `-Amount`         | `--amount`        | string | required | ETH to spend when a breakout is confirmed. |
| `-WindowPolls`    | `--window-polls`  | integer | `20`   | Number of polls in the rolling price window. Also controls warm-up length. |
| `-BreakoutPct`    | `--breakout-pct`  | float  | `0`     | % above the window high required to confirm a breakout. `0` = any new high triggers. |
| `-TrailPct`       | `--trail-pct`     | float  | `5`     | Trailing stop % applied after buy entry. |
| `-TokenSymbol`    | `--tokensymbol`   | string | address | Display label for the token in output. |
| `-PollSeconds`    | `--pollseconds`   | integer | `60`   | Seconds between price polls. |
| `-MaxIterations`  | `--maxiterations` | integer | `1440` | Max total polls (watch + hold). If no breakout by this limit, exits without trading. |
| `-DryRun`         | `--dry-run`       | switch | off     | Log breakout signals without buying. Trailing stop simulation also skipped. |

---

## 3. Price Window and Breakout Math

### Price oracle

Price is measured as: **ETH returned for a fixed reference token amount** (`refTokenStr`).

`refTokenStr` is determined once at startup by quoting `Amount` ETH → Token. The same amount is used throughout both phases. A higher ETH return = higher price.

### Rolling window

The window is a FIFO queue of `WindowPolls` most recent price observations (raw integer `buyAmount` values).

```
windowHighRaw = max(window)
```

On each poll, the newest price is added to the end and the oldest is removed from the front.

### Breakout condition

```
breakoutThresh = windowHighRaw × (1 + BreakoutPct / 100)

Breakout fires when: currentRaw >= breakoutThresh
```

With `BreakoutPct = 0`: fires the moment price reaches a new window high.
With `BreakoutPct = 1`: fires only when price exceeds the window high by at least 1% — avoids false signals at exact high touches.

### Post-entry trailing stop

After the breakout buy executes:

```
peakRaw  = quote(refTokenStr → ETH) immediately after buy
floorRaw = peakRaw × (1 − TrailPct / 100)

Each poll: re-quote refTokenStr → ETH
  If currentRaw > peakRaw: peak and floor rise
  If currentRaw ≤ floorRaw: sell immediately
```

### Warm-up phase

The first `WindowPolls − 1` polls are warm-up only. No breakout detection occurs until the window is full. This prevents premature entry on the very first observation.

```
Total warm-up time ≈ (WindowPolls − 1) × PollSeconds
e.g. WindowPolls=20, PollSeconds=60 → 19 minutes warm-up
```

---

## 4. Script Phases

```
Phase 1 — Warm-up
  Poll WindowPolls times, building price window
  No entry possible

Phase 2 — Monitoring
  Each poll: update window, compute windowHighRaw
  Check: currentRaw >= windowHighRaw * (1 + BreakoutPct/100)
  No entry: loop continues until breakout or MaxIterations
  Breakout detected → Phase 3

Phase 3 — Entry
  Execute: speed swap -c Chain --sell eth --buy Token -a Amount -y
  Quote post-buy price to anchor trailing stop peak

Phase 4 — Trailing stop
  Each poll: re-quote refTokenStr → ETH
  Update peak if new high
  Sell if below floor (peakRaw × (1 - TrailPct/100))
  MaxIterations reached → sell at market
```

---

## 5. Running the Scripts

### PowerShell — common scenarios

```powershell
# SPEED: 20-poll window, 1% breakout confirmation, 5% trail
.\momentum-any.ps1 -Chain base -Token speed -Amount 0.002 -WindowPolls 20 -BreakoutPct 1 -TrailPct 5

# cbBTC: shorter window, faster polls
.\momentum-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -Amount 0.005 -WindowPolls 10 -BreakoutPct 0.5 -TrailPct 3 -PollSeconds 30

# Zero confirmation (any new high triggers): useful for fast-moving tokens
.\momentum-any.ps1 -Chain base -Token speed -Amount 0.001 -WindowPolls 20 -BreakoutPct 0 -TrailPct 8

# Dry run: observe window and breakout signals without buying
.\momentum-any.ps1 -Chain base -Token speed -Amount 0.002 -WindowPolls 20 -DryRun

# Long-running watcher: 2-hour window, 30-minute polls
.\momentum-any.ps1 -Chain base -Token speed -Amount 0.005 `
    -WindowPolls 4 -PollSeconds 1800 -BreakoutPct 2 -TrailPct 10 -MaxIterations 96
```

### Bash — common scenarios

```bash
# SPEED: 20-poll window, 1% breakout, 5% trail
./momentum-any.sh --chain base --token speed --amount 0.002 \
    --window-polls 20 --breakout-pct 1 --trail-pct 5

# cbBTC: shorter window, faster polls
./momentum-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --amount 0.005 --window-polls 10 --breakout-pct 0.5 --trail-pct 3 --pollseconds 30

# Dry run
./momentum-any.sh --chain base --token speed --amount 0.002 \
    --window-polls 20 --dry-run

# Make executable first (Linux/Mac)
chmod +x momentum-any.sh
```

---

## 6. Reading the Output

### Warm-up phase

```
[09:00:01] Warm-up 1/19 - waiting 60 s...
[09:01:01] Price: 0.00001850 ETH  window high: 0.00001900  (-2.63% vs high)  [2 samples]
[09:02:01] Warm-up 2/19 - waiting 60 s...
[09:02:31] Price: 0.00001872 ETH  window high: 0.00001900  (-1.47% vs high)  [3 samples]
...
Warm-up complete. Window high: 0.00001920 ETH  (20 polls)
Breakout threshold: 0.00001939 ETH  (window high + 1%)
```

### Monitoring phase (pre-entry)

```
[09:20:01] Poll 1 / 1440 - waiting 60 s...
[09:21:01] Price: 0.00001915 ETH  win-high: 0.00001920  (-0.2604%)  thresh: -1.2346% away
[09:22:01] Poll 2 / 1440 - waiting 60 s...
[09:22:31] Price: 0.00001945 ETH  win-high: 0.00001945  (+0.0000%)  thresh: -0.9901% away

BREAKOUT detected! Price 0.00001962 ETH >= threshold 0.00001939 ETH  (+2.2% vs window high)
```

### Post-entry trailing stop

```
[09:35:01] POST-ENTRY — 0.00002100 ETH  peak: 0.00002100  floor: 0.00001995  (+0.0000% from peak)
[09:36:01] POST-ENTRY — 0.00002050 ETH  peak: 0.00002100  floor: 0.00001995  (-2.3810% from peak)
[09:37:01] POST-ENTRY — 0.00001988 ETH  peak: 0.00002100  floor: 0.00001995  (-5.3333% from peak)

Trail floor breached! 0.00001988 ETH back  (+1.84% vs entry cost)
>>> speed swap -c base --sell speed --buy eth -a 98000.00 SPEED -y
```

**Field meanings:**

| Field | Description |
|---|---|
| `Price / win-high` | Current price and current window high |
| `% vs high` | How far current price is from window high |
| `thresh: X% away` | How far current price is from breakout trigger |
| `POST-ENTRY` | Script is in trailing stop mode after a buy |
| `peak / floor` | Current trail peak and floor levels |
| Color yellow | Price at or above window high (approaching breakout) |
| Color white | Pre-entry, price near high but not there yet |
| Color gray | Pre-entry, price well below window high |
| Color green (post) | New trail peak established |
| Color dark red (post) | Within 25% of trail distance to floor |

---

## 7. P/L Interpretation

**Entry cost:** `Amount` ETH

**Exit value:** ETH received from trailing stop sell

**Net P/L:**
```
P/L % = (ethReceived − Amount) / Amount × 100
```

The trailing stop ensures the minimum loss is capped at `TrailPct%` of the post-entry peak value. If price rises after entry, the floor rises with it, locking in a portion of the gain.

**Break-even:** The entry is always at a new window high. The immediate break-even from the entry price is two swap fees (~0.1–0.2% round-trip). With `TrailPct=5`, if price falls immediately after entry, the maximum loss is approximately `5% + entry slippage`.

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| Breakout fires on a false spike | A single anomalous quote can temporarily push price above the threshold. | Use `BreakoutPct >= 1` to require price to be materially above the window high, not just touching it. |
| Short window catches noise | A small `WindowPolls` window (e.g. 5) will produce frequent breakout signals on volatile tokens. | Use `WindowPolls >= 20` for 18+ decimal tokens. Calibrate based on `PollSeconds × WindowPolls = desired lookback time`. |
| Warm-up time is long | 20 polls at 60 s each = 19 minutes before any entry is possible. | Reduce `WindowPolls` or `PollSeconds` for faster entry. Trade-off: more false signals. |
| No breakout ever occurs | Token moves sideways or down. Script exits at `MaxIterations` without a trade. | No capital lost. Extend `MaxIterations` or restart script. |
| Price drops right after breakout entry | The trailing stop fires at `peakRaw × (1 - TrailPct/100)`. Peak is anchored from the post-buy quote, not the breakout price. | Normal. Widen `TrailPct` if the token is very volatile and the stop is hit too quickly. |
| `refTokenStr` mismatch after breakout | `refTokenStr` was quoted at startup. After a big price move, the actual tokens received from the buy will differ. The trailing stop tracks `refTokenStr → ETH`, not the literal wallet balance. | The trail is an indicator. Actual sell executes `refTokenStr` as the sell amount, which was the expected quantity at startup. May leave a tiny amount unsold if actual received was higher. |
| Dry-run shows repeated breakouts | In dry-run, no buy is executed, so the window continues updating. If price stays at the breakout level, multiple breakout signals will print each poll. | Expected behaviour. Dry-run is for observation only. |
