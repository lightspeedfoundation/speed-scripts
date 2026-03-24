<#
.SYNOPSIS
    Trailing stop-loss: buy any token with -BaseToken, then sell when base return drops
    -TrailPct% below the running peak.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes BaseToken -> <Token> to show what you will get.
    3. Executes the buy (BaseToken -> <Token>).
    4. Gets a baseline sell quote to set the initial peak.
    5. Polls <Token> -> BaseToken every -PollSeconds seconds.
       - If base return exceeds the current peak, the peak (and floor) rise.
       - If base return drops below floor (peak * (1 - TrailPct/100)), sells immediately.
    6. Falls back to selling after -MaxIterations polls regardless.

    The floor trails the peak upward and never moves back down.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    Peak/floor are measured in -BaseToken received for the position (default: speed).

.EXAMPLE
    .\trailing-stop-any.ps1 -Chain base -Token speed -Amount 0.001 -TrailPct 5
    .\trailing-stop-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.002 -TrailPct 3
    .\trailing-stop-any.ps1 -Chain base -Token 0x... -TokenSymbol PEPE -Amount 0.01 -TrailPct 10 -PollSeconds 30
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,         # address or alias
    [Parameter(Mandatory)][string] $Amount,        # base token units (-BaseToken)
    [Parameter(Mandatory)][double] $TrailPct,      # % drop from peak that triggers sell
    [string]                       $TokenSymbol   = "",
    [int]                          $PollSeconds   = 60,
    [int]                          $MaxIterations = 1440,
    [string]                       $BaseToken       = 'speed',
    [string]                       $BaseTokenSymbol = '',
    [switch]                       $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Join-Path $PSScriptRoot '..') '_speed_json.ps1')

# RPC endpoints by chain name (mirrors CLI constants)
$RPC_URLS = @{
    "base"     = "https://mainnet.base.org"
    "8453"     = "https://mainnet.base.org"
    "mainnet"  = "https://eth.llamarpc.com"
    "ethereum" = "https://eth.llamarpc.com"
    "1"        = "https://eth.llamarpc.com"
    "optimism" = "https://mainnet.optimism.io"
    "10"       = "https://mainnet.optimism.io"
    "arbitrum" = "https://arb1.arbitrum.io/rpc"
    "42161"    = "https://arb1.arbitrum.io/rpc"
    "polygon"  = "https://polygon.llamarpc.com"
    "137"      = "https://polygon.llamarpc.com"
    "bsc"      = "https://bsc-dataseed.binance.org"
    "56"       = "https://bsc-dataseed.binance.org"
}

# ── helpers ───────────────────────────────────────────────────────────────────

