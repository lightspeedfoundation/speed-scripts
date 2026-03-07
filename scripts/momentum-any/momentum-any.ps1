<#
.SYNOPSIS
    Momentum buy: track a rolling price window and only buy when price breaks
    above the window high by -BreakoutPct%. Once in, a trailing stop manages
    the exit. Never spends ETH unless a confirmed breakout occurs.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes -Amount ETH -> <Token> to derive a reference amount for price
       tracking (does NOT execute a buy yet).
    3. Quotes that reference amount -> ETH to establish an initial price.
    4. Warm-up phase: polls -WindowPolls times to build the initial rolling
       price window (no buys possible during warm-up).
    5. Monitoring phase: each subsequent poll updates the rolling window.
       Breakout condition: currentPrice >= windowHigh * (1 + BreakoutPct/100)
    6. On breakout: executes the buy (-Amount ETH -> Token).
    7. Post-buy: runs a trailing stop. Peak rises on new highs; sells when
       ETH return drops -TrailPct% below the running peak.
    8. If -MaxIterations polls pass without a breakout: exits without buying.

    Use -DryRun to observe the window and breakout detection without buying.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH / native is always the quote currency.

.PARAMETER Amount
    ETH to spend when a breakout is confirmed.

.PARAMETER WindowPolls
    Number of recent polls used to determine the rolling price high.
    Warm-up requires this many polls before breakout detection begins.
    Default: 20.

.PARAMETER BreakoutPct
    Additional % above the window high required to confirm a breakout.
    0 = any new all-time-window high triggers entry.
    Default: 0.

.PARAMETER TrailPct
    Trailing stop % applied after buy entry. Default: 5.

.PARAMETER VolumeConfirm
    Switch. When set, runs a pool depth check before executing any breakout buy.
    Compares price-per-unit at Amount vs Amount*VolumeMultiple ETH. If the implied
    price impact exceeds MaxImpactPct%, the entry is skipped (not the script).
    Subsequent breakout signals are still evaluated. Breakouts on thin pools are rejected.

.PARAMETER VolumeMultiple
    Multiplier for the large quote in the volume check. Default: 10.
    A quote for Amount*10 ETH vs Amount ETH reveals pool depth.

.PARAMETER MaxImpactPct
    Maximum acceptable price impact % for the volume check. Default: 5.
    If impact > MaxImpactPct, the breakout is rejected as likely illiquid.

.PARAMETER DryRun
    Observe price window and log breakout signals without buying.

.EXAMPLE
    .\momentum-any.ps1 -Chain base -Token speed -Amount 0.002 -WindowPolls 20 -BreakoutPct 1 -TrailPct 5
    .\momentum-any.ps1 -Chain base -Token speed -Amount 0.002 -WindowPolls 20 -BreakoutPct 1 -TrailPct 5 -VolumeConfirm
    .\momentum-any.ps1 -Chain base -Token speed -Amount 0.002 -BreakoutPct 1 -TrailPct 5 -VolumeConfirm -MaxImpactPct 3
    .\momentum-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.005 -WindowPolls 10 -BreakoutPct 0.5 -TrailPct 3 -PollSeconds 30
    .\momentum-any.ps1 -Chain base -Token speed -Amount 0.001 -WindowPolls 20 -BreakoutPct 0 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $Amount,
    [string]                       $TokenSymbol   = "",
    [int]                          $WindowPolls   = 20,
    [double]                       $BreakoutPct   = 0.0,
    [double]                       $TrailPct      = 5.0,
    [int]                          $PollSeconds     = 60,
    [int]                          $MaxIterations   = 1440,
    [switch]                       $VolumeConfirm,
    [double]                       $VolumeMultiple  = 10.0,
    [double]                       $MaxImpactPct    = 5.0,
    [switch]                       $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ETH_DECIMALS = [double]1e18

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
    Write-Host ">>> Executing: speed swap -c $Chain --sell $Token --buy eth -a $tokenAmount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell $Token --buy eth -a $tokenAmount -y
    exit $LASTEXITCODE
}

