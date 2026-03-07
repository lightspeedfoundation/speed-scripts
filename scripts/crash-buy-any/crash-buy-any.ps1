<#
.SYNOPSIS
    Crash buy: monitor price velocity and buy immediately when price drops
    -CrashPct% relative to a rolling baseline. Rides the bounce via trailing stop.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes -Amount ETH -> <Token> to establish a reference amount.
    3. Gets initial price quote to seed the baseline window.
    4. Detection loop: polls every -PollSeconds seconds.
       - Computes baseline = mean of the last -BaselinePolls prices.
       - Computes dropPct = (baseline - currentRaw) / baseline * 100.
       - If dropPct >= CrashPct: crash confirmed -> executes the buy.
       - Otherwise: slides the window forward, continue watching.
    5. Post-buy: trailing stop (identical to trailing-stop-any.ps1).
       Peak rises on new highs. Sells when ETH return drops -TrailPct% from peak.
    6. Falls back to selling after -MaxIterations total polls.

    BaselinePolls controls false-positive resistance. Default 1 = single-poll
    comparison (maximum sensitivity, highest false-positive rate on thin pairs).
    Set 3-5 on low-liquidity tokens to require the mean of several polls to be
    above the threshold before a crash is confirmed — one whale trade cannot fire it.

    Difference from mean-revert-any: mean-revert detects gradual drift below a
    rolling SMA. Crash-buy detects velocity events — a sharp sudden drop.
    A token can be exactly at its 30-day mean and still crash 8% in 30 seconds.
    NOTE: running both on the same token means a genuine crash triggers both
    simultaneously, silently doubling your position. Intentional use only.

    Use -DryRun to observe crash signals without buying.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH / native is always the quote currency.

.PARAMETER Amount
    ETH to spend when a crash is confirmed.

.PARAMETER CrashPct
    % drop below the rolling baseline required to trigger the buy.

.PARAMETER BaselinePolls
    Number of recent polls whose mean forms the crash baseline.
    1 (default) = compare against the immediately preceding poll (maximum sensitivity).
    3-5 = rolling mean baseline; reduces false positives on low-liquidity pairs.
    Detection does not begin until the window has accumulated this many polls.

.PARAMETER TrailPct
    Trailing stop % applied after buy entry. Default: 5.

.PARAMETER TimeStopMinutes
    Maximum minutes to run after detection begins before exiting regardless of price.
    0 (default) = disabled (run until MaxIterations).
    If no entry has been made: exits cleanly without a trade ("thesis did not play out").
    If an entry is held: sells at market immediately.

.PARAMETER DryRun
    Observe crash signals and log entries without buying.

.EXAMPLE
    .\crash-buy-any.ps1 -Chain base -Token speed -Amount 0.002 -CrashPct 5 -TrailPct 5
    .\crash-buy-any.ps1 -Chain base -Token speed -Amount 0.002 -CrashPct 5 -TrailPct 5 -BaselinePolls 3
    .\crash-buy-any.ps1 -Chain base -Token speed -Amount 0.002 -CrashPct 5 -TrailPct 5 -TimeStopMinutes 120
    .\crash-buy-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.012 -CrashPct 3 -TrailPct 3 -PollSeconds 30 -BaselinePolls 4
    .\crash-buy-any.ps1 -Chain base -Token speed -Amount 0.001 -CrashPct 5 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $Amount,
    [Parameter(Mandatory)][double] $CrashPct,
    [double]  $TrailPct         = 5.0,
    [int]     $BaselinePolls    = 1,
    [string]  $TokenSymbol      = "",
    [int]     $PollSeconds      = 30,
    [int]     $MaxIterations    = 2880,
    [int]     $TimeStopMinutes  = 0,
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

if ($CrashPct -le 0)        { Write-Error "-CrashPct must be > 0."; exit 1 }
if ($TrailPct -le 0)        { Write-Error "-TrailPct must be > 0."; exit 1 }
if ($BaselinePolls -lt 1)   { Write-Error "-BaselinePolls must be >= 1."; exit 1 }
if ($TimeStopMinutes -lt 0) { Write-Error "-TimeStopMinutes must be >= 0."; exit 1 }

Write-Host ""
Write-Host "=== Speed Crash Buy ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- crash signals logged, no buy will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain          : $Chain"
Write-Host "  Token          : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  Buy amount     : $Amount ETH  (on crash)"
$baselineLabel = if ($BaselinePolls -eq 1) { "single-poll (prev tick)" } else { "$BaselinePolls-poll rolling mean" }
Write-Host "  Crash trigger  : $CrashPct % drop vs $baselineLabel"
Write-Host "  Baseline polls : $BaselinePolls  (window warm-up: $BaselinePolls polls)"
Write-Host "  Trail pct      : $TrailPct % drop from peak triggers sell"
Write-Host "  Poll interval  : $PollSeconds s"
Write-Host "  Max polls      : $MaxIterations"
if ($TimeStopMinutes -gt 0) {
    Write-Host "  Time stop      : $TimeStopMinutes min  (exits at thesis timeout regardless of price)"
}
Write-Host ""

