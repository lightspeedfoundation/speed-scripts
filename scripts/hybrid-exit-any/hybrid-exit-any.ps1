<#
.SYNOPSIS
    Hybrid exit: buy immediately, sell ExitFraction% at a fixed TakePct% target,
    then trail the remainder with a TrailPct% stop. Hard stop always active.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes -Amount ETH -> <Token> to show what you will get.
    3. Executes the buy (ETH -> Token).
    4. Gets a baseline sell quote (baselineRaw) to anchor all exit levels.
    5. Phase A — watching for take target:
       Poll until price >= baselineRaw * (1 + TakePct/100).
       Hard stop always active: sells FULL position if price <= baselineRaw * (1 - StopPct/100).
    6. Phase B — partial sell at take target:
       Sells ExitFraction% of the original token amount at market.
       Locks in guaranteed profit on that portion.
    7. Phase C — trailing stop on remainder:
       Trails the remaining (100 - ExitFraction)% with a TrailPct% stop.
       Hard stop remains active on the remainder throughout Phase C.
    8. Falls back to selling all remaining tokens after -MaxIterations total polls.

    The highest Sharpe exit structure: the fixed first sell guarantees a win
    on half the position while the trailing stop lets the remainder compound.

    Use -DryRun to simulate all phases without executing any swaps.

.PARAMETER Chain
    Chain name or ID (base, ethereum, arbitrum, optimism, polygon, bnb).

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH is always the quote currency.

.PARAMETER Amount
    ETH to spend on the initial buy.

.PARAMETER TakePct
    % above baseline to trigger the first partial sell (take-profit level).

.PARAMETER ExitFraction
    % of position to sell at the TakePct target. Default: 50.
    The remainder (100 - ExitFraction)% is then trailed.
    Valid range: 1-99.

.PARAMETER TrailPct
    Trailing stop % applied to the remainder after the partial exit. Default: 5.

.PARAMETER StopPct
    Hard stop-loss: % below baseline that triggers an immediate full-position sell.
    Active in both Phase A and Phase C. Default: 10.

.PARAMETER TokenSymbol
    Optional display label for the token. Defaults to the address.

.PARAMETER PollSeconds
    Seconds between price polls. Default 60.

.PARAMETER MaxIterations
    Maximum total polls (Phase A + Phase C). Falls back to market sell. Default 1440.

.PARAMETER DryRun
    Print what would happen without executing any swaps.

.EXAMPLE
    .\hybrid-exit-any.ps1 -Chain base -Token speed -Amount 0.002 -TakePct 10 -ExitFraction 50 -TrailPct 5 -StopPct 10
    .\hybrid-exit-any.ps1 -Chain base -Token speed -Amount 0.002 -TakePct 15 -TrailPct 8
    .\hybrid-exit-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.012 -TakePct 5 -ExitFraction 60 -TrailPct 3 -StopPct 7
    .\hybrid-exit-any.ps1 -Chain base -Token speed -Amount 0.001 -TakePct 10 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $Amount,
    [Parameter(Mandatory)][double] $TakePct,
    [double]  $ExitFraction  = 50.0,
    [double]  $TrailPct      = 5.0,
    [double]  $StopPct       = 10.0,
    [string]  $TokenSymbol   = "",
    [int]     $PollSeconds   = 60,
    [int]     $MaxIterations = 1440,
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
    param([string]$tokenAmount, [string]$label)
    Write-Host ""
    Write-Host ">>> Executing: speed swap -c $Chain --sell $Token --buy eth -a $tokenAmount -y  ($label)" -ForegroundColor Cyan
    speed swap -c $Chain --sell $Token --buy eth -a $tokenAmount -y
    exit $LASTEXITCODE
}

# -- setup ---------------------------------------------------------------------

Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$TOKEN_SCALE   = [Math]::Pow(10, $tokenDecimals)
$TokenLabel    = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