# -- setup ---------------------------------------------------------------------

Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$TOKEN_SCALE   = [Math]::Pow(10, $tokenDecimals)
$TokenLabel    = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

if ($WindowPolls -lt 2) { Write-Error "-WindowPolls must be >= 2."; exit 1 }
if ($TrailPct -le 0)    { Write-Error "-TrailPct must be > 0."; exit 1 }

Write-Host ""
Write-Host "=== Speed Momentum Buy ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- breakout signals logged, no buy will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain          : $Chain"
Write-Host "  Token          : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  Buy amount     : $Amount ETH  (on breakout)"
Write-Host "  Window polls   : $WindowPolls  (warm-up + rolling high)"
Write-Host "  Breakout pct   : $BreakoutPct % above window high"
Write-Host "  Trail pct      : $TrailPct % drop from peak triggers sell"
Write-Host "  Poll interval  : $PollSeconds s"
Write-Host "  Max polls      : $MaxIterations"
if ($VolumeConfirm) {
    Write-Host "  Volume confirm : ON  (reject breakout if pool impact > $MaxImpactPct% at ${VolumeMultiple}x size)"
}
Write-Host ""

# -- step 1: reference quote (no buy yet) -------------------------------------

Write-Host "Step 1 - Quoting $Amount ETH -> $TokenLabel (reference, no buy yet)..." -ForegroundColor DarkCyan

$refBuyQuote   = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $Amount
$refTokenRaw   = [double]$refBuyQuote.buyAmount
$refTokenHuman = $refTokenRaw / $TOKEN_SCALE
$refTokenStr   = $refTokenHuman.ToString("F$tokenDecimals")

if ([double]$refTokenStr -le 0) {
    Write-Error "Reference token amount resolved to 0 (raw=$refTokenRaw, decimals=$tokenDecimals). Aborting."
    exit 1
}
Write-Host ("  Reference amount : {0} {1} for {2} ETH" -f $refTokenStr, $TokenLabel, $Amount)

# -- step 2: initial price observation ----------------------------------------

Write-Host ""
Write-Host "Step 2 - Getting initial price..." -ForegroundColor DarkCyan

$initSellQuote = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
$initRaw       = [double]$initSellQuote.buyAmount
$initETH       = $initRaw / $ETH_DECIMALS

Write-Host ("  Initial price : {0:F8} ETH  (for {1} {2})" -f $initETH, $refTokenStr, $TokenLabel)
Write-Host ""

# -- step 3: warm-up phase  - build initial window ------------------------------

Write-Host ("Step 3 - Warm-up: collecting {0} polls to build price window..." -f $WindowPolls) -ForegroundColor DarkCyan

# Circular buffer for rolling window
$window    = [System.Collections.Generic.Queue[double]]::new()
$window.Enqueue($initRaw)

$warmupNeeded = $WindowPolls - 1
$warmupDone   = 0

