<#
.SYNOPSIS
    Bracket (OCO) order: buy any token with -BaseToken, then hold two simultaneous exit
    conditions — a take-profit ceiling and a stop-loss floor. The first to trigger
    fires the sell; the other is cancelled automatically.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes BaseToken -> <Token> to show what you will get.
    3. Executes the buy (BaseToken -> <Token>).
    4. Gets a baseline sell quote to anchor both levels:
         takeTarget = baselineRaw * (1 + TakePct/100)
         stopFloor  = baselineRaw * (1 - StopPct/100)
    5. Polls every -PollSeconds seconds.
       - If base return >= takeTarget : take-profit fires -> sell and exit.
       - If base return <= stopFloor  : stop-loss fires   -> sell and exit.
    6. Falls back to a market sell after -MaxIterations polls.

    Philosophically: every other script exits on ONE condition. Bracket defines
    the complete risk/reward envelope at entry — ceiling and floor simultaneously.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    Exit levels are measured in -BaseToken returned for the full position.

.PARAMETER Amount
    Amount of -BaseToken to spend on the initial buy (speed swap -a uses this asset).

.PARAMETER TakePct
    % above baseline base return to trigger the take-profit sell.

.PARAMETER StopPct
    % below baseline base return to trigger the stop-loss sell.

.PARAMETER DryRun
    Log bracket signals without buying or selling.

.EXAMPLE
    .\bracket-any.ps1 -Chain base -Token speed -Amount 0.002 -TakePct 10 -StopPct 5
    .\bracket-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.012 -TakePct 5 -StopPct 3 -PollSeconds 30
    .\bracket-any.ps1 -Chain base -Token speed -Amount 0.001 -TakePct 8 -StopPct 4 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $Amount,
    [Parameter(Mandatory)][double] $TakePct,
    [Parameter(Mandatory)][double] $StopPct,
    [string]  $TokenSymbol   = "",
    [int]     $PollSeconds   = 60,
    [int]     $MaxIterations = 1440,
    [switch]  $DryRun,
    [string]                       $BaseToken       = 'speed',
    [string]                       $BaseTokenSymbol = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"


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
    param([string]$tokenAmount, [string]$reason)
    Write-Host ""
    Write-Host ">>> $reason - Executing: speed swap -c $Chain --sell $Token --buy $BaseToken -a $tokenAmount -y" -ForegroundColor Cyan
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

if ($TakePct -le 0) { Write-Error "-TakePct must be > 0."; exit 1 }
if ($StopPct -le 0) { Write-Error "-StopPct must be > 0."; exit 1 }

Write-Host ""
Write-Host "=== Speed Bracket Order (OCO) ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- no buy or sell will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain         : $Chain"
Write-Host "  Token         : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  Base spent    : $Amount $($script:BaseLabel)"
Write-Host "  Take-profit   : +$TakePct % above entry baseline"
Write-Host "  Stop-loss     : -$StopPct % below entry baseline"
Write-Host "  Poll interval : $PollSeconds s"
Write-Host "  Max polls     : $MaxIterations"
Write-Host ""

# -- step 1: quote the buy -----------------------------------------------------

Write-Host "Step 1 - Quoting $($script:BaseLabel) -> $TokenLabel for $Amount $($script:BaseLabel)..." -ForegroundColor DarkCyan

$buyQuote   = Get-Quote -sellTok $BaseToken -buyTok $Token -sellAmt $Amount
$tokenRaw   = [double]$buyQuote.buyAmount
$tokenHuman = $tokenRaw / $TOKEN_SCALE
$tokenStr   = $tokenHuman.ToString("F$tokenDecimals")

if ([double]$tokenStr -le 0) {
    Write-Error "Token amount resolved to 0 (raw=$tokenRaw, decimals=$tokenDecimals). Aborting."
    exit 1
}
Write-Host ("  You will get : {0} {1} for {2} {3}" -f $tokenStr, $TokenLabel, $Amount, $script:BaseLabel)
Write-Host ""

# -- step 2: execute the buy ---------------------------------------------------

Write-Host "Step 2 - Buying $TokenLabel..." -ForegroundColor DarkCyan

if ($DryRun) {
    Write-Host "  [DRY-RUN] Would execute: speed swap -c $Chain --sell $BaseToken --buy $Token -a $Amount -y" -ForegroundColor DarkYellow
} else {
    Write-Host ">>> Executing: speed swap -c $Chain --sell $BaseToken --buy $Token -a $Amount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell $BaseToken --buy $Token -a $Amount -y
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Buy swap failed (exit $LASTEXITCODE). Aborting."
        exit $LASTEXITCODE
    }
}
Write-Host ""

# -- step 3: baseline sell quote — anchors both levels -------------------------

Write-Host "Step 3 - Baseline sell quote ($TokenLabel -> $($script:BaseLabel))..." -ForegroundColor DarkCyan