# -- step 1: reference quote (no buy yet) --------------------------------------

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

# -- step 2: initial price quote -----------------------------------------------

Write-Host ""
Write-Host "Step 2 - Getting initial price..." -ForegroundColor DarkCyan

$initSellQuote = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
$prevRaw       = [double]$initSellQuote.buyAmount
$prevETH       = $prevRaw / $ETH_DECIMALS

Write-Host ("  Initial price : {0:F8} ETH  (for {1} {2})" -f $prevETH, $refTokenStr, $TokenLabel)
Write-Host ""

# -- step 3: crash detection + post-entry trailing stop ------------------------

Write-Host "Step 3 - Monitoring for crash..." -ForegroundColor DarkCyan
Write-Host ""

$iteration    = 0
$entryMade    = $false
$tokenStr     = ""
$peakRaw      = [double]0
$floorRaw     = [double]0
$startTime    = Get-Date

# Rolling baseline window — seeded with the initial price quote
$priceWindow = [System.Collections.Generic.Queue[double]]::new()
$priceWindow.Enqueue($prevRaw)

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
        $q          = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
        $currentRaw = [double]$q.buyAmount
        $currentETH = $currentRaw / $ETH_DECIMALS
        $ts2        = Get-Date -Format "HH:mm:ss"

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

        # ── pre-entry: velocity crash detection ────────────────────────────────
        # Slide window before comparison so baseline reflects only past polls
        $priceWindow.Enqueue($currentRaw)
        while ($priceWindow.Count -gt ($BaselinePolls + 1)) { [void]$priceWindow.Dequeue() }

        # Wait for window to fill before detecting — avoids false signal on first poll
        $windowReady = ($priceWindow.Count -ge ($BaselinePolls + 1))

        # Baseline = mean of all window entries except the current (last) one
        $windowArr   = $priceWindow.ToArray()
        $baselineArr = $windowArr[0..($windowArr.Length - 2)]
        $baselineRaw = ($baselineArr | Measure-Object -Sum).Sum / $baselineArr.Length
        $baselineETH = $baselineRaw / $ETH_DECIMALS
        $dropPct     = if ($baselineRaw -gt 0) { (($baselineRaw - $currentRaw) / $baselineRaw) * 100.0 } else { 0.0 }
        $pctToTrig   = $CrashPct - $dropPct

        if (-not $windowReady) {
            Write-Host ("[$ts2] Warming up baseline window... ({0}/{1} polls)" -f ($priceWindow.Count - 1), $BaselinePolls) -ForegroundColor DarkGray
            continue
        }

        if ($dropPct -ge $CrashPct) {
            $color = "Green"
        } elseif ($dropPct -ge ($CrashPct * 0.5)) {
            $color = "Yellow"
        } elseif ($dropPct -ge 0) {
            $color = "White"
        } else {
            $color = "DarkGray"
        }

        Write-Host ("[$ts2] Price: {0:F8} ETH  baseline: {1:F8}  drop: {2:+0.4f}%  trigger: {3:F2}%  ({4:+0.4f}% away)" -f `
            $currentETH, $baselineETH, $dropPct, $CrashPct, (-$pctToTrig)) -ForegroundColor $color

        # Crash entry condition
        if ($dropPct -ge $CrashPct) {
            Write-Host ""
            Write-Host ("CRASH detected! Price dropped {0:F4}% vs {1}-poll baseline  ({2:F8} ETH -> {3:F8} ETH)" -f `
                $dropPct, $BaselinePolls, $baselineETH, $currentETH) -ForegroundColor Green

            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would BUY $Amount ETH of $TokenLabel now. Continuing to observe..." -ForegroundColor DarkYellow
            } else {
                Write-Host ""
                Write-Host "Executing crash buy: $Amount ETH -> $TokenLabel" -ForegroundColor Green
                Write-Host ">>> speed swap -c $Chain --sell eth --buy $Token -a $Amount -y" -ForegroundColor Cyan
                speed swap -c $Chain --sell eth --buy $Token -a $Amount -y
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Crash buy failed (exit $LASTEXITCODE). Aborting."
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
    Write-Host "Max iterations ($MaxIterations) reached. No crash detected. Exiting without a trade." -ForegroundColor Yellow
    exit 0
}
