# Crash Buy Skill

Complete reference for `crash-buy-any.ps1` and `crash-buy-any.sh` — velocity-based crash entry bots built on the `speed` CLI.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Velocity Signal Math](#3-velocity-signal-math)
4. [Script Phases](#4-script-phases)
5. [Running the Scripts](#5-running-the-scripts)
6. [Reading the Output](#6-reading-the-output)
7. [P/L Interpretation](#7-pl-interpretation)
8. [Pitfalls and Limits](#8-pitfalls-and-limits)

---

## 1. Concept

Crash buy detects **velocity events** — sudden sharp drops measured against a rolling baseline — and buys immediately into the capitulation. The thesis: when a token drops hard and fast (panic sell, whale dump, liquidation cascade), the move is often followed by a partial or full recovery as buyers step in.

The signal is velocity-based: compare the current price to the mean of the last `BaselinePolls` prices. If the drop exceeds `CrashPct%`, buy immediately and ride the bounce with a trailing stop.

`BaselinePolls=1` (default) compares against the immediately preceding poll — maximum sensitivity, highest false-positive rate on thin pairs. `BaselinePolls=3-5` requires the mean of several polls to be above the threshold before confirming a crash — a single whale trade on a thin pool cannot fire the signal alone.

**How it differs from `mean-revert-any`:**

| | `mean-revert-any` | `crash-buy-any` |
|---|---|---|
| Signal type | Statistical (deviation from rolling SMA) | Velocity (drop rate vs rolling baseline) |
| Entry condition | Price drifted X% below its rolling average | Price dropped X% vs recent baseline |
| Time horizon | Gradual drift over many polls | Instant spike event |
| False signal risk | Slow trends can look like dips | Single whale trade can fire on thin pairs |
| Complementary | Yes — orthogonal signals |

A token at its 30-day mean can crash 8% in 30 seconds. Mean-revert would not trigger (price is at the mean). Crash-buy would trigger immediately. These are orthogonal signals.

**Simultaneous run warning:** Running both on the same token means a genuine crash can trigger both scripts in the same window — `mean-revert-any` sees a large dip below its SMA while `crash-buy-any` sees the velocity spike. The result is a silently doubled position during the exact scenario where extra exposure is least desirable. Intentional use only — plan total exposure across concurrent scripts.

**When to use it:**
- Markets with known liquidation events or sharp wick behaviour
- Tokens with periodic large-seller pressure followed by organic recovery
- When you want to buy the initial candle of a panic sell, not the eventual statistical dip
- Higher risk / higher speed entry compared to mean-revert

**Post-entry exit:** After buying, the position is managed by a trailing stop — identical to `trailing-stop-any`. The crash thesis is that the recovery will run, so a trailing stop captures the move rather than exiting at a fixed level.

---

## 2. Parameters Reference

| Parameter (PS1)   | Flag (SH)             | Type    | Default  | Description |
|---|---|---|---|---|
| `-Chain`          | `--chain`             | string  | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`          | `--token`             | string  | required | Token contract address or alias (`speed`). ETH is always the quote currency. |
| `-Amount`         | `--amount`            | string  | required | ETH to spend when a crash is confirmed. |
| `-CrashPct`       | `--crash-pct`         | float   | required | % drop below the rolling baseline required to trigger the buy. |
| `-BaselinePolls`  | `--baseline-polls`    | integer | `1`      | Number of recent polls whose mean forms the crash baseline. `1` = single-poll comparison (maximum sensitivity). `3-5` = rolling mean; resists single-tick whale false positives on thin pairs. Detection does not begin until the window has this many entries. |
| `-TrailPct`       | `--trail-pct`         | float   | `5`      | Trailing stop % applied after buy entry. |
| `-TokenSymbol`    | `--tokensymbol`       | string  | address  | Display label for the token in output. |
| `-PollSeconds`    | `--pollseconds`       | integer | `30`     | Seconds between price polls. Default is shorter than other scripts — velocity detection needs higher frequency. |
| `-MaxIterations`  | `--maxiterations`     | integer | `2880`   | Max total polls (detection + hold). Default 2880 × 30s = 24 hours. |
| `-DryRun`         | `--dry-run`           | switch  | off      | Log crash signals without buying. |

---

## 3. Velocity Signal Math

### Price oracle

Price is measured as: **ETH returned for a fixed reference token amount** (`refTokenStr`).

`refTokenStr` is determined once at startup by quoting `Amount` ETH → Token. The same amount is used throughout.

### Crash detection

```
priceWindow  = rolling queue of the last BaselinePolls prices
baselineRaw  = mean(priceWindow)   -- excludes the current poll
currentRaw   = price from this poll

dropPct = (baselineRaw − currentRaw) / baselineRaw × 100

Crash fires when: dropPct >= CrashPct
                  AND priceWindow has accumulated >= BaselinePolls entries
```

After each poll, `currentRaw` is added to the window and the oldest entry is dropped if the window exceeds `BaselinePolls`. Detection is gated until the window is full — no false signal on the first poll.

**When `BaselinePolls=1`** (default): the window holds one entry = the immediately preceding poll. Behavior is identical to the original single-poll comparison.

**When `BaselinePolls=3`**: the baseline is the mean of the 3 preceding polls. A single anomalous poll cannot move the baseline enough to fire the signal — the whale trade would need to have already shifted the average over 3 polls before a further drop triggers entry.

### Sensitivity calibration

The effective crash threshold depends on `CrashPct`, `PollSeconds`, and `BaselinePolls`:

```
Required velocity = CrashPct% below the BaselinePolls-poll mean

e.g. CrashPct=5, PollSeconds=30, BaselinePolls=1
     → must drop 5% vs the immediately preceding 30-s tick

     CrashPct=5, PollSeconds=30, BaselinePolls=3
     → must drop 5% vs the mean of the 3 preceding ticks (90 s of context)
       a single rogue tick cannot fire this alone
```

Shorter `PollSeconds` = detects faster crashes, but also more vulnerable to transient quote noise. Higher `BaselinePolls` = more resistance to noise at the cost of slightly delayed detection.

### Post-entry trailing stop

After the crash buy executes:

```
peakRaw  = quote(refTokenStr → ETH) immediately after buy
floorRaw = peakRaw × (1 − TrailPct / 100)

Each poll: re-quote refTokenStr → ETH
  If currentRaw > peakRaw: peak and floor rise
  If currentRaw ≤ floorRaw: sell immediately
```

---

## 4. Script Phases

```
Phase 1 — Reference quote (no buy)
  Quote Amount ETH → Token to establish refTokenStr

Phase 2 — Initial price + window seed
  Quote refTokenStr → ETH = initRaw
  priceWindow = [initRaw]

Phase 3 — Crash detection loop
  Each poll:
    currentRaw = quote(refTokenStr → ETH)
    Append currentRaw to priceWindow; drop oldest if len > BaselinePolls+1
    If window not yet full: print warm-up status, continue
    baselineRaw = mean(priceWindow excluding currentRaw)
    dropPct = (baselineRaw − currentRaw) / baselineRaw × 100
    If dropPct >= CrashPct: CRASH → Phase 4
    Else: continue (window slides forward on next poll)

Phase 4 — Crash buy
  Execute: speed swap -c Chain --sell eth --buy Token -a Amount -y
  Quote post-buy price to anchor peakRaw, floorRaw

Phase 5 — Trailing stop
  Each poll: re-quote refTokenStr → ETH
  Update peak/floor if new high
  Sell if currentRaw <= floorRaw
  MaxIterations reached → sell at market
```

---

## 5. Running the Scripts

### PowerShell — common scenarios

```powershell
# SPEED: 5% crash, 5% trail — single-poll mode (default)
.\crash-buy-any.ps1 -Chain base -Token speed -Amount 0.002 -CrashPct 5 -TrailPct 5

# SPEED: 5% crash, 5% trail — 3-poll rolling baseline (recommended for thin pairs)
.\crash-buy-any.ps1 -Chain base -Token speed -Amount 0.002 -CrashPct 5 -TrailPct 5 -BaselinePolls 3

# cbBTC: tighter trigger, shorter polls, 4-poll baseline
.\crash-buy-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -Amount 0.012 -CrashPct 3 -TrailPct 3 -PollSeconds 30 -BaselinePolls 4

# Wider crash threshold to avoid noise on volatile token
.\crash-buy-any.ps1 -Chain base -Token speed -Amount 0.005 -CrashPct 8 -TrailPct 10 -PollSeconds 60

# Dry run: observe crash signals without buying
.\crash-buy-any.ps1 -Chain base -Token speed -Amount 0.001 -CrashPct 5 -DryRun
```

### Bash — common scenarios

```bash
# SPEED: 5% crash, 5% trail — single-poll mode (default)
./crash-buy-any.sh --chain base --token speed --amount 0.002 --crash-pct 5 --trail-pct 5

# SPEED: 3-poll rolling baseline — resists thin-pair false positives
./crash-buy-any.sh --chain base --token speed --amount 0.002 --crash-pct 5 --trail-pct 5 --baseline-polls 3

# cbBTC: faster polls, 4-poll baseline
./crash-buy-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --amount 0.012 --crash-pct 3 --trail-pct 3 --pollseconds 30 --baseline-polls 4

# Dry run
./crash-buy-any.sh --chain base --token speed --amount 0.002 --crash-pct 5 --dry-run

# Make executable first (Linux/Mac)
chmod +x crash-buy-any.sh
```

---

## 6. Reading the Output

### Detection phase (pre-entry)

```
[09:00:00] Warming up baseline window... (0/3 polls)
[09:00:30] Warming up baseline window... (1/3 polls)
[09:01:00] Warming up baseline window... (2/3 polls)
[09:01:30] Price: 0.00042100 ETH  baseline: 0.00042367  drop: +0.6299%  trigger: 5.00%  (-4.3701% away)
[09:02:00] Price: 0.00041800 ETH  baseline: 0.00042267  drop: +1.1047%  trigger: 5.00%  (-3.8953% away)
[09:02:30] Price: 0.00040000 ETH  baseline: 0.00041967  drop: +4.6863%  trigger: 5.00%  (-0.3137% away)
[09:03:00] Price: 0.00037900 ETH  baseline: 0.00041300  drop: +8.2324%  trigger: 5.00%  (+3.2324% away)

CRASH detected! Price dropped +8.2324% vs 3-poll baseline  (0.00041300 ETH -> 0.00037900 ETH)
```

**Field meanings (detection phase):**

| Field | Description |
|---|---|
| `Price` | Current price in ETH |
| `baseline` | Mean of the last `BaselinePolls` prices (excludes current poll) |
| `drop: +X%` | Price dropped X% below the baseline |
| `drop: -X%` | Price rose above baseline (negative = price going up) |
| `trigger: X%` | The CrashPct threshold required to enter |
| `(-X% away)` | Still needs to drop X% more to reach trigger |
| `(+X% away)` | Already past the trigger (fired) |
| Color gray | Negative drop (price rising) or warm-up |
| Color white | Small positive drop |
| Color yellow | Drop >= 50% of CrashPct |
| Color green | Crash triggered — entry fires |

### Post-entry trailing stop

Same as `trailing-stop-any` output:

```
[09:02:30] POST-ENTRY  0.00038500 ETH  peak: 0.00038500  floor: 0.00036575  (+0.0000% from peak)
[09:03:00] POST-ENTRY  0.00039200 ETH  peak: 0.00039200  floor: 0.00037240  (+0.0000% from peak)
[09:03:30] POST-ENTRY  0.00039000 ETH  peak: 0.00039200  floor: 0.00037240  (-0.5102% from peak)
```

---

## 7. P/L Interpretation

**Entry cost:** `Amount` ETH

**Exit value:** ETH received from trailing stop sell

**Net P/L:**
```
P/L % = (ethReceived − Amount) / Amount × 100
```

The crash entry typically results in buying at a price already below the pre-crash level. If the token recovers even partially, the trailing stop captures most of the bounce. If the crash continues (token trends down), the trailing stop eventually fires to limit the loss.

**Best case:** Crash is a wick — price recovers fully and overshoots, trailing stop fires at a new high.

**Worst case:** Crash is the start of a sustained downtrend — trailing stop fires shortly after entry at `entryPrice × (1 - TrailPct/100)`.

**Maximum loss** (approximately): `TrailPct%` of the post-buy entry value, plus entry slippage on both legs.

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| Single whale trade fires on thin pair | With `BaselinePolls=1`, a single large trade on a low-liquidity DEX pair can move price by `CrashPct%` in one poll without representing a real crash. | Use `BaselinePolls=3-5` on thin pairs. One trade cannot shift a 3-poll mean enough to fire. |
| Quote noise triggers false crash | A single bad API response can return an anomalous low price, triggering the buy on noise rather than a real event. | Use `CrashPct >= 5` as a minimum AND `BaselinePolls >= 3`. Tight thresholds with single-poll mode will fire on noise. |
| Crash is the start of a trend | Not all crashes recover. If the token is in a sustained downtrend, crash-buy repeatedly loses to the trailing stop. | Run only on tokens with established recovery behaviour. Avoid during broad market downturns. |
| Missing the initial wick | If the token crashes 10% in 5 seconds but your poll interval is 60 seconds, the price may partially recover before the next poll and the measured drop is only 3%. Signal missed. | Use shorter `PollSeconds` (30 or less). Default is 30 for this reason. |
| Baseline window warm-up | With `BaselinePolls=3`, the script spends 3 polls (~90s at default) building the window before crash detection begins. A crash in the first 90s is missed. | For pure speed: `BaselinePolls=1`. For false-positive resistance: accept the warm-up delay. |
| Slow grind never triggers | The window mean slides down with the price. A 1% drop per poll never fires even if total drop is 20%. | Intentional. Crash-buy targets velocity spikes, not gradual declines. Use `mean-revert-any` for gradual declines. |
| Simultaneous run with `mean-revert-any` | A genuine crash can trigger both scripts in the same window — `mean-revert-any` sees a large dip below SMA, `crash-buy-any` sees the velocity spike. Result: silently doubled position at the worst possible moment. | Intentional use only. If running both, size each `Amount` accordingly so the combined exposure is acceptable. |
| Concurrent execution with other bots | Each script has independent window state. Running all three (`momentum`, `mean-revert`, `crash-buy`) simultaneously is mechanically safe but the combined `Amount` values define your total worst-case exposure. | Plan total exposure across all concurrent scripts before starting. |
