<#
.SYNOPSIS
    Compression buy: wait for price to consolidate into a tight range (compression),
    then buy when price breaks out of that range (expansion). Trails exit.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes -Amount ETH -> <Token> to establish reference amount (no buy yet).
    3. Warm-up phase: polls -WindowPolls times to build the initial rolling window.
    4. Monitoring phase: each poll updates the rolling window and computes:
         rollingMean  = average of window prices
         rollingRange = windowHigh - windowLow
         compressionRatio = rollingRange / rollingMean * 100
       ARMED when compressionRatio <= CompressionPct (price band is tight).
       FIRES when armed AND currentPrice >= windowHigh * (1 + ExpansionPct/100).
    5. On entry: executes the buy (-Amount ETH -> Token).
    6. Post-buy exit: trailing stop, identical to momentum-any post-entry.
       Peak rises on new highs; sells when ETH return drops -TrailPct% from peak.
    7. Optional -ArmTimeout: if armed state persists this many polls without
       expansion, resets arm (avoids stale armed state in infinite sideways ranges).
    8. Falls back to selling after -MaxIterations if already bought.

    Key distinction from momentum-any: momentum fires on ANY price breakout above
    the window high. Compression-buy ONLY fires on a breakout that follows a
    measured compression period. The compression confirms a coiling setup before
    entry. Range contractions statistically precede the largest directional moves.

    Use -DryRun to observe compression and expansion signals without buying.

.PARAMETER Chain
    Chain name or ID (base, ethereum, arbitrum, optimism, polygon, bnb).

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH is always the quote currency.

.PARAMETER Amount
    ETH to spend when a compression expansion is confirmed.

.PARAMETER WindowPolls
    Number of recent polls used for rolling range and mean calculations.
    Warm-up requires this many polls before compression detection begins.
    Default: 20.

.PARAMETER CompressionPct
    Rolling range must be <= this % of the rolling mean to be considered compressed.
    Lower = tighter squeeze required before arming. Default: 3.

.PARAMETER ExpansionPct
    Price must break above the window high by this % while armed to confirm entry.
    0 = any break above window high while armed triggers entry. Default: 1.

.PARAMETER TrailPct
    Trailing stop % applied after buy entry. Default: 5.

.PARAMETER ArmTimeout
    If armed for this many polls without an expansion breakout, reset the arm and
    re-watch for fresh compression. 0 = never reset (stay armed until expansion or
    a new compression breaks the arm condition). Default: 0.

.PARAMETER TokenSymbol
    Optional display label for the token. Defaults to the address.

.PARAMETER PollSeconds
    Seconds between price polls. Default 60.

.PARAMETER MaxIterations
    Maximum total polls. If entry has been made, sells remaining position.
    If no entry, exits without trade. Default: 1440.

.PARAMETER DryRun
    Observe compression and expansion signals without buying.

.EXAMPLE
    .\compression-buy-any.ps1 -Chain base -Token speed -Amount 0.002 -WindowPolls 20 -CompressionPct 3 -ExpansionPct 1 -TrailPct 5
    .\compression-buy-any.ps1 -Chain base -Token speed -Amount 0.002 -CompressionPct 2 -ExpansionPct 0.5 -TrailPct 4
    .\compression-buy-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.012 -WindowPolls 15 -CompressionPct 2 -ExpansionPct 0.5 -TrailPct 3 -PollSeconds 30
    .\compression-buy-any.ps1 -Chain base -Token speed -Amount 0.002 -CompressionPct 3 -ArmTimeout 10 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $Amount,
    [string]  $TokenSymbol     = "",
    [int]     $WindowPolls     = 20,
    [double]  $CompressionPct  = 3.0,
    [double]  $ExpansionPct    = 1.0,
    [double]  $TrailPct        = 5.0,
    [int]     $ArmTimeout      = 0,
    [int]     $PollSeconds     = 60,
    [int]     $MaxIterations   = 1440,
    [switch]  $DryRun
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

if ($WindowPolls -lt 2)      { Write-Error "-WindowPolls must be >= 2."; exit 1 }
if ($CompressionPct -le 0)   { Write-Error "-CompressionPct must be > 0."; exit 1 }
if ($TrailPct -le 0)         { Write-Error "-TrailPct must be > 0."; exit 1 }
if ($ArmTimeout -lt 0)       { Write-Error "-ArmTimeout must be >= 0."; exit 1 }

Write-Host ""
Write-Host "=== Speed Compression Buy ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- compression signals logged, no buy will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain           : $Chain"
Write-Host "  Token           : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  Buy amount      : $Amount ETH  (on expansion breakout)"
Write-Host "  Window polls    : $WindowPolls  (rolling range + mean)"
Write-Host "  Compression     : <= $CompressionPct % range/mean  (arm condition)"
Write-Host "  Expansion       : +$ExpansionPct % above window high while armed  (entry)"
Write-Host "  Trail pct       : $TrailPct % drop from peak triggers sell"
if ($ArmTimeout -gt 0) {
    Write-Host "  Arm timeout     : $ArmTimeout polls without expansion resets arm"
}
Write-Host "  Poll interval   : $PollSeconds s"
Write-Host "  Max polls       : $MaxIterations"
Write-Host ""

