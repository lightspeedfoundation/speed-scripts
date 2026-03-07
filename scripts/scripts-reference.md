# Trading Scripts Reference

Concise function reference for all trading bots. Each script runs standalone — `Chain`, `Token`, and `Amount` (or equivalent) are always required. All scripts support `-DryRun` unless noted. All use ETH as the quote currency.

---

## Entry + Managed Exit

These scripts execute an immediate buy and then manage the exit autonomously.

**`trailing-stop-any`** — Buy immediately, then trail a stop below the running ETH-return peak. `TrailPct` sets the floor offset below peak. Floor only moves up; never resets down. Sells when ETH return drops below floor. No take-profit target — pure peak protection. The simplest production-ready bot.

**`limit-order-any`** — Buy immediately, then poll until ETH return >= original ETH * (1 + `TargetPct`/100). Single fixed target, no trailing. Falls back to market sell after `MaxIterations`. Success is measured in ETH, not token price. The baseline for all fixed-target strategies.

**`bracket-any`** — Buy immediately, then hold a take-profit ceiling (`TakePct`) and stop-loss floor (`StopPct`) simultaneously. Both levels anchored to `baselineRaw` (post-buy sell quote). First level to fire executes the sell; the other cancels implicitly. DryRun prints exact baseline, take, and stop levels before committing. OCO logic — no trailing, no drift.

**`ladder-sell-any`** — Buy immediately with the full `Amount`, then sell in N equal tranches at predefined profit levels. `FirstRungPct` sets the first sell trigger; `RungSpacingPct` spaces each subsequent rung. Each rung sells `1/N` of the original position. Remaining tokens sold at market on timeout. Incremental exit — lock profits in stages without over-optimizing a single exit.

**`hybrid-exit-any`** — Buy immediately, then run a two-phase exit. Phase A: hold the full position and wait for price to reach `TakePct`% above baseline — then sell `ExitFraction`% (default 50%) at market, locking in guaranteed profit on that portion. Phase C: trail the remaining `(100 - ExitFraction)`% with a `TrailPct`% trailing stop, letting it compound if the move extends. Hard stop (`StopPct`) active throughout both phases — fires on the full position in Phase A, on the remainder in Phase C. The highest Sharpe exit structure: the fixed first sell eliminates "gave back all gains"; the trailing second sell eliminates "sold too early".

---

## Conditional Entry + Managed Exit

These scripts do NOT buy immediately. They wait for a signal condition, then enter and manage the exit.

**`momentum-any`** — Warm-up phase builds a rolling price window of `WindowPolls` polls. Monitoring phase fires a buy only when price breaks above the window high by `BreakoutPct`%. Post-entry exit is a trailing stop (`TrailPct`). Never spends ETH without a confirmed breakout. DryRun lets you observe window and breakout signals without committing. Trend-following regime. Optional `-VolumeConfirm` flag adds a pool depth check before any entry: quotes `Amount` vs `Amount * VolumeMultiple` ETH and rejects the breakout signal if implied price impact exceeds `MaxImpactPct`% — filters thin-pool wicks.

**`mean-revert-any`** — Continuously recalculates a rolling mean. Buys when price drops `DipPct`% below the rolling mean. Exit is either mean-recovery (`RecoverPct`% above entry) or a trailing stop (`TrailPct`) — whichever fires first. Hard stop-loss (`StopPct`) always active. Mean recomputes every poll — entry zones shift with the market. Pair with `momentum-any` on the same token for full two-regime coverage. Optional `-TimeStopMinutes`: if elapsed time exceeds the limit after warm-up, exits cleanly without a trade if no entry was made, or sells at market if holding a position.

**`crash-buy-any`** — Velocity-based crash detector. Compares each poll against a rolling baseline (`BaselinePolls` controls how many preceding polls form the baseline mean, default 1 = single prior poll). Fires on a drop >= `CrashPct`% vs baseline. Default `PollSeconds=30` for higher resolution. Post-entry exit is pure trailing stop — identical to `trailing-stop-any`. Designed for fast, sudden single-candle drops, not gradual drift. `BaselinePolls > 1` increases noise resistance at the cost of reaction speed. Optional `-TimeStopMinutes` adds a thesis timeout. **False-positive risk on thin pairs:** a single whale trade can move price by `CrashPct`% in one poll on a low-liquidity DEX pair without representing a real crash. Use wider `CrashPct` and shorter `PollSeconds` on liquid pairs; treat thin pairs with caution.

