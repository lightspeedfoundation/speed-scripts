## v2: configurable base token

Same behavior as `../scripts/<this-folder>/`, but the **quote currency** is not hard-coded to **ETH**. Use:

| | |
|---|---|
| **PowerShell** | `-BaseToken` (default `speed`), optional `-BaseTokenSymbol` |
| **Bash** | `--base-token` (default `speed`), optional `--base-token-symbol` |

Spend/quote amounts (e.g. `-Amount`, `-TotalAmount`, `-BasePerGrid`, `-BasePerRung`) are in **units of the base token**. Use `../scripts/` if you want ETH-only bots unchanged.

---

# Compression Buy Skill

Complete reference for `compression-buy-any.ps1` and `compression-buy-any.sh` — a volatility-entry bot that waits for price to coil into a tight range before entering on the breakout.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Detection Math](#3-detection-math)
4. [Script Phases](#4-script-phases)
5. [Running the Scripts](#5-running-the-scripts)
6. [Reading the Output](#6-reading-the-output)
7. [Calibration Guide](#7-calibration-guide)
8. [Pitfalls and Limits](#8-pitfalls-and-limits)
9. [Comparison: compression-buy vs momentum-any](#9-comparison-compression-buy-vs-momentum-any)

---

## 1. Concept

Every other entry script in the suite fires on a current price condition — a dip below mean (`mean-revert`), a velocity spike (`crash-buy`), or a price breakout (`momentum`). `compression-buy-any` fires on a *setup* condition: it waits for the market to coil into a tight range, then enters when price breaks out of that range.

The rationale:
- **Volatility contracts before it expands.** Bollinger Band squeezes, ATR compression, and low-range consolidation periods historically precede the largest directional moves (in both directions).
- **Entering during compression eliminates false breakouts.** `momentum-any` fires on any price breaking the window high. `compression-buy-any` only fires on a breakout that follows a confirmed tight range — the market has been storing energy first.
- **Direction is unknown, but position is known.** This script bets on expansion from compression happening upward. It is a valid assumption because: (a) you can only go long on a DEX, and (b) in practice most compression-then-breakout entries are directional rather than random.

**How it differs from `momentum-any`:**

| | momentum-any | compression-buy-any |
|---|---|---|
| Entry condition | Price breaks above window high by BreakoutPct% | Same, BUT only when previously armed (range was compressed) |
| No compression? | Fires on any breakout | Does NOT fire — continues watching |
| False breakout exposure | High (any wick can fire) | Lower (requires compression context first) |
| Setup patience | None — reacts immediately | Requires a coiling setup before entry |

**State machine:**

```
WATCHING   -> range <= CompressionPct: transition to ARMED
ARMED      -> price >= windowHigh * (1 + ExpansionPct/100): ENTRY
ARMED      -> range > CompressionPct: transition back to WATCHING (compression lost)
ARMED      -> ArmTimeout **monitoring** polls elapsed while still compressed, without entry: transition back to WATCHING (reset). Counter increments only while `armed` stays true and range stays compressed.
```

---

## 2. Parameters Reference

| Parameter (PS1)     | Flag (SH)               | Type    | Default | Description |
|---|---|---|---|---|
| `-Chain`            | `--chain`               | string  | required | Chain name or ID (`base`, `ethereum`, etc.) |
| `-Token`            | `--token`               | string  | required | Token contract address or alias (`speed`). |
| `-Amount`           | `--amount`              | string  | required | **Base token** units to spend when expansion is confirmed (same asset as `-BaseToken`). |
| `-WindowPolls`      | `--window-polls`        | integer | `20`    | Rolling window length (samples). After the initial price, the script runs **`WindowPolls − 1`** additional warm-up polls so the window holds **`WindowPolls`** prices before monitoring. |
| `-CompressionPct`  | `--compression-pct`     | float   | `3`     | Max rolling range as % of mean to be considered compressed (arm condition). Lower = tighter squeeze required. Must be **> 0** (validated). |
| `-ExpansionPct`    | `--expansion-pct`       | float   | see below | Min % above window high while armed to trigger entry. **≥ 0**; `0` = any break at/above window high (PS1 emits a warning). **Default differs:** PowerShell **`0.5`**, Bash **`1`** — set explicitly for parity. |
| `-TrailPct`        | `--trail-pct`           | float   | `5`     | Trailing stop % applied post-entry. Must be **> 0** (validated). |
| `-ArmTimeout`      | `--arm-timeout`         | integer | `0`     | Polls armed without expansion before auto-resetting. `0` = never auto-reset. Must be **≥ 0**. |
| `-TokenSymbol`     | `--tokensymbol`         | string  | address | Display label for the token. |
| `-PollSeconds`     | `--pollseconds`         | integer | `60`    | Seconds between price polls. |
| `-MaxIterations`   | `--maxiterations`       | integer | `1440`  | Max total polls. Sells if entry made; exits cleanly if not. |
| `-BaseToken`       | `--base-token`          | string  | `speed` | Asset for quotes and spend. If equal to `-Token`, resolves to `eth`. |
| `-BaseTokenSymbol` | `--base-token-symbol`   | string  | *(empty)* | Display label for the base token in logs. |
| `-DryRun`          | `--dry-run`             | switch  | off     | Log compression/expansion signals without executing any swaps. |

---

## 3. Detection Math

All “prices” in the window are **base-token amounts returned** for selling the fixed reference size `refTokenStr` (same oracle as other v2 bots: token → base).

### Rolling window stats (computed every poll)

```
rollingMean  = average(window prices)
windowHigh   = max(window prices)
windowLow    = min(window prices)
rollingRange = (windowHigh - windowLow) / rollingMean * 100
```

### Arm condition (compression detected)

```
ARMED = true  when  rollingRange <= CompressionPct
ARMED = false when  rollingRange > CompressionPct  (compression lost)
```

### Entry condition (expansion breakout while armed)

```
expansionThresh = windowHigh * (1 + ExpansionPct / 100)
ENTRY fires when ARMED = true  AND  currentPrice >= expansionThresh
```

### ArmTimeout reset

```
If ARMED for ArmTimeout polls without entry: ARMED = false (reset)
Next compression period will re-arm.
```

### Post-entry trailing stop (identical to momentum-any)

```
On new high: peakRaw = currentRaw; floorRaw = peakRaw * (1 - TrailPct/100)
SELL when currentRaw <= floorRaw
```

---

## 4. Script Phases

```
Step 1 — Reference quote
  Quote Amount BaseToken -> Token (no buy). Record refTokenStr.

Step 2 — Initial price
  Quote refTokenStr -> BaseToken. Seed rolling window (first sample).

Step 3 — Warm-up
  Run WindowPolls − 1 additional polls (after Step 2) so the window contains
  WindowPolls samples total. Display range% and sample count each poll.

Step 4 — Monitoring loop
  Each poll: quote refTokenStr -> BaseToken = currentRaw
  Update window, recompute rollingRange, windowHigh

  IF entry already made: trailing stop mode (same as momentum-any)

  Compression state machine:
    WATCHING:
      If rollingRange <= CompressionPct: -> ARMED  (print "-- ARMED")
    ARMED:
      If rollingRange > CompressionPct: -> WATCHING  (print COMPRESSION LOST — range expanded)
      Else: increment armPollCount each poll while still compressed
        If ArmTimeout > 0 and armPollCount >= ArmTimeout: -> WATCHING  (print ARM TIMEOUT)

  Expansion check (only when ARMED):
    If currentRaw >= expansionThresh: ENTRY
      Execute buy
      Get post-buy quote = peakRaw
      Set floorRaw = peakRaw * (1 - TrailPct/100)
      Switch to trailing stop mode

Step 5 — Timeout
  MaxIterations reached: sell if entry made, else exit cleanly
```

---

## 5. Running the Scripts

### PowerShell — common scenarios

```powershell
# Default: 20-poll window, 3% compression, 0.5% expansion (PS1), 5% trail
.\compression-buy-any.ps1 -Chain base -Token speed -Amount 0.002

# Tighter compression, faster expansion
.\compression-buy-any.ps1 -Chain base -Token speed -Amount 0.002 -CompressionPct 2 -ExpansionPct 0.5 -TrailPct 4

# cbBTC: 15-poll window, tighter levels, 30s polls
.\compression-buy-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -Amount 0.012 -WindowPolls 15 -CompressionPct 2 -ExpansionPct 0.5 -TrailPct 3 -PollSeconds 30

# With arm timeout: reset if compressed for 10+ polls without expansion
.\compression-buy-any.ps1 -Chain base -Token speed -Amount 0.002 -ArmTimeout 10

# Dry run to observe compression/expansion pattern
.\compression-buy-any.ps1 -Chain base -Token speed -Amount 0.001 -CompressionPct 3 -DryRun
```

### Bash — common scenarios

```bash
# Default settings
./compression-buy-any.sh --chain base --token speed --amount 0.002

# Tighter levels
./compression-buy-any.sh --chain base --token speed --amount 0.002 \
    --compression-pct 2 --expansion-pct 0.5 --trail-pct 4

# cbBTC
./compression-buy-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --amount 0.012 --window-polls 15 --compression-pct 2 \
    --expansion-pct 0.5 --trail-pct 3 --pollseconds 30

# With arm timeout
./compression-buy-any.sh --chain base --token speed --amount 0.002 \
    --compression-pct 3 --arm-timeout 10

# Dry run
./compression-buy-any.sh --chain base --token speed --amount 0.002 \
    --compression-pct 3 --dry-run

# Make executable
chmod +x compression-buy-any.sh
```

---

## 6. Reading the Output

(Default base token is **speed**; prices below are **base-token** return for `refTokenStr` ≈ **0.00000333 cbBTC** on Base — **~10³ speed**, matching `../LIVE-TEST-1000-SPEED.md`.)

### Warm-up phase

```
[09:00:00] Warm-up 1/19 - waiting 60 s...
[09:01:00] Price: 1008.20 speed  range: 4.12%  compress<=3%  [2 samples]
[09:02:00] Price: 1005.40 speed  range: 3.87%  compress<=3%  [3 samples]
...
[09:20:00] Price: 994.50 speed  range: 2.94%  compress<=3%  [20 samples]

Warm-up complete. Range: 2.94%  Mean: 997.80 speed  (20 polls)
```

### Monitoring — watching state (not compressed yet)

```
[09:21:00] [watching] price: 1012.30 speed  win-high: 1018.60 speed  range: 4.21%  exp-thresh: 1028.79 speed  (+0.0% vs high)
```

### Monitoring — armed state (compressed)

```
[09:22:00] COMPRESSION  range: 2.88% <= 3%  mean: 998.20 speed -- ARMED
[09:23:00] [ARMED] price: 999.40 speed  win-high: 1002.50 speed  range: 2.91%  exp-thresh: 1012.53 speed  (-0.47% vs high)
[09:24:00] [ARMED] price: 1002.50 speed  win-high: 1002.50 speed  range: 2.89%  exp-thresh: 1012.53 speed  (+0.0% vs high)
[09:25:00] [ARMED] price: 1013.20 speed  win-high: 1002.50 speed  range: 2.90%  exp-thresh: 1012.53 speed  (+1.07% vs high)

EXPANSION BREAKOUT! Price 1013.20 speed >= 1012.53 speed while compressed  (+1.07% vs window high)
```

### Post-entry trailing stop

```
[09:26:00] POST-ENTRY  1018.00 speed  peak: 1018.00 speed  floor: 967.10 speed  (0.0000% from peak)
[09:27:00] POST-ENTRY  1039.50 speed  peak: 1039.50 speed  floor: 987.53 speed  (0.0000% from peak)
[09:28:00] POST-ENTRY  1015.20 speed  peak: 1039.50 speed  floor: 987.53 speed  (-2.3377% from peak)
```

**Field meanings:**
- `[watching]` — range is above CompressionPct, no entry possible
- `[ARMED]` — range is compressed, next expansion breakout fires entry
- `range: X%` — current rolling range as % of rolling mean
- `exp-thresh` — the price level that fires entry (windowHigh * (1 + ExpansionPct/100))
- `COMPRESSION LOST` — range expanded back above `CompressionPct`, arm reset (PS1 also prints “range expanded beyond …%” in the same line)
- `ARM TIMEOUT` — armed too long without breakout, arm reset

---

## 7. Calibration Guide

**CompressionPct:**

| Market | Liquid (BTC/ETH) | Mid-cap | Low-cap |
|---|---|---|---|
| Suggested | 1-2% | 2-4% | 4-6% |
| Rationale | High-frequency markets have tighter natural ranges | Mid-caps oscillate more | Low-caps are noisy; need wider threshold to avoid false arming |

**ExpansionPct:**

Lower values enter earlier on breakout (more reactive). Higher values wait for the breakout to be more confirmed (less false positives, worse entry price).

- `0` — any price at/above window high while armed fires entry (PS1 warns; Bash warns on stderr)
- `0.5` — PowerShell **default**
- `1` — Bash **default** (explicit `-ExpansionPct` on both runtimes avoids mismatch)
- `2+` — conservative; may miss fast expansions

**WindowPolls:**

Longer windows give a more statistically meaningful range measurement but require more warm-up time and react slower to changing volatility.
- 10 polls at 30s = 5 min window
- 20 polls at 60s = 20 min window
- 20 polls at 30s = 10 min window

**ArmTimeout:**

If a token enters a permanent sideways range (infinite compression), without `ArmTimeout` the script will stay armed forever until expansion fires. Setting `ArmTimeout = 10-20` resets the arm periodically, forcing a fresh compression check. If the range is genuinely permanent, the arm will just re-trigger on the next poll anyway.

**TrailPct:**

Same logic as `momentum-any` — use wider trails on volatile pairs to avoid trail-firing on normal oscillation after entry.

---

## 8. Pitfalls and Limits

| Pitfall | Details | Mitigation |
|---|---|---|
| Compression on thin pools is just noise | On a low-liquidity pair, a 2% range over 20 polls may just be quote noise, not a genuine Bollinger squeeze. There's no volume to confirm the compression is real. | Use on liquid pairs (BTC/ETH wrappers, large DEX pools). Combine with `-VolumeConfirm` on `momentum-any` if you want a similar guard here. |
| Breakout direction unknown | Compression tells you energy is coiling. It says nothing about which direction. The script only buys upward expansion. A downward expansion after compression will not fire entry (price moves away from windowHigh). | Acceptable — on a DEX you can only go long. You simply miss the downward breakout. |
| Compression reset by noisy poll | A single outlier quote can temporarily lift the range above CompressionPct, causing the arm to reset and potentially miss the next expansion tick. | Use a slightly wider `CompressionPct` to tolerate quote noise. `ArmTimeout` does not help here (it's for stale arm, not temporary dearm). |
| Entry on the trailing edge of compression | If the compression phase is ending naturally (range is about to expand organically), the first expansion tick above `windowHigh + ExpansionPct%` fires entry into what may be a short-lived pop rather than a genuine directional move. | `TrailPct` manages this — if the move is weak, the trail fires quickly and limits loss. |
| ArmTimeout too short | If `ArmTimeout` is shorter than the natural length of compression periods for the token, the arm will keep resetting before the expansion fires. | Observe the token's typical compression duration in DryRun mode first to calibrate. |

---

## 9. Comparison: compression-buy vs momentum-any

| Dimension | `momentum-any` | `compression-buy-any` |
|---|---|---|
| Entry signal | Price breakout above rolling window high | Price breakout above rolling window high AFTER confirmed compression |
| Setup requirement | None | CompressionPct range must be met |
| False positive rate | Higher (any wick above window high fires) | Lower (requires compression context) |
| Reaction speed | Immediate | Delayed by compression phase |
| Missed moves | Rarely misses a breakout | Misses breakouts that occur without a compression setup |
| Best suited for | Trending markets with clear momentum | Coiling/consolidation setups before directional moves |
| Complementary run | Run simultaneously with mean-revert for ranging regime coverage | Run simultaneously with momentum to cover both breakout types |

**Running both simultaneously on the same token** is safe. `momentum-any` will fire on the first breakout (compressed or not). `compression-buy-any` will only fire if that breakout follows a compression phase. In practice this means `momentum-any` fires more often, and `compression-buy-any` fires on the higher-quality subset. If you want to avoid double entries, run only one at a time.
