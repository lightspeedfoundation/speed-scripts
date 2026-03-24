<#
.SYNOPSIS
    Mean-reversion buy: build a rolling price mean and only buy when price dips
    -DipPct% below it. Exits when price recovers back toward the mean or at a
    hard stop-loss. Never spends base unless a confirmed dip occurs.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes -Amount of -BaseToken -> <Token> to derive a reference amount (no buy yet).
    3. Quotes that reference amount -> BaseToken to establish an initial price.
    4. Warm-up phase: polls -WindowPolls times to build the rolling price window.
    5. Detection phase: each poll updates the rolling window and computes the SMA.
       Dip condition: currentPrice <= rollingMean * (1 - DipPct/100)
    6. On dip confirmed: executes the buy (-Amount BaseToken -> Token).
    7. Post-buy exits (hard stop always active):
       a. Mean-recovery (default): sell when price >= rollingMean * (1 - RecoverPct/100).
          The mean keeps updating during the hold — target follows the market.
       b. Trailing stop (-TrailPct > 0): peak/floor trailing stop, same logic as
          momentum-any. Use when you expect the dip recovery to overshoot the mean.
       Hard stop: sell if currentPrice <= entryPrice * (1 - StopPct/100).
       Protects against trending-down markets where mean reversion fails.
    8. If -MaxIterations polls pass without a dip: exits without buying.

    Philosophical opposite of momentum-any.ps1. Run both simultaneously on the
    same token to cover both trending (momentum) and ranging (mean-reversion)
    market regimes.

    Use -DryRun to observe dip signals without buying.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    Amounts and P/L are in -BaseToken (default: speed).

.PARAMETER Amount
    Amount of -BaseToken to spend when a dip is confirmed.

.PARAMETER WindowPolls
    Number of recent polls used to compute the rolling mean (SMA).
    Warm-up requires this many polls before dip detection begins.
    Default: 20.

.PARAMETER DipPct
    % below rolling mean required to confirm a dip entry.
    Default: 3.

.PARAMETER RecoverPct
    Mean-recovery exit: sell when price >= rollingMean * (1 - RecoverPct/100).
    0 = sell at the mean. Negative = sell above the mean (ride the overshoot).
    Only used when -TrailPct is 0 (default).
    Default: 1.

.PARAMETER StopPct
    Hard stop-loss: % below entry price that triggers an immediate sell.
    Always active regardless of exit mode.
    Default: 10.

.PARAMETER TrailPct
    If > 0: use a trailing stop post-entry instead of mean-recovery exit.
    Useful when you expect the recovery to run past the mean.
    Default: 0 (mean-recovery mode).

.PARAMETER TimeStopMinutes
    Maximum minutes to run after warm-up completes before exiting regardless of price.
    0 (default) = disabled (run until MaxIterations).
    If no entry has been made: exits cleanly without a trade ("thesis did not play out").
    If an entry is held: sells at market immediately.

.PARAMETER DryRun
    Observe dip signals and log entries without buying.

.EXAMPLE
    .\mean-revert-any.ps1 -Chain base -Token speed -Amount 0.002 -WindowPolls 20 -DipPct 3 -RecoverPct 1 -StopPct 10
    .\mean-revert-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.012 -WindowPolls 20 -DipPct 2 -RecoverPct 0.5 -StopPct 8 -PollSeconds 60
    .\mean-revert-any.ps1 -Chain base -Token speed -Amount 0.002 -DipPct 3 -TrailPct 3 -StopPct 10
    .\mean-revert-any.ps1 -Chain base -Token speed -Amount 0.002 -DipPct 3 -StopPct 10 -TimeStopMinutes 240
    .\mean-revert-any.ps1 -Chain base -Token speed -Amount 0.001 -DipPct 2 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $Amount,
    [string]  $TokenSymbol   = "",
    [int]     $WindowPolls   = 20,
    [double]  $DipPct        = 3.0,
    [double]  $RecoverPct    = 1.0,
    [double]  $StopPct       = 10.0,
    [double]  $TrailPct      = 0.0,
    [int]     $PollSeconds      = 60,
    [int]     $MaxIterations    = 1440,
    [int]     $TimeStopMinutes  = 0,
    [switch]  $DryRun,
    [string]                       $BaseToken       = 'speed',
    [string]                       $BaseTokenSymbol = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Join-Path $PSScriptRoot '..') '_speed_json.ps1')