while ($warmupDone -lt $warmupNeeded) {
    $warmupDone++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$ts] Warm-up {0}/{1} - waiting {2} s..." -f $warmupDone, $warmupNeeded, $PollSeconds) -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $wq       = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
        $wRaw     = [double]$wq.buyAmount
        $wETH     = $wRaw / $ETH_DECIMALS
        $wHigh    = ($window | Measure-Object -Maximum).Maximum
        $wHighETH = $wHigh / $ETH_DECIMALS
        $wPct     = if ($wHigh -gt 0) { (($wRaw - $wHigh) / $wHigh) * 100.0 } else { 0.0 }
        $ts2      = Get-Date -Format "HH:mm:ss"
        Write-Host ("[$ts2] Price: {0:F8} ETH  window high: {1:F8}  ({2:+0.00}% vs high)  [{3} samples]" -f `
            $wETH, $wHighETH, $wPct, ($window.Count + 1)) -ForegroundColor DarkGray
        $window.Enqueue($wRaw)
        if ($window.Count -gt $WindowPolls) { [void]$window.Dequeue() }
    } catch {
        Write-Warning "Warm-up poll $warmupDone failed: $_ - continuing."
        $window.Enqueue($initRaw)
        if ($window.Count -gt $WindowPolls) { [void]$window.Dequeue() }
    }
}

Write-Host ""
$windowHighRaw = ($window | Measure-Object -Maximum).Maximum
$windowHighETH = $windowHighRaw / $ETH_DECIMALS
Write-Host ("Warm-up complete. Window high: {0:F8} ETH  ({1} polls)" -f $windowHighETH, $WindowPolls) -ForegroundColor DarkCyan
if ($BreakoutPct -gt 0) {
    $breakoutThreshETH = ($windowHighRaw * (1.0 + $BreakoutPct / 100.0)) / $ETH_DECIMALS
    Write-Host ("Breakout threshold: {0:F8} ETH  (window high + {1}%)" -f $breakoutThreshETH, $BreakoutPct) -ForegroundColor DarkCyan
}
Write-Host ""

# -- step 4: monitoring + breakout detection -----------------------------------

Write-Host "Step 4 - Monitoring for breakout..." -ForegroundColor DarkCyan
Write-Host ""

$iteration    = 0
$entryMade    = $false
$tokenStr     = ""
$peakRaw      = [double]0
$floorRaw     = [double]0

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $q          = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
        $currentRaw = [double]$q.buyAmount
        $currentETH = $currentRaw / $ETH_DECIMALS
        $ts2        = Get-Date -Format "HH:mm:ss"

        # Update rolling window
        $window.Enqueue($currentRaw)
        if ($window.Count -gt $WindowPolls) { [void]$window.Dequeue() }
        $windowHighRaw = ($window | Measure-Object -Maximum).Maximum
        $windowHighETH = $windowHighRaw / $ETH_DECIMALS

        # -- post-entry: trailing stop -----------------------------------------
        if ($entryMade) {
            # Re-quote actual bought token amount for accurate trail
            $tq       = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
            $tRaw     = [double]$tq.buyAmount
            $tETH     = $tRaw / $ETH_DECIMALS

            if ($tRaw -gt $peakRaw) {
                $peakRaw  = $tRaw
                $floorRaw = $peakRaw * (1.0 - $TrailPct / 100.0)
            }

            $peakETH      = $peakRaw / $ETH_DECIMALS
            $floorETH     = $floorRaw / $ETH_DECIMALS
            $pctFromPeak  = (($tRaw - $peakRaw) / $peakRaw) * 100.0

            $trailDist    = $peakRaw - $floorRaw
            $distToFloor  = $tRaw - $floorRaw
            if ($tRaw -ge $peakRaw) {
                $color = "Green"
            } elseif ($trailDist -gt 0 -and ($distToFloor / $trailDist) -lt 0.25) {
                $color = "DarkRed"
            } else {
                $color = "White"
            }

            Write-Host ("[$ts2] POST-ENTRY  - {0:F8} ETH  peak: {1:F8}  floor: {2:F8}  ({3:F4}% from peak)" -f `
                $tETH, $peakETH, $floorETH, $pctFromPeak) -ForegroundColor $color

            if ($tRaw -le $floorRaw) {
                $entryETH = [double]$Amount
                $gainPct  = (($tETH - $entryETH) / $entryETH) * 100.0
                Write-Host ""
                Write-Host ("Trail floor breached! {0:F8} ETH back  ({1:F4}% vs entry cost)" -f $tETH, $gainPct) -ForegroundColor Red
                Run-Sell $tokenStr
            }
            continue
        }

        # -- pre-entry: watch for breakout -------------------------------------
        $breakoutThresh = $windowHighRaw * (1.0 + $BreakoutPct / 100.0)
        $pctVsHigh      = (($currentRaw - $windowHighRaw) / $windowHighRaw) * 100.0
        $pctVsThresh    = (($currentRaw - $breakoutThresh) / $breakoutThresh) * 100.0

        if ($currentRaw -ge $windowHighRaw) {
            $color = "Yellow"
        } elseif ($pctVsHigh -gt -2.0) {
            $color = "White"
        } else {
            $color = "DarkGray"
        }

        Write-Host ("[$ts2] Price: {0:F8} ETH  win-high: {1:F8}  ({2:+0.0000}%)  thresh: {3:+0.0000}% away" -f `
            $currentETH, $windowHighETH, $pctVsHigh, $pctVsThresh) -ForegroundColor $color

        # Breakout condition
        if ($currentRaw -ge $breakoutThresh) {
            Write-Host ""
            Write-Host ("BREAKOUT detected! Price {0:F8} ETH >= threshold {1:F8} ETH  (+{2:F4}% vs window high)" -f `
                $currentETH, ($breakoutThresh / $ETH_DECIMALS), $pctVsHigh) -ForegroundColor Green

            # ── Volume confirmation check ──────────────────────────────────────
            $skipEntry = $false
            if ($VolumeConfirm) {
                try {
                    $largeAmountStr = ([double]$Amount * $VolumeMultiple).ToString("F8")
                    $smallQ  = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $Amount
                    $largeQ  = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $largeAmountStr
                    $smallPPU = [double]$smallQ.buyAmount / [double]$Amount
                    $largePPU = [double]$largeQ.buyAmount / [double]$largeAmountStr
                    $impactPct = if ($largePPU -gt 0) { ($smallPPU / $largePPU - 1.0) * 100.0 } else { 0.0 }

                    if ($impactPct -gt $MaxImpactPct) {
                        Write-Host ("  [VOLUME] Pool impact: {0:F2}% at {1}x size > MaxImpactPct {2}%. Breakout rejected (thin pool). Watching for next signal." -f `
                            $impactPct, $VolumeMultiple, $MaxImpactPct) -ForegroundColor Yellow
                        $skipEntry = $true
                    } else {
                        Write-Host ("  [VOLUME] Pool impact: {0:F2}% at {1}x size (max: {2}%). Liquidity OK. Entering." -f `
                            $impactPct, $VolumeMultiple, $MaxImpactPct) -ForegroundColor Green
                    }
                } catch {
                    Write-Warning "Volume check failed: $_ -- proceeding without confirmation."
                }
            }

            if ($skipEntry) { continue }

            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would BUY $Amount ETH of $TokenLabel now. Continuing to observe..." -ForegroundColor DarkYellow
            } else {
                Write-Host ""
                Write-Host "Executing breakout buy: $Amount ETH -> $TokenLabel" -ForegroundColor Green
                Write-Host ">>> speed swap -c $Chain --sell eth --buy $Token -a $Amount -y" -ForegroundColor Cyan
                speed swap -c $Chain --sell eth --buy $Token -a $Amount -y
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Breakout buy failed (exit $LASTEXITCODE). Aborting."
                    exit $LASTEXITCODE
                }
                Write-Host ""

                # Get current sell quote to anchor trail peak
                Write-Host "Getting post-buy sell quote to anchor trailing stop..." -ForegroundColor DarkCyan
                $postBuyQ  = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
                $postBuyRaw= [double]$postBuyQ.buyAmount
                # Use refTokenStr as the tokenStr for trailing stop (the amount we'd get for Amount ETH)
                $tokenStr  = $refTokenStr
                $peakRaw   = $postBuyRaw
                $floorRaw  = $peakRaw * (1.0 - $TrailPct / 100.0)
                $entryMade = $true

                Write-Host ("  Entry price   : {0:F8} ETH  (for {1} {2})" -f ($postBuyRaw / $ETH_DECIMALS), $tokenStr, $TokenLabel) -ForegroundColor DarkGray
                Write-Host ("  Trail peak    : {0:F8} ETH" -f ($peakRaw / $ETH_DECIMALS)) -ForegroundColor DarkGray
                Write-Host ("  Trail floor   : {0:F8} ETH  (-{1}%)" -f ($floorRaw / $ETH_DECIMALS), $TrailPct) -ForegroundColor DarkGray
                Write-Host ""
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
} else {
    Write-Host "Max iterations ($MaxIterations) reached. No breakout detected. Exiting without a trade." -ForegroundColor Yellow
    exit 0
}
