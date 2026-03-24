## v2: configurable base token

Same behavior as `../scripts/<this-folder>/`, but the **quote currency** is not hard-coded to **ETH**. Use:

| | |
|---|---|
| **PowerShell** | `-BaseToken` (default `speed`), optional `-BaseTokenSymbol` |
| **Bash** | `--base-token` (default `speed`), optional `--base-token-symbol` |

Spend/quote amounts (e.g. `-Amount`, `-TotalAmount`, `-BasePerGrid`, `-BasePerRung`) are in **units of the base token**. Use `../scripts/` if you want ETH-only bots unchanged.

---

# Bracket Order (OCO) Skill

Complete reference for `bracket-any.ps1` and `bracket-any.sh` — One-Cancels-Other bracket order bots built on the `speed` CLI.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Level Math](#3-level-math)
4. [Script Phases](#4-script-phases)
5. [Running the Scripts](#5-running-the-scripts)
6. [Reading the Output](#6-reading-the-output)
7. [P/L Interpretation](#7-pl-interpretation)
8. [Pitfalls and Limits](#8-pitfalls-and-limits)

---

## 1. Concept

A bracket order defines the complete risk/reward envelope of a trade at entry. After buying, two levels are set simultaneously:
- **Take-profit ceiling** — sell if price rises to +TakePct% above the entry baseline
- **Stop-loss floor** — sell if price falls to -StopPct% below the entry baseline

The first level to be hit fires the sell and exits the position. The other level is implicitly cancelled. This is the standard "bracket" or "OCO" (One-Cancels-Other) order pattern used in all professional trading systems.

**Why this matters:** Every other script in this toolkit exits on a single condition — a trail, a limit, or a mean target. A bracket defines both a maximum gain target AND a maximum loss limit simultaneously. You enter knowing exactly how much you are willing to lose and exactly what profit you are targeting.

**When to use it:**
- You have a specific price target based on technical analysis (support/resistance, Fibonacci, etc.)
- You want hard risk/reward discipline: e.g., risk 3% to make 9% (1:3 ratio)
- You want to define the trade fully at entry and walk away

**Difference from `trailing-stop-any`:** Trailing stop has no take-profit ceiling — it rides gains indefinitely. Bracket has both a ceiling and a floor, making it a fully bounded trade.

**Difference from `limit-order-any`:** Limit order has no stop-loss — it only exits at a profit target (or timeout). Bracket adds a hard floor below.

---

## 2. Parameters Reference

| Parameter (PS1)     | Flag (SH)               | Type    | Default   | Description |
|---|---|---|---|---|
| `-Chain`            | `--chain`               | string  | required  | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`            | `--token`               | string  | required  | Token contract address or alias (`speed`). |
| `-Amount`           | `--amount`              | string  | required  | **Base token** units to spend on the initial buy (same asset as `-BaseToken`). |
| `-TakePct`          | `--take-pct`            | float   | required  | % above the entry baseline (in base returned) to trigger take-profit. |
| `-StopPct`          | `--stop-pct`            | float   | required  | % below the entry baseline to trigger stop-loss. |
| `-TokenSymbol`      | `--tokensymbol`         | string  | address   | Display label for the token in output. |
| `-PollSeconds`      | `--pollseconds`         | integer | `60`      | Seconds between price polls. |
| `-MaxIterations`    | `--maxiterations`       | integer | `1440`    | Max polls before a forced market sell. |
| `-BaseToken`        | `--base-token`          | string  | `speed`   | Asset to spend and receive (e.g. `speed`, `eth`, or `0x…`). If equal to `-Token`, resolves to `eth`. |
| `-BaseTokenSymbol`  | `--base-token-symbol`   | string  | *(empty)* | Display label for the base token in logs (e.g. show `SPEED` instead of `speed`). |
| `-DryRun`           | `--dry-run`             | switch  | off       | Log bracket levels and signals without buying or selling. |

---

## 3. Level Math

### Price oracle

Price is measured as: **base token returned for the fixed token amount** (`tokenStr`) — e.g. **~10²–10³ speed** for a normal **cbBTC** position on Base when **`-BaseToken speed`**, not micro-units like **0.01 speed**.

`tokenStr` is determined at startup from the buy quote and remains constant throughout polling. A higher base return = higher price.

### Baseline

```
baselineRaw = quote(tokenStr → BaseToken) immediately after the buy executes
```

The baseline represents what you could sell the position for right now, immediately after entry. It is often a few percent below **`Amount`** base spent due to spread and slippage.

**Mainnet-shaped example (Base, cbBTC, 1000 speed spent):** position ≈ **0.00000333 cbBTC** → baseline sell quote ≈ **997.05 speed** — see `../LIVE-TEST-1000-SPEED.md`.

### Bracket levels

```
takeTarget = baselineRaw × (1 + TakePct / 100)
stopFloor  = baselineRaw × (1 − StopPct / 100)
```

Both anchored to `baselineRaw`, not to `Amount` base spent. This means:
- A 10% take-profit means you want 10% more **base** back than the post-buy baseline — not 10% more than you spent.
- A 5% stop-loss means you accept losing 5% from the post-buy baseline value.

The actual P/L vs base spent will differ slightly due to entry slippage. The skill section on P/L interpretation covers how to calculate the real return.

### Risk/reward ratio

```
R:R = TakePct / StopPct

e.g. TakePct=9, StopPct=3 → R:R = 3:1
```

A minimum 2:1 R:R is recommended. Taking trades with 1:1 or worse requires a win rate above 50% to be profitable after fees.

---

## 4. Script Phases

```
Phase 1 — Buy
  Execute: speed swap -c Chain --sell BaseToken --buy Token -a Amount -y
  (default BaseToken is speed; resolves to eth when Token is also the base)

Phase 2 — Anchor
  Quote tokenStr → BaseToken immediately after buy = baselineRaw
  takeTarget = baselineRaw × (1 + TakePct/100)
  stopFloor  = baselineRaw × (1 − StopPct/100)

Phase 3 — Bracket monitoring
  Each poll: quote tokenStr → BaseToken = currentRaw
  If currentRaw >= takeTarget: TAKE-PROFIT → sell → exit
  If currentRaw <= stopFloor:  STOP-LOSS   → sell → exit
  MaxIterations reached:       TIMEOUT     → sell → exit
```

---

## 5. Running the Scripts

### PowerShell — common scenarios

```powershell
# SPEED: 1:2 R:R (risk 5%, target 10%)
.\bracket-any.ps1 -Chain base -Token speed -Amount 0.002 -TakePct 10 -StopPct 5

# cbBTC: tighter bracket, faster polls
.\bracket-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -Amount 0.012 -TakePct 5 -StopPct 3 -PollSeconds 30

# 1:3 R:R discipline: risk 3%, target 9%
.\bracket-any.ps1 -Chain base -Token speed -Amount 0.002 -TakePct 9 -StopPct 3

# Dry run: see what levels would be set without executing
.\bracket-any.ps1 -Chain base -Token speed -Amount 0.002 -TakePct 10 -StopPct 5 -DryRun

# Tight bracket for high-conviction trade
.\bracket-any.ps1 -Chain base -Token speed -Amount 0.005 -TakePct 5 -StopPct 2 -PollSeconds 30
```

### Bash — common scenarios

```bash
# SPEED: 1:2 R:R
./bracket-any.sh --chain base --token speed --amount 0.002 --take-pct 10 --stop-pct 5

# cbBTC: faster polls
./bracket-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --amount 0.012 --take-pct 5 --stop-pct 3 --pollseconds 30

# Dry run
./bracket-any.sh --chain base --token speed --amount 0.002 \
    --take-pct 10 --stop-pct 5 --dry-run

# Make executable first (Linux/Mac)
chmod +x bracket-any.sh
```

---

## 6. Reading the Output

Digits below match a **dry-run** on Base (**cbBTC**, **1000 speed** spent, **+10% / −10%** bracket) — see `../LIVE-TEST-1000-SPEED.md`. Oracle values are **hundreds of speed**, not **10⁻⁴** (that scale was legacy **ETH**-style paste error).

### Setup block

(Default base token is **speed**; labels follow `-BaseTokenSymbol` / `--base-token-symbol` when set.)

```
=== Speed Bracket Order (OCO) ===
  Chain         : base
  Token         : cbBTC  (decimals: 8)
  Base spent    : 1000 speed
  Take-profit   : +10% above entry baseline
  Stop-loss     : -10% below entry baseline
  Poll interval : 30 s
  Max polls     : 1440

Step 3 - Baseline sell quote (cbBTC -> speed)...
  Baseline speed back : 997.05035889 speed
  Take-profit target: 1096.75539478 speed  (baseline +10%)
  Stop-loss floor   : 897.34532300 speed  (baseline -10%)
```

### Polling phase

Actual lines match `bracket-any.ps1` / `bracket-any.sh` (same formulas):

```
[22:57:10] Poll 1 / 1440 - waiting 30 s...
[22:57:10] 997.05035889 speed  (0.0000% vs entry)  TP: +10.0000% to target  SL: 10.0000% cushion to floor  [take: 1096.75539478 speed  stop: 897.34532300 speed]
```

- **`TP: +X% to target`** — \((\texttt{takeTargetRaw} - \texttt{currentRaw}) / \texttt{currentRaw} \times 100\): how far **up** (in %) the quote must move from the current poll to hit take-profit. Near zero means close to TP.
- **`SL: X% cushion to floor`** — \((\texttt{currentRaw} - \texttt{stopFloorRaw}) / \texttt{currentRaw} \times 100\): margin above the stop floor (as % of current); small or negative means stop is close or breached.

```
TAKE-PROFIT triggered! 1097.20 speed back  (+10.1% vs baseline)
>>> TAKE-PROFIT - Executing: speed swap -c base --sell 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf --buy speed -a 0.00000333 -y
```

**Field meanings:**

| Field | Description |
|---|---|
| Base amount (first column) | Current **base token** return for the full `tokenStr` position |
| `% vs entry` | Gain/loss vs the post-buy **baseline** (not vs amount spent) |
| `TP: … to target` | Percent move from current quote toward take-profit (see formula above) |
| `SL: … cushion to floor` | Percent of current quote above the stop floor (see formula above) |
| `[take: … stop: …]` | Absolute base values of both bracket levels |
| Color green | At or above take-profit — take-profit fires |
| Color red | At or below stop-loss — stop-loss fires |
| Color yellow | Within 25% of the distance from baseline to take-profit |
| Color dark red | Within 25% of the distance from baseline to stop floor |
| Color white | Between both inner zones |

---

## 7. P/L Interpretation

**Entry cost:** `Amount` in **base token** units spent

**Exit value:** Base token received when the sell swap completes

**Net P/L:**
```
P/L % = (baseReceived − Amount) / Amount × 100
```

**Note on baseline vs. Amount:** The take-profit and stop-loss are anchored to `baselineRaw` (post-buy sell quote), not `Amount`. If entry slippage is 1% (baseline ≈ 0.99 × Amount in base terms), then:

| Scenario | TakePct | Base received (approx) | P/L vs Amount |
|---|---|---|---|
| TP fires | 10% | 0.99 × 1.10 × Amount = 1.089 × Amount | +8.9% |
| SL fires | -5% | 0.99 × 0.95 × Amount = 0.940 × Amount | -6.0% |

The console shows **`% gain vs base spent`** (take-profit) or **`% vs base spent`** (stop-loss) at trigger time — that is P/L vs **Amount**, not vs baseline.

**Risk/reward in practice (1% entry slippage, 1:2 R:R TakePct=10, StopPct=5):**
```
Expected gain if TP: ~+8.9%
Expected loss if SL: ~-6.0%
Required win rate to break even: ~40%
```

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| Baseline is not Amount | Post-buy baseline is typically 1–2% below **Amount** (in base) due to slippage. Both levels are anchored to baseline, not Amount. | Account for slippage when choosing TakePct/StopPct. Use DryRun first to observe the exact baseline. |
| Stop fires immediately | If the token has high spread (5%+), the baseline may be far below Amount and the stop could fire on the first poll. | For high-spread tokens, increase StopPct or widen the bracket. Run DryRun to see baseline first. |
| Bracket doesn't adapt | Unlike a trailing stop, bracket levels are fixed at entry. If price moves strongly in your favor but then reverses, the TP may not have fired before the reversal. | For trending moves, prefer trailing stop. Bracket is best for range-bound, mean-reverting conditions. |
| MaxIterations with a losing position | On timeout, the script sells at market regardless of level. If price is between levels at timeout, you exit at current market price. | Set MaxIterations appropriately for your expected holding period. 1440 polls × 60s = 24 hours. |
| Parallel bracket + trailing stop | Running both simultaneously on the same token creates competing sells. The first to execute will leave a residual position for the second script to attempt to sell (which may fail if balance is 0). | Run only one exit script per position. |