if ($TakePct -le 0)                     { Write-Error "-TakePct must be > 0."; exit 1 }
if ($ExitFraction -le 0 -or $ExitFraction -ge 100) { Write-Error "-ExitFraction must be 1-99."; exit 1 }
if ($TrailPct -le 0)                    { Write-Error "-TrailPct must be > 0."; exit 1 }
if ($StopPct -le 0)                     { Write-Error "-StopPct must be > 0."; exit 1 }

Write-Host ""
Write-Host "=== Speed Hybrid Exit ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- no swaps will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain          : $Chain"
Write-Host "  Token          : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  Buy amount     : $Amount ETH"
Write-Host "  Take target    : +$TakePct % above baseline  -> sell $ExitFraction% of position"
Write-Host "  Trail stop     : $TrailPct % drop from peak  -> sell remainder ($([int](100 - $ExitFraction))%)"
Write-Host "  Hard stop      : $StopPct % below baseline   -> sell FULL position (both phases)"
Write-Host "  Poll interval  : $PollSeconds s"
Write-Host "  Max polls      : $MaxIterations"
Write-Host ""

# -- step 1: buy ---------------------------------------------------------------

Write-Host "Step 1 - Quoting $Amount ETH -> $TokenLabel..." -ForegroundColor DarkCyan

$buyPreview = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $Amount
$estTokenRaw   = [double]$buyPreview.buyAmount
$estTokenHuman = $estTokenRaw / $TOKEN_SCALE
$estTokenStr   = $estTokenHuman.ToString("F$tokenDecimals")
Write-Host ("  Estimated receive : {0} {1}" -f $estTokenStr, $TokenLabel)

if (-not $DryRun) {
    Write-Host ""
    Write-Host "Executing buy: $Amount ETH -> $TokenLabel" -ForegroundColor Green
    Write-Host ">>> speed swap -c $Chain --sell eth --buy $Token -a $Amount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell eth --buy $Token -a $Amount -y
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Buy failed (exit $LASTEXITCODE). Aborting."
        exit $LASTEXITCODE
    }
    Write-Host ""
}

# -- step 2: baseline quote ----------------------------------------------------

Write-Host "Step 2 - Getting baseline sell quote to anchor exit levels..." -ForegroundColor DarkCyan

$refTokenRaw   = [double]$buyPreview.buyAmount
$refTokenHuman = $refTokenRaw / $TOKEN_SCALE
$refTokenStr   = $refTokenHuman.ToString("F$tokenDecimals")

if ([double]$refTokenStr -le 0) {
    Write-Error "Reference token amount resolved to 0. Aborting."
    exit 1
}

$baselineQ   = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
$baselineRaw = [double]$baselineQ.buyAmount
$baselineETH = $baselineRaw / $ETH_DECIMALS

$takeTargetRaw  = $baselineRaw * (1.0 + $TakePct / 100.0)
$stopThreshRaw  = $baselineRaw * (1.0 - $StopPct / 100.0)
$takeTargetETH  = $takeTargetRaw / $ETH_DECIMALS
$stopThreshETH  = $stopThreshRaw / $ETH_DECIMALS

# Compute partial and remainder token strings
$partialFrac      = $ExitFraction / 100.0
$remainderFrac    = 1.0 - $partialFrac
$partialTokenHuman  = ([double]$refTokenStr) * $partialFrac
$remainderTokenHuman = ([double]$refTokenStr) * $remainderFrac
$partialTokenStr    = $partialTokenHuman.ToString("F$tokenDecimals")
$remainderTokenStr  = $remainderTokenHuman.ToString("F$tokenDecimals")

Write-Host ("  Baseline         : {0:F8} ETH  (for {1} {2})" -f $baselineETH, $refTokenStr, $TokenLabel) -ForegroundColor DarkGray
Write-Host ("  Take target      : {0:F8} ETH  (+{1}%)  -> sell {2} {3} ({4}%)" -f $takeTargetETH, $TakePct, $partialTokenStr, $TokenLabel, $ExitFraction) -ForegroundColor DarkGray
Write-Host ("  Remainder        : {0} {1}  ({2}%) -> trailed at -{3}%" -f $remainderTokenStr, $TokenLabel, [int](100 - $ExitFraction), $TrailPct) -ForegroundColor DarkGray
Write-Host ("  Hard stop        : {0:F8} ETH  (-{1}%)" -f $stopThreshETH, $StopPct) -ForegroundColor DarkGray
Write-Host ""