$sellQuote   = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $tokenStr
$baselineRaw = [double]$sellQuote.buyAmount
$baselineETH = $baselineRaw / $script:BASE_DECIMALS_SCALE

$takeTargetRaw = $baselineRaw * (1.0 + $TakePct / 100.0)
$stopFloorRaw  = $baselineRaw * (1.0 - $StopPct / 100.0)
$takeTargetETH = $takeTargetRaw / $script:BASE_DECIMALS_SCALE
$stopFloorETH  = $stopFloorRaw  / $script:BASE_DECIMALS_SCALE

Write-Host ("  Baseline {1} back : {0:F8} {1}" -f $baselineETH, $script:BaseLabel)
Write-Host ("  Take-profit target: {0:F8} {2}  (baseline +{1}%)" -f $takeTargetETH, $TakePct, $script:BaseLabel)
Write-Host ("  Stop-loss floor   : {0:F8} {2}  (baseline -{1}%)" -f $stopFloorETH, $StopPct, $script:BaseLabel)
Write-Host ""

# -- step 4: poll for bracket exits --------------------------------------------

Write-Host "Step 4 - Monitoring bracket. First level hit wins..." -ForegroundColor DarkCyan
Write-Host ""

$iteration = 0

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $q          = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $tokenStr
        $currentRaw = [double]$q.buyAmount
        $currentETH = $currentRaw / $script:BASE_DECIMALS_SCALE
        $ts2        = Get-Date -Format "HH:mm:ss"

        $pctVsBase = (($currentRaw - $baselineRaw) / $baselineRaw) * 100.0
        $pctToTP   = if ($currentRaw -gt 0) { (($takeTargetRaw - $currentRaw) / $currentRaw) * 100.0 } else { 0.0 }
        $pctToSL   = if ($currentRaw -gt 0) { (($currentRaw - $stopFloorRaw)  / $currentRaw) * 100.0 } else { 0.0 }

        # Color logic: green = at/above TP, red = at/below SL, yellow = within 25% of either level
        $tpZone = ($takeTargetRaw - $baselineRaw) * 0.25
        $slZone = ($baselineRaw - $stopFloorRaw) * 0.25

        if ($currentRaw -ge $takeTargetRaw) {
            $color = "Green"
        } elseif ($currentRaw -le $stopFloorRaw) {
            $color = "Red"
        } elseif ($currentRaw -ge ($takeTargetRaw - $tpZone)) {
            $color = "Yellow"
        } elseif ($currentRaw -le ($stopFloorRaw + $slZone)) {
            $color = "DarkRed"
        } else {
            $color = "White"
        }

        Write-Host ("[$ts2] {0:F8} {6}  ({1:F4}% vs entry)  TP: +{2:F4}% to target  SL: {3:F4}% cushion to floor  [take: {4:F8} {6}  stop: {5:F8} {6}]" -f `
            $currentETH, $pctVsBase, $pctToTP, $pctToSL, $takeTargetETH, $stopFloorETH, $script:BaseLabel) -ForegroundColor $color

        # Take-profit check
        if ($currentRaw -ge $takeTargetRaw) {
            $gainPct = (($currentETH - [double]$Amount) / [double]$Amount) * 100.0
            Write-Host ""
            Write-Host ("TAKE-PROFIT triggered! {0:F8} {2} back  ({1:F4}% gain vs base spent)" -f $currentETH, $gainPct, $script:BaseLabel) -ForegroundColor Green
            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would SELL $tokenStr $TokenLabel -> $($script:BaseLabel) now." -ForegroundColor DarkYellow
                exit 0
            }
            Run-Sell -tokenAmount $tokenStr -reason "TAKE-PROFIT"
        }

        # Stop-loss check
        if ($currentRaw -le $stopFloorRaw) {
            $lossPct = (($currentETH - [double]$Amount) / [double]$Amount) * 100.0
            Write-Host ""
            Write-Host ("STOP-LOSS triggered! {0:F8} {2} back  ({1:F4}% vs base spent)" -f $currentETH, $lossPct, $script:BaseLabel) -ForegroundColor Red
            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would SELL $tokenStr $TokenLabel -> $($script:BaseLabel) now." -ForegroundColor DarkYellow
                exit 0
            }
            Run-Sell -tokenAmount $tokenStr -reason "STOP-LOSS"
        }

    } catch {
        Write-Warning "Quote failed on poll $iteration : $_ - retrying next interval."
    }
}

# -- max iterations ------------------------------------------------------------

Write-Host ""
Write-Host "Max iterations ($MaxIterations) reached. Selling at market..." -ForegroundColor Yellow
if ($DryRun) {
    Write-Host "  [DRY-RUN] Would SELL $tokenStr $TokenLabel -> $($script:BaseLabel) now." -ForegroundColor DarkYellow
    exit 0
}
Run-Sell -tokenAmount $tokenStr -reason "TIMEOUT"
