<#
.SYNOPSIS
    Bracket (OCO) order: buy any token with ETH, then hold two simultaneous exit
    conditions — a take-profit ceiling and a stop-loss floor. The first to trigger
    fires the sell; the other is cancelled automatically.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes ETH -> <Token> to show what you will get.
    3. Executes the buy (ETH -> <Token>).
    4. Gets a baseline sell quote to anchor both levels:
         takeTarget = baselineRaw * (1 + TakePct/100)
         stopFloor  = baselineRaw * (1 - StopPct/100)
    5. Polls every -PollSeconds seconds.
       - If ETH return >= takeTarget : take-profit fires -> sell and exit.
       - If ETH return <= stopFloor  : stop-loss fires   -> sell and exit.
    6. Falls back to a market sell after -MaxIterations polls.

    Philosophically: every other script exits on ONE condition. Bracket defines
    the complete risk/reward envelope at entry — ceiling and floor simultaneously.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH / native is always the quote currency.

.PARAMETER Amount
    ETH to spend on the initial buy.

.PARAMETER TakePct
    % above baseline ETH return to trigger the take-profit sell.

.PARAMETER StopPct
    % below baseline ETH return to trigger the stop-loss sell.

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
    param([string]$tokenAmount, [string]$reason)
    Write-Host ""
    Write-Host ">>> $reason - Executing: speed swap -c $Chain --sell $Token --buy eth -a $tokenAmount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell $Token --buy eth -a $tokenAmount -y
    exit $LASTEXITCODE
}

# -- setup ---------------------------------------------------------------------

Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$TOKEN_SCALE   = [Math]::Pow(10, $tokenDecimals)
$TokenLabel    = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

if ($TakePct -le 0) { Write-Error "-TakePct must be > 0."; exit 1 }
if ($StopPct -le 0) { Write-Error "-StopPct must be > 0."; exit 1 }

Write-Host ""
Write-Host "=== Speed Bracket Order (OCO) ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- no buy or sell will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain         : $Chain"
Write-Host "  Token         : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  ETH spent     : $Amount ETH"
Write-Host "  Take-profit   : +$TakePct % above entry baseline"
Write-Host "  Stop-loss     : -$StopPct % below entry baseline"
Write-Host "  Poll interval : $PollSeconds s"
Write-Host "  Max polls     : $MaxIterations"
Write-Host ""

# -- step 1: quote the buy -----------------------------------------------------

Write-Host "Step 1 - Quoting ETH -> $TokenLabel for $Amount ETH..." -ForegroundColor DarkCyan

$buyQuote   = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $Amount
$tokenRaw   = [double]$buyQuote.buyAmount
$tokenHuman = $tokenRaw / $TOKEN_SCALE
$tokenStr   = $tokenHuman.ToString("F$tokenDecimals")

if ([double]$tokenStr -le 0) {
    Write-Error "Token amount resolved to 0 (raw=$tokenRaw, decimals=$tokenDecimals). Aborting."
    exit 1
}
Write-Host ("  You will get : {0} {1} for {2} ETH" -f $tokenStr, $TokenLabel, $Amount)
Write-Host ""

# -- step 2: execute the buy ---------------------------------------------------

Write-Host "Step 2 - Buying $TokenLabel..." -ForegroundColor DarkCyan

if ($DryRun) {
    Write-Host "  [DRY-RUN] Would execute: speed swap -c $Chain --sell eth --buy $Token -a $Amount -y" -ForegroundColor DarkYellow
} else {
    Write-Host ">>> Executing: speed swap -c $Chain --sell eth --buy $Token -a $Amount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell eth --buy $Token -a $Amount -y
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Buy swap failed (exit $LASTEXITCODE). Aborting."
        exit $LASTEXITCODE
    }
}
Write-Host ""

# -- step 3: baseline sell quote — anchors both levels -------------------------

Write-Host "Step 3 - Baseline sell quote ($TokenLabel -> ETH)..." -ForegroundColor DarkCyan

$sellQuote   = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
$baselineRaw = [double]$sellQuote.buyAmount
$baselineETH = $baselineRaw / $ETH_DECIMALS

$takeTargetRaw = $baselineRaw * (1.0 + $TakePct / 100.0)
$stopFloorRaw  = $baselineRaw * (1.0 - $StopPct / 100.0)
$takeTargetETH = $takeTargetRaw / $ETH_DECIMALS
$stopFloorETH  = $stopFloorRaw  / $ETH_DECIMALS

Write-Host ("  Baseline ETH back : {0:F8} ETH" -f $baselineETH)
Write-Host ("  Take-profit target: {0:F8} ETH  (baseline +{1}%)" -f $takeTargetETH, $TakePct)
Write-Host ("  Stop-loss floor   : {0:F8} ETH  (baseline -{1}%)" -f $stopFloorETH, $StopPct)
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
        $q          = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
        $currentRaw = [double]$q.buyAmount
        $currentETH = $currentRaw / $ETH_DECIMALS
        $ts2        = Get-Date -Format "HH:mm:ss"

        $pctVsBase = (($currentRaw - $baselineRaw) / $baselineRaw) * 100.0
        $pctToTP   = (($takeTargetRaw - $currentRaw) / $takeTargetRaw) * 100.0
        $pctToSL   = (($currentRaw - $stopFloorRaw)  / $stopFloorRaw)  * 100.0

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

        Write-Host ("[$ts2] {0:F8} ETH  ({1:+0.4f}% vs entry)  TP: {2:+0.4f}% away  SL: {3:+0.4f}% away  [take: {4:F8}  stop: {5:F8}]" -f `
            $currentETH, $pctVsBase, (-$pctToTP), (-$pctToSL), $takeTargetETH, $stopFloorETH) -ForegroundColor $color

        # Take-profit check
        if ($currentRaw -ge $takeTargetRaw) {
            $gainPct = (($currentETH - [double]$Amount) / [double]$Amount) * 100.0
            Write-Host ""
            Write-Host ("TAKE-PROFIT triggered! {0:F8} ETH back  ({1:F4}% gain vs ETH spent)" -f $currentETH, $gainPct) -ForegroundColor Green
            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would SELL $tokenStr $TokenLabel -> ETH now." -ForegroundColor DarkYellow
                exit 0
            }
            Run-Sell -tokenAmount $tokenStr -reason "TAKE-PROFIT"
        }

        # Stop-loss check
        if ($currentRaw -le $stopFloorRaw) {
            $lossPct = (($currentETH - [double]$Amount) / [double]$Amount) * 100.0
            Write-Host ""
            Write-Host ("STOP-LOSS triggered! {0:F8} ETH back  ({1:F4}% vs ETH spent)" -f $currentETH, $lossPct) -ForegroundColor Red
            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would SELL $tokenStr $TokenLabel -> ETH now." -ForegroundColor DarkYellow
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
    Write-Host "  [DRY-RUN] Would SELL $tokenStr $TokenLabel -> ETH now." -ForegroundColor DarkYellow
    exit 0
}
Run-Sell -tokenAmount $tokenStr -reason "TIMEOUT"