# -- step 3: Phase A — watch for take target -----------------------------------

Write-Host "Step 3 - Phase A: watching for take target (+$TakePct%)..." -ForegroundColor DarkCyan
Write-Host ""

$iteration   = 0
$phaseB_done = $false
$peakRaw     = [double]0
$floorRaw    = [double]0

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        # Quote the full position (refTokenStr) for take/stop checks
        $q          = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $refTokenStr
        $currentRaw = [double]$q.buyAmount
        $currentETH = $currentRaw / $ETH_DECIMALS
        $ts2        = Get-Date -Format "HH:mm:ss"

        # ── Phase C: trailing stop on remainder ────────────────────────────────
        if ($phaseB_done) {
            $rq   = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $remainderTokenStr
            $rRaw = [double]$rq.buyAmount
            $rETH = $rRaw / $ETH_DECIMALS

            # Hard stop on remainder (scaled to remainder size)
            $stopRemainRaw = $stopThreshRaw * $remainderFrac
            if ($rRaw -le $stopRemainRaw) {
                $gainPct = (($rETH - ([double]$Amount * $remainderFrac)) / ([double]$Amount * $remainderFrac)) * 100.0
                Write-Host ""
                Write-Host ("HARD STOP on remainder! {0:F8} ETH back  ({1:F4}% vs remainder cost)" -f $rETH, $gainPct) -ForegroundColor Red
                if ($DryRun) { Write-Host "  [DRY-RUN] Would SELL remainder $remainderTokenStr $TokenLabel -> ETH" -ForegroundColor DarkYellow; exit 0 }
                Run-Sell $remainderTokenStr "hard stop - remainder"
            }

            if ($rRaw -gt $peakRaw) {
                $peakRaw  = $rRaw
                $floorRaw = $peakRaw * (1.0 - $TrailPct / 100.0)
            }

            $peakETH     = $peakRaw / $ETH_DECIMALS
            $floorETH    = $floorRaw / $ETH_DECIMALS
            $pctFromPeak = (($rRaw - $peakRaw) / $peakRaw) * 100.0

            $trailDist   = $peakRaw - $floorRaw
            $distToFloor = $rRaw - $floorRaw
            if ($rRaw -ge $peakRaw) {
                $color = "Green"
            } elseif ($trailDist -gt 0 -and ($distToFloor / $trailDist) -lt 0.25) {
                $color = "DarkRed"
            } else {
                $color = "White"
            }

            Write-Host ("[$ts2] PHASE-C  remainder: {0:F8} ETH  peak: {1:F8}  floor: {2:F8}  ({3:F4}% from peak)" -f `
                $rETH, $peakETH, $floorETH, $pctFromPeak) -ForegroundColor $color

            if ($rRaw -le $floorRaw) {
                $gainPct = (($rETH - ([double]$Amount * $remainderFrac)) / ([double]$Amount * $remainderFrac)) * 100.0
                Write-Host ""
                Write-Host ("Trail floor breached! Remainder: {0:F8} ETH back  ({1:F4}% vs remainder cost)" -f $rETH, $gainPct) -ForegroundColor Red
                if ($DryRun) { Write-Host "  [DRY-RUN] Would SELL remainder $remainderTokenStr $TokenLabel -> ETH" -ForegroundColor DarkYellow; exit 0 }
                Run-Sell $remainderTokenStr "trail stop - remainder"
            }
            continue
        }

        # ── Phase A: hard stop on full position ────────────────────────────────
        if ($currentRaw -le $stopThreshRaw) {
            $lossPct = (($currentETH - [double]$Amount) / [double]$Amount) * 100.0
            Write-Host ""
            Write-Host ("HARD STOP triggered! {0:F8} ETH back  ({1:F4}% vs entry cost)" -f $currentETH, $lossPct) -ForegroundColor Red
            if ($DryRun) { Write-Host "  [DRY-RUN] Would SELL full $refTokenStr $TokenLabel -> ETH" -ForegroundColor DarkYellow; exit 0 }
            Run-Sell $refTokenStr "hard stop - full position"
        }

        # ── Phase A: display and take-profit check ─────────────────────────────
        $pctVsBaseline = (($currentRaw - $baselineRaw) / $baselineRaw) * 100.0
        $pctToTake     = $TakePct - $pctVsBaseline

        if ($currentRaw -ge $takeTargetRaw) {
            $color = "Green"
        } elseif ($pctVsBaseline -ge ($TakePct * 0.5)) {
            $color = "Yellow"
        } elseif ($pctVsBaseline -ge 0) {
            $color = "White"
        } else {
            $color = "DarkGray"
        }

        Write-Host ("[$ts2] PHASE-A  price: {0:F8} ETH  baseline: {1:F8}  ({2:+0.4f}% vs baseline)  take: +{3:F2}%  ({4:+0.4f}% away)" -f `
            $currentETH, $baselineETH, $pctVsBaseline, $TakePct, $pctToTake) -ForegroundColor $color

        if ($currentRaw -ge $takeTargetRaw) {
            Write-Host ""
            Write-Host ("Take target reached! {0:F8} ETH  (+{1:F4}% vs baseline)" -f $currentETH, $pctVsBaseline) -ForegroundColor Green
            Write-Host ("Selling {0}% of position ({1} {2})..." -f $ExitFraction, $partialTokenStr, $TokenLabel) -ForegroundColor Green

            if ($DryRun) {
                Write-Host ("  [DRY-RUN] Would SELL $partialTokenStr $TokenLabel -> ETH") -ForegroundColor DarkYellow
                Write-Host ("  [DRY-RUN] Would trail remaining $remainderTokenStr $TokenLabel with -$TrailPct% stop") -ForegroundColor DarkYellow
            } else {
                Write-Host ">>> speed swap -c $Chain --sell $Token --buy eth -a $partialTokenStr -y" -ForegroundColor Cyan
                speed swap -c $Chain --sell $Token --buy eth -a $partialTokenStr -y
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Partial sell failed (exit $LASTEXITCODE). Aborting."
                    exit $LASTEXITCODE
                }
            }

            Write-Host ""
            Write-Host ("Phase B complete. Trailing {0} {1} ({2}%) with -{3}% stop..." -f `
                $remainderTokenStr, $TokenLabel, [int](100 - $ExitFraction), $TrailPct) -ForegroundColor DarkCyan

            # Anchor trail on remainder's current value
            $rq       = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $remainderTokenStr
            $peakRaw  = [double]$rq.buyAmount
            $floorRaw = $peakRaw * (1.0 - $TrailPct / 100.0)
            Write-Host ("  Trail peak  : {0:F8} ETH" -f ($peakRaw / $ETH_DECIMALS)) -ForegroundColor DarkGray
            Write-Host ("  Trail floor : {0:F8} ETH  (-{1}%)" -f ($floorRaw / $ETH_DECIMALS), $TrailPct) -ForegroundColor DarkGray
            Write-Host ""

            $phaseB_done = $true
        }

    } catch {
        Write-Warning "Poll $iteration failed: $_ - retrying next interval."
    }
}

# -- max iterations ------------------------------------------------------------

Write-Host ""
if ($phaseB_done) {
    Write-Host "Max iterations ($MaxIterations) reached. Selling remainder..." -ForegroundColor Yellow
    if ($DryRun) { Write-Host "  [DRY-RUN] Would SELL $remainderTokenStr $TokenLabel -> ETH" -ForegroundColor DarkYellow; exit 0 }
    Run-Sell $remainderTokenStr "max iterations - remainder"
} else {
    Write-Host "Max iterations ($MaxIterations) reached. Selling full position..." -ForegroundColor Yellow
    if ($DryRun) { Write-Host "  [DRY-RUN] Would SELL $refTokenStr $TokenLabel -> ETH" -ForegroundColor DarkYellow; exit 0 }
    Run-Sell $refTokenStr "max iterations - full position"
}