$RPC_URLS = @{
    "base"     = "https://mainnet.base.org"
    "8453"     = "https://mainnet.base.org"
    "mainnet"  = "https://eth.llamarpc.com"
    "ethereum" = "https://eth.llamarpc.com"
    "1"        = "https://eth.llamarpc.com"
    "optimism" = "https://mainnet.optimism.io"
    "op"       = "https://mainnet.optimism.io"
    "10"       = "https://mainnet.optimism.io"
    "arbitrum" = "https://arb1.arbitrum.io/rpc"
    "arb"      = "https://arb1.arbitrum.io/rpc"
    "42161"    = "https://arb1.arbitrum.io/rpc"
    "polygon"  = "https://polygon.llamarpc.com"
    "matic"    = "https://polygon.llamarpc.com"
    "137"      = "https://polygon.llamarpc.com"
    "bsc"      = "https://bsc-dataseed.binance.org"
    "bnb"      = "https://bsc-dataseed.binance.org"
    "56"       = "https://bsc-dataseed.binance.org"
}

# -- helpers -------------------------------------------------------------------

function Get-TokenDecimals {
    param([string]$tokenAddr, [string]$chainName)
    $lower = $tokenAddr.ToLower()
    if ($lower -in @('speed', 'eth', 'native', 'ether')) { return 18 }
    if (-not $tokenAddr.StartsWith("0x")) { return 18 }

    $rpc = $RPC_URLS[$chainName.ToLower()]
    if (-not $rpc) {
        Write-Warning "Unknown chain '$chainName' for RPC decimals lookup, assuming 18."
        return 18
    }

    $body = '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"' + $tokenAddr + '","data":"0x313ce567"},"latest"],"id":1}'
    try {
        $resp = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
        $hex  = $resp.result -replace '^0x', ''
        return [Convert]::ToInt32($hex.TrimStart('0'), 16)
    } catch {
        Write-Warning "Could not fetch decimals from RPC: $_  Assuming 18."
        return 18
    }
}

