## v2: configurable base token

Same behavior as `../scripts/<this-folder>/`, but the **quote currency** is not hard-coded to **ETH**. Use:

| | |
|---|---|
| **PowerShell** | `-BaseToken` (default `speed`), optional `-BaseTokenSymbol` |
| **Bash** | `--base-token` (default `speed`), optional `--base-token-symbol` |

Spend/quote amounts (e.g. `-Amount`, `-TotalAmount`, `-BasePerGrid`, `-BasePerRung`) are in **units of the base token**. Use `../scripts/` if you want ETH-only bots unchanged.

---

# Grid Trading Skill

Complete reference for `grid-trade-any.ps1` and `grid-trade-any.sh` — grid trading bots built on the `speed` CLI.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Grid Math](#3-grid-math)
4. [Cell State Model](#4-cell-state-model)
5. [Running the Scripts](#5-running-the-scripts)
6. [Reading the Status Table](#6-reading-the-status-table)
7. [P/L Interpretation](#7-pl-interpretation)
8. [Pitfalls and Limits](#8-pitfalls-and-limits)

---

## 1. Concept

Grid trading profits from a price that oscillates within a range, without requiring a directional view. You place a ladder of buy orders at regular intervals below the current price. Each time the price drops to a buy level, you buy tokens. Each time the price recovers back through the next level up, you sell those tokens for a small profit equal to the grid spacing.

**When to use it:**
- The token is ranging or oscillating with no strong trend
- You want to accumulate profits from volatility rather than hold a position
- You can tolerate capital being locked in open positions if price drops and does not recover

**How profit is made:**

Each round-trip (buy at level N, sell at level N-1) earns approximately `GridPct%` gross on that position, minus two swap fees. For example, with `GridPct = 2%` and `BasePerGrid = 200` **speed**, one completed round-trip returns ~**4** **speed** gross before fees (labels follow `-BaseToken`). Dry-run reference: `../LIVE-TEST-1000-SPEED.md` (**~197.6 speed** “base” price for the grid’s reference size).

**Key risk:** If price drops below all grid levels and does not recover, all cells become filled (capital fully deployed). No further sells occur until price recovers. At `MaxIterations`, all filled cells are sold at the prevailing market price which may be below the buy levels.

---

## 2. Parameters Reference

| Parameter (PS1) | Flag (SH) | Type | Default | Description |
|---|---|---|---|---|
| `-Chain` | `--chain` | string | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token` | `--token` | string | required | Token contract address or alias (the asset being grid-traded). |
| `-BasePerGrid` | `--eth-per-grid` | string/number | required | Base token to spend at each buy level. Bash keeps the legacy flag name `--eth-per-grid`; value is **base token** units (same as PS1 `-BasePerGrid`). Min ~0.0001 **ETH-equivalent** on 0x. |
| `-BaseToken` | `--base-token` | string | `speed` | Quote token address or alias (`speed`, `eth`, …). |
| `-BaseTokenSymbol` | `--base-token-symbol` | string | `""` | Optional display label for the base token. |
| `-Levels` | `--levels` | integer | required | Number of grid cells to create below current price. |
| `-GridPct` | `--grid-pct` | float | required | Percentage spacing between adjacent grid levels (e.g. `2` = 2%). |
| `-TokenSymbol` | `--token-symbol` | string | `""` | Optional display label for the traded token. |
| `-PollSeconds` | `--poll-seconds` | integer | `60` | Seconds between price polls. |
| `-MaxIterations` | `--max-iterations` | integer | `2880` | Max polls before forcing an exit sell (~48 h at 60 s). |
| `-DryRun` | `--dry-run` | switch | false | Simulate without executing any swaps. Quotes still run. |

**Total capital required (worst case):** `BasePerGrid * Levels` in **base token** — maximum outlay if all grid cells fill simultaneously (plus gas).

---

## 3. Grid Math

### Price metric

The bot measures price as: **how much base token is returned for a fixed reference token amount** (`refTokenAmount`).

`refTokenAmount` is determined at startup by quoting `BasePerGrid` **base token** → Token. This quantity is then used as the stable reference for all subsequent Token → base token price polls.

A higher base return = higher token price. A lower base return = lower token price.

### Reference amount derivation

```
Step 1: quote(BaseToken -> Token, amount=BasePerGrid) => refTokenAmount
Step 2: quote(Token -> BaseToken, amount=refTokenAmount) => baseRaw (raw integer, scaled by base-token decimals)
```

`baseRaw` is the baseline price. All grid levels are derived from it.

### Level formula

With `Levels = 5` and `GridPct = 2`:

```
Cell i:
  BuyLevelRaw  = baseRaw * (1 - (i+1) * GridPct/100)
  SellLevelRaw = baseRaw * (1 - i     * GridPct/100)
```

Worked example (`baseRaw` normalised to `1.0` for clarity):

| Cell | Buy Level | Sell Level | Profit if triggered |
|---|---|---|---|
| 0 | 0.98 (price -2%) | 1.00 (base) | ~2% gross |
| 1 | 0.96 (price -4%) | 0.98 | ~2% gross |
| 2 | 0.94 (price -6%) | 0.96 | ~2% gross |
| 3 | 0.92 (price -8%) | 0.94 | ~2% gross |
| 4 | 0.90 (price -10%) | 0.92 | ~2% gross |

- All cells start as `pending_buy`.
- Cell 0 triggers first (closest to current price).
- Cell 4 triggers last (furthest from current price, requires the largest drop).

### Integer arithmetic note

All raw price comparisons use the integer `buyAmount` from the `quote` JSON output (no division). Division only occurs for display formatting. This avoids floating-point precision loss in trigger logic.

---

## 4. Cell State Model

Each cell follows this lifecycle:

```
pending_buy
    |
    | price drops to BuyLevel => invoke_buy(BasePerGrid)
    |
    v
  filled  (TokenHeld = quoted token amount, base spent = BasePerGrid)
    |
    | price rises to SellLevel => invoke_sell(TokenHeld)
    |
    v
pending_buy  (cell resets, ready for next buy)
```

**On each poll, sells are processed before buys.** This ensures base token is recouped before being committed to new positions.

**Multiple levels can trigger in one poll** if the price jumps several grid steps between polls. All eligible cells are processed in a single pass.

**On MaxIterations:** all `filled` cells are sold in order (cell 0 first) at the current market price, regardless of whether the sell level has been reached.

---

## 5. Running the Scripts

### PowerShell — common scenarios

```powershell
# SPEED token, 5 levels, 2% grid, 0.001 speed per level (default base)
.\grid-trade-any.ps1 -Chain base -Token speed -BasePerGrid 0.001 -Levels 5 -GridPct 2

# cbBTC, 3 levels, 1.5% grid, 30-second polls
.\grid-trade-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -BasePerGrid 0.002 -Levels 3 -GridPct 1.5 -PollSeconds 30

# Dry run to preview grid before committing capital
.\grid-trade-any.ps1 -Chain base -Token speed `
    -BasePerGrid 0.001 -Levels 5 -GridPct 2 -DryRun

# Tight grid, many levels (ensure BasePerGrid > 0.0001 ETH-equivalent dust limit)
.\grid-trade-any.ps1 -Chain base -Token speed `
    -BasePerGrid 0.0002 -Levels 10 -GridPct 1 -PollSeconds 30
```

### Bash — common scenarios

```bash
# SPEED token, 5 levels, 2% grid
./grid-trade-any.sh --chain base --token speed \
    --eth-per-grid 0.001 --levels 5 --grid-pct 2

# cbBTC, 3 levels, 1.5% grid, 30-second polls
./grid-trade-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --token-symbol cbBTC \
    --eth-per-grid 0.002 --levels 3 --grid-pct 1.5 --poll-seconds 30

# Dry run
./grid-trade-any.sh --chain base --token speed \
    --eth-per-grid 0.001 --levels 5 --grid-pct 2 --dry-run

# Make executable first (Linux/Mac)
chmod +x grid-trade-any.sh
```

---

## 6. Reading the Status Table

Example output during a poll (magnitudes aligned with Base **cbBTC** grid dry-run: **200 speed** per cell, **~197.6 speed** session **base** in `../LIVE-TEST-1000-SPEED.md`; **~0.00000066 cbBTC** per buy quoted there):

```
[14:32:01] Price: 190.84 speed  (base: 197.63, -3.44%)  Buys: 2  Sells: 1
          P/L: -35.50 speed   Spent: 400.00 speed   Received: 364.50 speed

  #    Buy lvl (speed)  Sell lvl (speed)  Status        Token Held              Spent (speed)
  -    --------------   ----------------  ------------  ----------------------  --------------
  0    193.67           197.63          FILLED  *     0.00000066 cbBTC          200
  1    189.79           193.67          FILLED  *     0.00000067 cbBTC          200
  2    185.92           189.79          waiting       -                       -
  3    182.20           185.92          waiting       -                       -
  4    178.62           182.20          waiting       -                       -
```

**Column meanings:**

| Column | Description |
|---|---|
| `#` | Cell index (0 = closest to base price) |
| `Buy lvl (base)` | Base-token return threshold that triggers a buy (price must drop to or below this). Header uses your `-BaseToken` label (e.g. `speed`). |
| `Sell lvl (base)` | Base-token return threshold that triggers a sell (price must rise to or above this). |
| `Status` | `waiting` = no position open. `FILLED *` = token position held. |
| `Token Held` | Quoted token amount bought at this cell. Used as the sell amount. |
| `Spent (base)` | Base token spent to buy into this cell. |

**Color coding (PS1):**
- Cyan — cell is `FILLED` (holds a token position)
- DarkYellow — cell is `waiting` but price is within one grid step of triggering a buy
- White — cell is `waiting`, more than one grid step away
- Green (trigger line) — sell triggered
- Magenta (trigger line) — buy triggered

**Header line fields:**
- `Price` — current base-token return for the reference token amount
- `base` — the price captured at startup; all levels derived from this
- `%` — how far current price has moved from base (negative = price dropped)
- `Buys / Sells` — cumulative count for the session
- `P/L` — net base-token profit/loss for the session so far

---

## 7. P/L Interpretation

**`totalEthSpent` (display: base spent)** — sum of all `BasePerGrid` amounts across completed buys. Incremented immediately when a buy executes.

**`totalEthReceived` (display: base received)** — estimated sum of base token from all completed sells. After each sell swap, a second `quote` call estimates the base token that would have been received. This is an approximation — actual received amount depends on slippage at execution time.

**Running P/L formula:**

```
P/L = total_received_base - total_spent_base
```

A negative P/L during the session is normal when cells are filled but unsold. Base spent grows with each buy; base received only grows when sells execute.

**Break-even per cell:** each filled cell breaks even when its sell executes at `SellLevelRaw >= BuyLevelRaw * (1 + fee_fraction * 2)`. With ~0.05% swap fees each way, GridPct values above 0.2% cover fees. Practical minimum is 1% to leave meaningful margin after fee variance.

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| `BasePerGrid` too small | 0x API rejects swaps below ~0.0001 ETH equivalent. Buy will throw an error and skip. | Use `BasePerGrid >= 0.0002` in base units (or raise size until the API accepts). |
| Price gap between polls crosses multiple levels | All eligible cells trigger in one pass. If price drops 6% between two polls on a 2% grid, three cells fire simultaneously. Capital use spikes. | Use shorter `PollSeconds` (30s) or wider `GridPct` to reduce simultaneous triggers. |
| All cells filled, no base remaining | Grid is fully deployed. No further buys until sells execute. Session continues polling. | Ensure wallet holds enough base token: `BasePerGrid * Levels + gas buffer`. |
| Tight grids eaten by fees | 0.5% grid with 0.1% fees each way leaves only 0.3% net per round-trip — nearly zero after gas. | Keep `GridPct` at least 3-5x the round-trip fee (so >= 1% for typical 0x fees). |
| Token held string rounds to zero | Tokens with very small decimals or very large supply may produce a tiny human amount. | Script aborts the buy with an error. Increase `BasePerGrid`. |
| `DryRun` P/L uses quote, not actual fill | Quote prices include 0x spread but not slippage. Real P/L will differ slightly. | Use `DryRun` for grid preview only; verify levels look sensible before going live. |
| MaxIterations sells at a loss | If price never recovers, final forced sells execute below buy levels. | Set `MaxIterations` high enough to give the grid time to cycle. Alternatively, remove the max-iterations constraint by setting it to a very large number. |
| Sell quote fails after swap | The P/L estimate after each sell uses a second quote call. If it fails, `total_eth_received` is not updated that cycle. The actual swap still executed. | Check terminal output for `Warning: sell quote failed` lines; P/L display may lag but trades are unaffected. |