**`compression-buy-any`** — Waits for price to coil into a tight range, then enters on the breakout. Two states: WATCHING (range too wide) and ARMED (range <= `CompressionPct`% of mean). Entry fires only when ARMED and price breaks above the window high by `ExpansionPct`%. Post-entry exit is a trailing stop (`TrailPct`). Optional `-ArmTimeout` resets the arm if compression persists too long without expansion. **Key distinction from `momentum-any`:** momentum fires on any breakout; compression-buy only fires on a breakout that follows confirmed range compression — the market has been storing energy first. Lower false-positive rate; misses breakouts that occur without a prior squeeze.

---

## Accumulation Bots

These scripts do NOT take a fixed amount. They accumulate a position over time via rules.

**`ladder-buy-any`** — Builds N buy trigger levels below the current baseline price, spaced `RungSpacingPct`% apart. Each time price dips to a rung, buys `EthPerRung` ETH. Tracks the full accumulated position. `-TrailAfterN` switches into a trailing stop on the total accumulated position once N rungs have filled — does not require all rungs. `-TrailAfterN 2` on a 4-rung ladder starts trailing after the second fill, regardless of whether rungs 3-4 ever trigger. `-TrailAfterFilled` is kept as a backward-compatible alias (equivalent to `-TrailAfterN $Rungs`). Static baseline — rungs are set once at start and do not drift with the market.

**`grid-trade-any`** — Places N grid cells below current price, each spaced `GridPct`% apart. Buys `EthPerGrid` ETH when price reaches a cell's buy level. Sells each filled cell individually when price recovers one grid step. Processes sells before buys each poll. Prints a live grid status table and running P&L after every poll. Designed for oscillating/ranging markets with no directional bias. Exits all filled cells at `MaxIterations`.

**`value-average-any`** — On each interval, raises a target portfolio value by `TargetIncrement` ETH. Buys the deficit (current value below target). Optional `-AllowSell` trims the surplus when current value exceeds target. `MaxBuyPerInterval` caps runaway buys. Buys more when price is low (large deficit) and less when high — natural inverse price sensitivity. Runs for `Intervals` intervals then prints a final summary.

---

## Pure Execution Tools

These scripts have no strategy. They are execution quality tools — use them to reduce timing risk and market impact on large positions.

**`twap-buy-any`** — Splits a fixed `TotalAmount` of ETH into `N` equal slices and executes one buy per `IntervalSeconds`. No signal, no condition — every slice fires on schedule. Prints average price, price range, and per-slice variance at the end. Use when entering a large position where a single market buy would cause meaningful slippage.

**`twap-sell-any`** — No initial buy. Operates on an existing token position — takes `TokenAmount` directly (run `speed balance` first). Splits into `N` equal sell slices over `IntervalSeconds`. Tracks best and worst slice. Prints total ETH received, average price, and slice performance summary. Pure exit tool — reduces market impact when liquidating a large position.

---

## Utilities

**`_syntax-check-any`** — PowerShell syntax validator. Pass a `.ps1` filename to check for parser errors without executing the script. Used for pre-deployment validation. Not a trading bot.

---

## Script Interactions

**`crash-buy-any` + `mean-revert-any` running simultaneously on the same token** — These scripts are mechanically orthogonal (different signals: velocity vs. distance from mean), but on a genuine crash both can trigger in the same window. `mean-revert-any` sees a large dip below its rolling mean; `crash-buy-any` sees the velocity spike. The result is a silently doubled position during the exact scenario where you least want extra exposure. This may be acceptable if intentional, but it should be explicit — not a side effect of running two bots without awareness. Consider staggering entry sizes or running only one on tokens where both are deployed.

**`momentum-any` + `compression-buy-any` running simultaneously on the same token** — `momentum-any` will fire on any breakout above the window high. `compression-buy-any` will only fire on a breakout following a compression phase. Running both means some breakouts will generate a single entry (momentum only, no prior compression) and others will generate a doubled entry (both fire on a compression breakout). This is not a bug, but it should be intentional — on a compression breakout you are doubling size at exactly the moment the setup is strongest. If you want to avoid double entries, run only one.

---

## Regime Map

| Market Condition | Primary Script | Secondary |
|---|---|---|
| Trending up | `momentum-any` | `trailing-stop-any` |
| Coiling / pre-breakout | `compression-buy-any` | `momentum-any` |
| Ranging / oscillating | `mean-revert-any` | `grid-trade-any` |
| Sudden crash | `crash-buy-any` | — |
| Fixed target exit | `limit-order-any` | `bracket-any` |
| Best Sharpe exit | `hybrid-exit-any` | — |
| Scale in on dips | `ladder-buy-any` | `value-average-any` |
| Scale out on rips | `ladder-sell-any` | `twap-sell-any` |
| Large position entry | `twap-buy-any` | — |
| Large position exit | `twap-sell-any` | — |