function Get-Quote {
    param([string]$sellTok, [string]$buyTok, [string]$sellAmt)
    $raw  = speed quote --json -c $Chain --sell $sellTok --buy $buyTok -a $sellAmt 2>&1
    $line = $raw | Where-Object { $_ -match '^\{' } | Select-Object -First 1
    if (-not $line) { throw "No JSON from quote. Output:`n$($raw -join "`n")" }
    $obj = $line | ConvertFrom-Json
    if (-not ($obj.PSObject.Properties.Name -contains 'buyAmount')) {
        throw "Quote error: $($obj.error)"
    }
    return $obj
}

function Run-Sell {
    param([string]$tokenAmount)
    Write-Host ""
    Write-Host ">>> Executing: speed swap -c $Chain --sell $Token --buy $BaseToken -a $tokenAmount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell $Token --buy $BaseToken -a $tokenAmount -y
    exit $LASTEXITCODE
}

# -- setup ---------------------------------------------------------------------

Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$TOKEN_SCALE   = [Math]::Pow(10, $tokenDecimals)
$TokenLabel    = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

# v2: configurable base token (default Speed; use ETH when Token is also Speed)
if ($BaseToken.ToLower() -eq $Token.ToLower()) { $BaseToken = 'eth' }
$baseDecimals = Get-TokenDecimals -tokenAddr $BaseToken -chainName $Chain
$script:BASE_DECIMALS_SCALE = [Math]::Pow(10, $baseDecimals)
$script:BaseLabel = if ($BaseTokenSymbol -ne "") { $BaseTokenSymbol } else { $BaseToken }

if ($WindowPolls -lt 2)      { Write-Error "-WindowPolls must be >= 2."; exit 1 }
if ($DipPct -le 0)           { Write-Error "-DipPct must be > 0."; exit 1 }
if ($StopPct -le 0)          { Write-Error "-StopPct must be > 0."; exit 1 }
if ($TrailPct -lt 0)         { Write-Error "-TrailPct must be >= 0."; exit 1 }
if ($TimeStopMinutes -lt 0)  { Write-Error "-TimeStopMinutes must be >= 0."; exit 1 }

$exitMode = if ($TrailPct -gt 0) {
    "trailing-stop  ($TrailPct% drop from peak)"
} else {
    "mean-recovery  (sell at mean - $RecoverPct%)"
}

Write-Host ""
Write-Host "=== Speed Mean-Reversion Buy ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- dip signals logged, no buy will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain          : $Chain"
Write-Host "  Token          : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  Buy amount     : $Amount $($script:BaseLabel)  (on dip)"
Write-Host "  Window polls   : $WindowPolls  (rolling SMA)"
Write-Host "  Dip trigger    : $DipPct % below rolling mean"
Write-Host "  Exit mode      : $exitMode"
Write-Host "  Hard stop      : $StopPct % below entry price"
Write-Host "  Poll interval  : $PollSeconds s"
Write-Host "  Max polls      : $MaxIterations"
if ($TimeStopMinutes -gt 0) {
    Write-Host "  Time stop      : $TimeStopMinutes min  (exits at thesis timeout regardless of price)"
}
Write-Host ""

# -- step 1: reference quote (no buy yet) --------------------------------------

Write-Host "Step 1 - Quoting $Amount $($script:BaseLabel) -> $TokenLabel (reference, no buy yet)..." -ForegroundColor DarkCyan

$refBuyQuote   = Get-Quote -sellTok $BaseToken -buyTok $Token -sellAmt $Amount
$refTokenRaw   = [double]$refBuyQuote.buyAmount
$refTokenHuman = $refTokenRaw / $TOKEN_SCALE
$refTokenStr   = $refTokenHuman.ToString("F$tokenDecimals")

if ([double]$refTokenStr -le 0) {
    Write-Error "Reference token amount resolved to 0 (raw=$refTokenRaw, decimals=$tokenDecimals). Aborting."
    exit 1
}
Write-Host ("  Reference amount : {0} {1} for {2} {3}" -f $refTokenStr, $TokenLabel, $Amount, $script:BaseLabel)

# -- step 2: initial price observation -----------------------------------------

Write-Host ""
Write-Host "Step 2 - Getting initial price..." -ForegroundColor DarkCyan

$initSellQuote = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $refTokenStr
$initRaw       = [double]$initSellQuote.buyAmount
$initETH       = $initRaw / $script:BASE_DECIMALS_SCALE

Write-Host ("  Initial price : {0:F8} {3}  (for {1} {2})" -f $initETH, $refTokenStr, $TokenLabel, $script:BaseLabel)
Write-Host ""

# -- step 3: warm-up phase — build initial window ------------------------------

Write-Host ("Step 3 - Warm-up: collecting {0} polls to build price window..." -f $WindowPolls) -ForegroundColor DarkCyan

$window = [System.Collections.Generic.Queue[double]]::new()
$window.Enqueue($initRaw)

$warmupNeeded = $WindowPolls - 1
$warmupDone   = 0

while ($warmupDone -lt $warmupNeeded) {
    $warmupDone++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$ts] Warm-up {0}/{1} - waiting {2} s..." -f $warmupDone, $warmupNeeded, $PollSeconds) -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $wq       = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $refTokenStr
        $wRaw     = [double]$wq.buyAmount
        $wETH     = $wRaw / $script:BASE_DECIMALS_SCALE
        $wMean    = ($window | Measure-Object -Average).Average
        $wMeanETH = $wMean / $script:BASE_DECIMALS_SCALE
        $wDipPct  = if ($wMean -gt 0) { (($wMean - $wRaw) / $wMean) * 100.0 } else { 0.0 }
        $ts2      = Get-Date -Format "HH:mm:ss"
        Write-Host ("[$ts2] Price: {0:F8} {4}  mean: {1:F8} {4}  (dip: {2:F2}%)  [{3} samples]" -f `
            $wETH, $wMeanETH, $wDipPct, ($window.Count + 1), $script:BaseLabel) -ForegroundColor DarkGray
        $window.Enqueue($wRaw)
        if ($window.Count -gt $WindowPolls) { [void]$window.Dequeue() }
    } catch {
        Write-Warning "Warm-up poll $warmupDone failed: $_ - continuing."
        $window.Enqueue($initRaw)
        if ($window.Count -gt $WindowPolls) { [void]$window.Dequeue() }
    }
}