function Get-TokenDecimals {
    param([string]$tokenAddr, [string]$chainName)

    $lower = $tokenAddr.ToLower()
    if ($lower -eq 'speed' -or $lower -eq 'eth' -or $lower -eq 'native') { return 18 }
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
    if (-not $line) {
        throw "No JSON from quote. Output:`n$($raw -join "`n")"
    }
    $obj = $line | ConvertFrom-Json
    if (-not ($obj.PSObject.Properties.Name -contains 'buyAmount')) {
        throw "Quote error: $($obj.error)"
    }
    return $obj
}

function Run-Sell {
    param([string]$tokenAmount)
    Write-Host ""
    if ($script:DryRun) {
        Write-Host ">>> [DRY-RUN] Would execute: speed swap -c $Chain --sell $Token --buy $BaseToken -a $tokenAmount -y" -ForegroundColor Yellow
        return
    }
    Write-Host ">>> Executing: speed swap -c $Chain --sell $Token --buy $BaseToken -a $tokenAmount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell $Token --buy $BaseToken -a $tokenAmount -y
    exit $LASTEXITCODE
}

# ── setup ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$TOKEN_DECIMALS = [Math]::Pow(10, $tokenDecimals)

$TokenLabel = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

# v2: configurable base token (default Speed; use ETH when Token is also Speed)
if ($BaseToken.ToLower() -eq $Token.ToLower()) { $BaseToken = 'eth' }
$baseDecimals = Get-TokenDecimals -tokenAddr $BaseToken -chainName $Chain
$script:BASE_DECIMALS_SCALE = [Math]::Pow(10, $baseDecimals)
$script:BaseLabel = if ($BaseTokenSymbol -ne "") { $BaseTokenSymbol } else { $BaseToken }

$script:DryRun = [bool]$DryRun

Write-Host ""
Write-Host "=== Speed Trailing Stop-Loss ===" -ForegroundColor Yellow
Write-Host "  Chain         : $Chain"
Write-Host "  Token         : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  Base spent    : $Amount $($script:BaseLabel)"
Write-Host "  Trail %       : $TrailPct % drop from peak triggers sell"
Write-Host "  Poll interval : $PollSeconds s"
Write-Host "  Max polls     : $MaxIterations"
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- no swaps will execute ***" -ForegroundColor Yellow }
Write-Host ""

# ── step 1: quote the buy ─────────────────────────────────────────────────────

Write-Host "Step 1 - Quoting $($script:BaseLabel) -> $TokenLabel for $Amount $($script:BaseLabel)..." -ForegroundColor DarkCyan

$buyQuote   = Get-Quote -sellTok $BaseToken -buyTok $Token -sellAmt $Amount
$tokenRaw   = [double]$buyQuote.buyAmount
$tokenHuman = $tokenRaw / $TOKEN_DECIMALS
$tokenStr   = $tokenHuman.ToString("F$tokenDecimals")

if ([double]$tokenStr -le 0) {
    Write-Error "Token amount resolved to 0 (raw=$tokenRaw, decimals=$tokenDecimals). Aborting."
    exit 1
}

Write-Host ("  You will get : {0} {1} for {2} {3}" -f $tokenStr, $TokenLabel, $Amount, $script:BaseLabel)
Write-Host ""

# ── step 2: execute the buy ───────────────────────────────────────────────────

if ($DryRun) {
    Write-Host "Step 2 - [DRY-RUN] Skipping buy; using Step 1 quote buy amount." -ForegroundColor DarkCyan
    $tokenRaw   = [double]$buyQuote.buyAmount
    $tokenHuman = $tokenRaw / $TOKEN_DECIMALS
    $tokenStr   = $tokenHuman.ToString("F$tokenDecimals")
    Write-Host ""
} else {
    Write-Host "Step 2 - Buying $TokenLabel..." -ForegroundColor DarkCyan
    Write-Host ">>> Executing: speed swap -c $Chain --sell $BaseToken --buy $Token -a $Amount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell $BaseToken --buy $Token -a $Amount -y
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Buy swap failed (exit $LASTEXITCODE). Aborting."
        exit $LASTEXITCODE
    }
    $tokenRaw = [double]$buyQuote.buyAmount
    $tokenHuman = $tokenRaw / $TOKEN_DECIMALS
    $tokenStr   = $tokenHuman.ToString("F$tokenDecimals")
    Write-Host ""
}

# ── step 3: baseline sell quote — sets initial peak ───────────────────────────

Write-Host "Step 3 - Baseline sell quote ($TokenLabel -> $($script:BaseLabel))..." -ForegroundColor DarkCyan

$sellQuote   = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $tokenStr
$baselineRaw = [double]$sellQuote.buyAmount
$baselineETH = $baselineRaw / $script:BASE_DECIMALS_SCALE

# Peak starts at baseline; floor = peak * (1 - TrailPct/100)
$peakRaw  = $baselineRaw
$floorRaw = $peakRaw * (1.0 - $TrailPct / 100.0)
$peakETH  = $baselineETH
$floorETH = $floorRaw / $script:BASE_DECIMALS_SCALE

Write-Host ("  Baseline {1} back : {0:F8} {1}" -f $baselineETH, $script:BaseLabel)
Write-Host ("  Initial peak      : {0:F8} {1}" -f $peakETH, $script:BaseLabel)
Write-Host ("  Initial floor     : {0:F8} {2}  (peak - {1} %)" -f $floorETH, $TrailPct, $script:BaseLabel)
Write-Host ""

# ── step 4: poll with trailing floor ─────────────────────────────────────────

$iteration = 0

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $q       = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $tokenStr
        $current = [double]$q.buyAmount
        $ethBack = $current / $script:BASE_DECIMALS_SCALE
        $ts2     = Get-Date -Format "HH:mm:ss"

        # Update peak if new high
        if ($current -gt $peakRaw) {
            $peakRaw  = $current
            $floorRaw = $peakRaw * (1.0 - $TrailPct / 100.0)
            $peakETH  = $peakRaw / $script:BASE_DECIMALS_SCALE
            $floorETH = $floorRaw / $script:BASE_DECIMALS_SCALE
        }

        $pctFromPeak = (($current - $peakRaw) / $peakRaw) * 100.0
        $pctFromFloor = (($current - $floorRaw) / $floorRaw) * 100.0

        # Color: green = new peak, red = within 25% of floor distance, white = ok
        $trailDistance = $peakRaw - $floorRaw
        $distanceToFloor = $current - $floorRaw
        if ($current -ge $peakRaw) {
            $color = "Green"
        } elseif ($trailDistance -gt 0 -and ($distanceToFloor / $trailDistance) -lt 0.25) {
            $color = "DarkRed"
        } else {
            $color = "White"
        }

        Write-Host ("[$ts2] {0:F8} {4}  peak: {1:F8} {4}  floor: {2:F8} {4}  ({3:F4}% from peak  {5:F4}% from floor)" -f $ethBack, $peakETH, $floorETH, $pctFromPeak, $script:BaseLabel, $pctFromFloor) -ForegroundColor $color

        if ($current -le $floorRaw) {
            $gainPct = (($current - $baselineRaw) / $baselineRaw) * 100.0
            Write-Host ""
            Write-Host ("Floor breached! {0:F8} {2} back  ({1:F4} % vs baseline)" -f $ethBack, $gainPct, $script:BaseLabel) -ForegroundColor Red
            Run-Sell $tokenStr
            if ($script:DryRun) { exit 0 }
        }
    } catch {
        Write-Warning "Quote failed on poll $iteration : $_ - retrying next interval."
    }
}

# ── max iterations hit ────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Max iterations ($MaxIterations) reached. Selling now." -ForegroundColor Yellow
Run-Sell $tokenStr
if ($script:DryRun) { exit 0 }