# -- step 1: reference quote (no buy yet) --------------------------------------

Write-Host "Step 1 - Quoting $Amount ETH -> $TokenLabel (reference, no buy yet)..." -ForegroundColor DarkCyan

$refBuyQuote   = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $Amount
$refTokenRaw   = [double]$refBuyQuote.buyAmount
$refTokenHuman = $refTokenRaw / $TOKEN_SCALE
$refTokenStr   = $refTokenHuman.ToString("F$tokenDecimals")

if ([double]$refTokenStr -le 0) {
    Write-Error "Reference token amount resolved to 0. Aborting."
    exit 1
}
Write-Host ("  Reference amount : {0} {1} for {2} ETH" -f $refTokenStr, $TokenLabel, $Amount)

# -- step 2: initial price -----------------------------------------------------

Write-Host ""
Write-Host "Step 2 - Getting initial price..." -ForegroundColor DarkCyan

$initSellQuote = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
$initRaw       = [double]$initSellQuote.buyAmount
$initETH       = $initRaw / $ETH_DECIMALS

Write-Host ("  Initial price : {0:F8} ETH  (for {1} {2})" -f $initETH, $refTokenStr, $TokenLabel)
Write-Host ""

# -- step 3: warm-up phase -----------------------------------------------------

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
        $wq      = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
        $wRaw    = [double]$wq.buyAmount
        $wETH    = $wRaw / $ETH_DECIMALS
        $wHigh   = ($window | Measure-Object -Maximum).Maximum
        $wLow    = ($window | Measure-Object -Minimum).Minimum
        $wMean   = ($window | Measure-Object -Average).Average
        $wRange  = if ($wMean -gt 0) { (($wHigh - $wLow) / $wMean) * 100.0 } else { 0.0 }
        $ts2     = Get-Date -Format "HH:mm:ss"
        Write-Host ("[$ts2] Price: {0:F8} ETH  range: {1:F2}%  compress<={2}%  [{3} samples]" -f `
            $wETH, $wRange, $CompressionPct, ($window.Count + 1)) -ForegroundColor DarkGray
        $window.Enqueue($wRaw)
        if ($window.Count -gt $WindowPolls) { [void]$window.Dequeue() }
    } catch {
        Write-Warning "Warm-up poll $warmupDone failed: $_ - continuing."
        $window.Enqueue($initRaw)
        if ($window.Count -gt $WindowPolls) { [void]$window.Dequeue() }
    }
}

$wMean    = ($window | Measure-Object -Average).Average
$wHigh    = ($window | Measure-Object -Maximum).Maximum
$wLow     = ($window | Measure-Object -Minimum).Minimum
$wRange   = if ($wMean -gt 0) { (($wHigh - $wLow) / $wMean) * 100.0 } else { 0.0 }

Write-Host ""
Write-Host ("Warm-up complete. Range: {0:F2}%  Mean: {1:F8} ETH  ({2} polls)" -f $wRange, ($wMean / $ETH_DECIMALS), $WindowPolls) -ForegroundColor DarkCyan
Write-Host ""

# -- step 4: monitoring - compression detection + expansion entry --------------

Write-Host "Step 4 - Monitoring for compression then expansion..." -ForegroundColor DarkCyan
Write-Host ""

$iteration   = 0
$armed       = $false
$armPollCount= 0
$entryMade   = $false
$tokenStr    = ""
$peakRaw     = [double]0
$floorRaw    = [double]0

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
        $rollingMean  = ($window | Measure-Object -Average).Average
        $windowHigh   = ($window | Measure-Object -Maximum).Maximum
        $windowLow    = ($window | Measure-Object -Minimum).Minimum
        $rangeRatio   = if ($rollingMean -gt 0) { (($windowHigh - $windowLow) / $rollingMean) * 100.0 } else { 0.0 }
        $windowHighETH= $windowHigh / $ETH_DECIMALS

        # ── post-entry: trailing stop ──────────────────────────────────────────
        if ($entryMade) {
            $tq   = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
            $tRaw = [double]$tq.buyAmount
            $tETH = $tRaw / $ETH_DECIMALS

            if ($tRaw -gt $peakRaw) {
                $peakRaw  = $tRaw
                $floorRaw = $peakRaw * (1.0 - $TrailPct / 100.0)
            }

            $peakETH     = $peakRaw / $ETH_DECIMALS
            $floorETH    = $floorRaw / $ETH_DECIMALS
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

            Write-Host ("[$ts2] POST-ENTRY  {0:F8} ETH  peak: {1:F8}  floor: {2:F8}  ({3:F4}% from peak)" -f `
                $tETH, $peakETH, $floorETH, $pctFromPeak) -ForegroundColor $color

            if ($tRaw -le $floorRaw) {
                $gainPct = (($tETH - [double]$Amount) / [double]$Amount) * 100.0
                Write-Host ""
                Write-Host ("Trail floor breached! {0:F8} ETH back  ({1:F4}% vs entry cost)" -f $tETH, $gainPct) -ForegroundColor Red
                Run-Sell $tokenStr
            }
            continue
        }

        # ── compression check ──────────────────────────────────────────────────
        $isCompressed = ($rangeRatio -le $CompressionPct)

        if ($armed -and -not $isCompressed) {
            # Price broke out of compression band without expansion signal — reset
            $armed        = $false
            $armPollCount = 0
            Write-Host ("[$ts2] COMPRESSION  range: {0:F2}%  mean: {1:F8}  [COMPRESSION LOST - range expanded beyond {2}%]" -f `
                $rangeRatio, ($rollingMean / $ETH_DECIMALS), $CompressionPct) -ForegroundColor DarkGray
        } elseif (-not $armed -and $isCompressed) {
            $armed        = $true
            $armPollCount = 0
            Write-Host ("[$ts2] COMPRESSION  range: {0:F2}% <= {1}%  mean: {1:F8} -- ARMED" -f `
                $rangeRatio, $CompressionPct, ($rollingMean / $ETH_DECIMALS)) -ForegroundColor Cyan
        } elseif ($armed) {
            $armPollCount++
            # Check ArmTimeout
            if ($ArmTimeout -gt 0 -and $armPollCount -ge $ArmTimeout) {
                $armed        = $false
                $armPollCount = 0
                Write-Host ("[$ts2] COMPRESSION  range: {0:F2}%  -- ARM TIMEOUT ({1} polls). Resetting." -f `
                    $rangeRatio, $ArmTimeout) -ForegroundColor Yellow
            }
        }

        # ── expansion breakout check (only when armed) ─────────────────────────
        $expansionThresh    = $windowHigh * (1.0 + $ExpansionPct / 100.0)
        $expansionThreshETH = $expansionThresh / $ETH_DECIMALS
        $pctVsHigh          = (($currentRaw - $windowHigh) / $windowHigh) * 100.0

        $armedLabel = if ($armed) { "ARMED" } else { "watching" }
        if ($armed) {
            $color = if ($currentRaw -ge $expansionThresh) { "Green" } elseif ($pctVsHigh -ge 0) { "Yellow" } else { "Cyan" }
        } else {
            $color = if ($isCompressed) { "Cyan" } else { "DarkGray" }
        }

        Write-Host ("[$ts2] [{5}] price: {0:F8}  win-high: {1:F8}  range: {2:F2}%  exp-thresh: {3:F8}  ({4:+0.4f}% vs high)" -f `
            $currentETH, $windowHighETH, $rangeRatio, $expansionThreshETH, $pctVsHigh, $armedLabel) -ForegroundColor $color

        if ($armed -and $currentRaw -ge $expansionThresh) {
            Write-Host ""
            Write-Host ("EXPANSION BREAKOUT! Price {0:F8} ETH >= {1:F8} ETH while compressed  (+{2:F4}% vs window high)" -f `
                $currentETH, $expansionThreshETH, $pctVsHigh) -ForegroundColor Green

            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would BUY $Amount ETH of $TokenLabel now. Continuing to observe..." -ForegroundColor DarkYellow
                $armed = $false
            } else {
                Write-Host ""
                Write-Host "Executing compression breakout buy: $Amount ETH -> $TokenLabel" -ForegroundColor Green
                Write-Host ">>> speed swap -c $Chain --sell eth --buy $Token -a $Amount -y" -ForegroundColor Cyan
                speed swap -c $Chain --sell eth --buy $Token -a $Amount -y
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Compression buy failed (exit $LASTEXITCODE). Aborting."
                    exit $LASTEXITCODE
                }
                Write-Host ""

                Write-Host "Getting post-buy sell quote to anchor trailing stop..." -ForegroundColor DarkCyan
                $postBuyQ   = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
                $postBuyRaw = [double]$postBuyQ.buyAmount
                $tokenStr   = $refTokenStr
                $peakRaw    = $postBuyRaw
                $floorRaw   = $peakRaw * (1.0 - $TrailPct / 100.0)
                $entryMade  = $true

                Write-Host ("  Entry price  : {0:F8} ETH  (for {1} {2})" -f ($postBuyRaw / $ETH_DECIMALS), $tokenStr, $TokenLabel) -ForegroundColor DarkGray
                Write-Host ("  Trail peak   : {0:F8} ETH" -f ($peakRaw / $ETH_DECIMALS)) -ForegroundColor DarkGray
                Write-Host ("  Trail floor  : {0:F8} ETH  (-{1}%)" -f ($floorRaw / $ETH_DECIMALS), $TrailPct) -ForegroundColor DarkGray
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
    Write-Host "Max iterations ($MaxIterations) reached. No expansion breakout detected. Exiting without a trade." -ForegroundColor Yellow
    exit 0
}