$rollingMean    = ($window | Measure-Object -Average).Average
$rollingMeanETH = $rollingMean / $script:BASE_DECIMALS_SCALE
$dipThreshRaw   = $rollingMean * (1.0 - $DipPct / 100.0)
$dipThreshETH   = $dipThreshRaw / $script:BASE_DECIMALS_SCALE

Write-Host ""
Write-Host ("Warm-up complete. Rolling mean: {0:F8} {2}  ({1} polls)" -f $rollingMeanETH, $WindowPolls, $script:BaseLabel) -ForegroundColor DarkCyan
Write-Host ("Dip entry threshold : {0:F8} {2}  (mean - {1}%)" -f $dipThreshETH, $DipPct, $script:BaseLabel) -ForegroundColor DarkCyan
Write-Host ""

# -- step 4: monitoring + dip detection / post-entry exit ----------------------

Write-Host "Step 4 - Monitoring for dip..." -ForegroundColor DarkCyan
Write-Host ""

$iteration     = 0
$entryMade     = $false
$dryRunDipSeen = $false
$tokenStr      = ""
$entryRaw      = [double]0
$stopThreshRaw = [double]0
$peakRaw       = [double]0
$floorRaw      = [double]0
$startTime     = Get-Date

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    # Time stop check
    if ($TimeStopMinutes -gt 0) {
        $elapsed = (Get-Date) - $startTime
        if ($elapsed.TotalMinutes -ge $TimeStopMinutes) {
            Write-Host ""
            Write-Host ("Time stop reached ({0:F1} min elapsed). " -f $elapsed.TotalMinutes) -NoNewline -ForegroundColor Yellow
            if ($entryMade) {
                Write-Host "Selling open position." -ForegroundColor Yellow
                Run-Sell $tokenStr
            } else {
                Write-Host "Thesis did not play out. Exiting without a trade." -ForegroundColor Yellow
                exit 0
            }
        }
    }

    try {
        $q          = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $refTokenStr
        $currentRaw = [double]$q.buyAmount
        $currentETH = $currentRaw / $script:BASE_DECIMALS_SCALE
        $ts2        = Get-Date -Format "HH:mm:ss"

        # Update rolling window and recompute mean
        $window.Enqueue($currentRaw)
        if ($window.Count -gt $WindowPolls) { [void]$window.Dequeue() }
        $rollingMean    = ($window | Measure-Object -Average).Average
        $rollingMeanETH = $rollingMean / $script:BASE_DECIMALS_SCALE
        $dipThreshRaw   = $rollingMean * (1.0 - $DipPct / 100.0)

        # ── post-entry: exit management ────────────────────────────────────────
        if ($entryMade) {
            $tq   = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $tokenStr
            $tRaw = [double]$tq.buyAmount
            $tETH = $tRaw / $script:BASE_DECIMALS_SCALE

            # Hard stop — checked before both exit modes
            if ($tRaw -le $stopThreshRaw) {
                $lossPct = (($tETH - [double]$Amount) / [double]$Amount) * 100.0
                Write-Host ""
                Write-Host ("HARD STOP triggered! {0:F8} {2} back  ({1:F4}% vs entry cost)" -f $tETH, $lossPct, $script:BaseLabel) -ForegroundColor Red
                if ($DryRun) {
                    Write-Host "  [DRY-RUN] Would SELL $tokenStr $TokenLabel -> $($script:BaseLabel) now." -ForegroundColor DarkYellow
                    exit 0
                }
                Run-Sell $tokenStr
            }

            $stopThreshETH = $stopThreshRaw / $script:BASE_DECIMALS_SCALE

            if ($TrailPct -gt 0) {
                # ── trailing stop exit ─────────────────────────────────────────
                if ($tRaw -gt $peakRaw) {
                    $peakRaw  = $tRaw
                    $floorRaw = $peakRaw * (1.0 - $TrailPct / 100.0)
                }
                $peakETH     = $peakRaw / $script:BASE_DECIMALS_SCALE
                $floorETH    = $floorRaw / $script:BASE_DECIMALS_SCALE
                $pctFromPeak = (($tRaw - $peakRaw) / $peakRaw) * 100.0

                $trailDist   = $peakRaw - $floorRaw
                $distToFloor = $tRaw - $floorRaw
                if ($tRaw -ge $peakRaw) {
                    $color = "Green"
                } elseif ($trailDist -gt 0 -and ($distToFloor / $trailDist) -lt 0.25) {
                    $color = "DarkRed"
                } else {
                    $color = "White"
                }

                Write-Host ("[$ts2] POST-ENTRY  trail: {0:F8} {5}  peak: {1:F8} {5}  floor: {2:F8} {5}  ({3:F4}% from peak)  stop<{4:F8} {5}" -f `
                    $tETH, $peakETH, $floorETH, $pctFromPeak, $stopThreshETH, $script:BaseLabel) -ForegroundColor $color

                if ($tRaw -le $floorRaw) {
                    $gainPct = (($tETH - [double]$Amount) / [double]$Amount) * 100.0
                    Write-Host ""
                    Write-Host ("Trail floor breached! {0:F8} {2} back  ({1:F4}% vs entry cost)" -f $tETH, $gainPct, $script:BaseLabel) -ForegroundColor Red
                    Run-Sell $tokenStr
                }

            } else {
                # ── mean-recovery exit ─────────────────────────────────────────
                $recoveryTargetRaw = $rollingMean * (1.0 - $RecoverPct / 100.0)
                $recoveryTargetETH = $recoveryTargetRaw / $script:BASE_DECIMALS_SCALE
                $pctVsTarget       = (($tRaw - $recoveryTargetRaw) / $recoveryTargetRaw) * 100.0

                if ($tRaw -ge $recoveryTargetRaw) {
                    $color = "Green"
                } elseif ($tRaw -le ($stopThreshRaw * 1.15)) {
                    $color = "DarkRed"
                } else {
                    $color = "White"
                }

                Write-Host ("[$ts2] POST-ENTRY  recov: {0:F8} {5}  mean: {1:F8} {5}  target: {2:F8} {5}  ({3:F4}% vs target)  stop<{4:F8} {5}" -f `
                    $tETH, $rollingMeanETH, $recoveryTargetETH, $pctVsTarget, $stopThreshETH, $script:BaseLabel) -ForegroundColor $color

                if ($tRaw -ge $recoveryTargetRaw) {
                    $gainPct = (($tETH - [double]$Amount) / [double]$Amount) * 100.0
                    Write-Host ""
                    Write-Host ("Recovery target reached! {0:F8} {2} back  ({1:F4}% vs entry cost)" -f $tETH, $gainPct, $script:BaseLabel) -ForegroundColor Green
                    Run-Sell $tokenStr
                }
            }

            continue
        }

        # ── pre-entry: watch for dip ───────────────────────────────────────────
        $dipPctCurrent = if ($rollingMean -gt 0) { (($rollingMean - $currentRaw) / $rollingMean) * 100.0 } else { 0.0 }
        $dipNeeded     = [Math]::Max(0.0, $DipPct - $dipPctCurrent)

        if ($dipPctCurrent -ge $DipPct) {
            $color = "Green"
        } elseif ($dipPctCurrent -ge ($DipPct * 0.5)) {
            $color = "Yellow"
        } elseif ($dipPctCurrent -ge 0) {
            $color = "White"
        } else {
            $color = "DarkGray"
        }

        Write-Host ("[$ts2] Price: {0:F8} {5}  mean: {1:F8} {5}  dip: {2:F4}%  trigger: {3:F2}%  ({4:F4}% more dip vs mean to enter)" -f `
            $currentETH, $rollingMeanETH, $dipPctCurrent, $DipPct, $dipNeeded, $script:BaseLabel) -ForegroundColor $color

        # Dip entry condition
        if ($currentRaw -le $dipThreshRaw) {
            Write-Host ""
            Write-Host ("DIP detected! Price {0:F8} {3} <= threshold {1:F8} {3}  ({2:F4}% below mean)" -f `
                $currentETH, ($dipThreshRaw / $script:BASE_DECIMALS_SCALE), $dipPctCurrent, $script:BaseLabel) -ForegroundColor Green

            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would BUY $Amount $($script:BaseLabel) of $TokenLabel now. Continuing to observe..." -ForegroundColor DarkYellow
                $dryRunDipSeen = $true
            } else {
                Write-Host ""
                Write-Host "Executing dip buy: $Amount $($script:BaseLabel) -> $TokenLabel" -ForegroundColor Green
                Write-Host ">>> speed swap -c $Chain --sell $BaseToken --buy $Token -a $Amount -y" -ForegroundColor Cyan
                speed swap -c $Chain --sell $BaseToken --buy $Token -a $Amount -y
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Dip buy failed (exit $LASTEXITCODE). Aborting."
                    exit $LASTEXITCODE
                }
                $actTokenRaw = $refTokenRaw
                $actTokenHuman = $actTokenRaw / $TOKEN_SCALE
                $refTokenStr   = $actTokenHuman.ToString("F$tokenDecimals")
                Write-Host ""

                Write-Host "Getting post-buy sell quote to anchor exit levels..." -ForegroundColor DarkCyan
                $postBuyQ   = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $refTokenStr
                $postBuyRaw = [double]$postBuyQ.buyAmount
                $tokenStr   = $refTokenStr
                $entryRaw   = $postBuyRaw
                $stopThreshRaw = $entryRaw * (1.0 - $StopPct / 100.0)

                Write-Host ("  Entry price    : {0:F8} {3}  (for {1} {2})" -f ($postBuyRaw / $script:BASE_DECIMALS_SCALE), $tokenStr, $TokenLabel, $script:BaseLabel) -ForegroundColor DarkGray
                Write-Host ("  Hard stop      : {0:F8} {2}  (-{1}% from entry)" -f ($stopThreshRaw / $script:BASE_DECIMALS_SCALE), $StopPct, $script:BaseLabel) -ForegroundColor DarkGray

                if ($TrailPct -gt 0) {
                    $peakRaw  = $postBuyRaw
                    $floorRaw = $peakRaw * (1.0 - $TrailPct / 100.0)
                    Write-Host ("  Trail peak     : {0:F8} {1}" -f ($peakRaw / $script:BASE_DECIMALS_SCALE), $script:BaseLabel) -ForegroundColor DarkGray
                    Write-Host ("  Trail floor    : {0:F8} {2}  (-{1}%)" -f ($floorRaw / $script:BASE_DECIMALS_SCALE), $TrailPct, $script:BaseLabel) -ForegroundColor DarkGray
                } else {
                    $recoveryTarget = $rollingMean * (1.0 - $RecoverPct / 100.0)
                    Write-Host ("  Recovery target: {0:F8} {2}  (mean - {1}%)" -f ($recoveryTarget / $script:BASE_DECIMALS_SCALE), $RecoverPct, $script:BaseLabel) -ForegroundColor DarkGray
                }

                Write-Host ""
                $entryMade = $true
            }
        }

    } catch {
        Write-Warning "Poll $iteration failed: $_ - retrying next interval."
    }
}

# -- max iterations ------------------------------------------------------------

Write-Host ""
if ($entryMade) {
    Write-Host "Max iterations ($MaxIterations) reached. Selling position..." -ForegroundColor Yellow
    Run-Sell $tokenStr
} elseif ($DryRun -and $dryRunDipSeen) {
    Write-Host "Max iterations ($MaxIterations) reached. Dry-run logged dip signal(s); no on-chain trade." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "Max iterations ($MaxIterations) reached. No dip detected. Exiting without a trade." -ForegroundColor Yellow
    exit 0
}
