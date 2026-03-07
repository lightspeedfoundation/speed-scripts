<#
.SYNOPSIS
    Trailing stop-loss: buy any token with ETH, then sell when ETH return drops
    -TrailPct% below the running peak.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Quotes ETH -> <Token> to show what you will get.
    3. Executes the buy (ETH -> <Token>).
    4. Gets a baseline sell quote to set the initial peak.
    5. Polls <Token> -> ETH every -PollSeconds seconds.
       - If ETH return exceeds the current peak, the peak (and floor) rise.
       - If ETH return drops below floor (peak * (1 - TrailPct/100)), sells immediately.
    6. Falls back to selling after -MaxIterations polls regardless.

    The floor trails the peak upward and never moves back down.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH / native is always the sell currency.

.EXAMPLE
    .\trailing-stop-any.ps1 -Chain base -Token speed -Amount 0.001 -TrailPct 5
    .\trailing-stop-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -Amount 0.002 -TrailPct 3
    .\trailing-stop-any.ps1 -Chain base -Token 0x... -TokenSymbol PEPE -Amount 0.01 -TrailPct 10 -PollSeconds 30
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,         # address or alias
    [Parameter(Mandatory)][string] $Amount,        # ETH you are spending
    [Parameter(Mandatory)][double] $TrailPct,      # % drop from peak that triggers sell
    [string]                       $TokenSymbol   = "",
    [int]                          $PollSeconds   = 60,
    [int]                          $MaxIterations = 1440
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ETH_DECIMALS = [double]1e18

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
    Write-Host ">>> Executing: speed swap -c $Chain --sell $Token --buy eth -a $tokenAmount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell $Token --buy eth -a $tokenAmount -y
    exit $LASTEXITCODE
}

# ── setup ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$TOKEN_DECIMALS = [Math]::Pow(10, $tokenDecimals)

$TokenLabel = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

Write-Host ""
Write-Host "=== Speed Trailing Stop-Loss ===" -ForegroundColor Yellow
Write-Host "  Chain         : $Chain"
Write-Host "  Token         : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  ETH spent     : $Amount ETH"
Write-Host "  Trail %       : $TrailPct % drop from peak triggers sell"
Write-Host "  Poll interval : $PollSeconds s"
Write-Host "  Max polls     : $MaxIterations"
Write-Host ""

# ── step 1: quote the buy ─────────────────────────────────────────────────────

Write-Host "Step 1 - Quoting ETH -> $TokenLabel for $Amount ETH..." -ForegroundColor DarkCyan

$buyQuote   = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $Amount
$tokenRaw   = [double]$buyQuote.buyAmount
$tokenHuman = $tokenRaw / $TOKEN_DECIMALS
$tokenStr   = $tokenHuman.ToString("F$tokenDecimals")

if ([double]$tokenStr -le 0) {
    Write-Error "Token amount resolved to 0 (raw=$tokenRaw, decimals=$tokenDecimals). Aborting."
    exit 1
}

Write-Host ("  You will get : {0} {1} for {2} ETH" -f $tokenStr, $TokenLabel, $Amount)
Write-Host ""

# ── step 2: execute the buy ───────────────────────────────────────────────────

Write-Host "Step 2 - Buying $TokenLabel..." -ForegroundColor DarkCyan
Write-Host ">>> Executing: speed swap -c $Chain --sell eth --buy $Token -a $Amount -y" -ForegroundColor Cyan
speed swap -c $Chain --sell eth --buy $Token -a $Amount -y
if ($LASTEXITCODE -ne 0) {
    Write-Error "Buy swap failed (exit $LASTEXITCODE). Aborting."
    exit $LASTEXITCODE
}
Write-Host ""

# ── step 3: baseline sell quote — sets initial peak ───────────────────────────

Write-Host "Step 3 - Baseline sell quote ($TokenLabel -> ETH)..." -ForegroundColor DarkCyan

$sellQuote   = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
$baselineRaw = [double]$sellQuote.buyAmount
$baselineETH = $baselineRaw / $ETH_DECIMALS

# Peak starts at baseline; floor = peak * (1 - TrailPct/100)
$peakRaw  = $baselineRaw
$floorRaw = $peakRaw * (1.0 - $TrailPct / 100.0)
$peakETH  = $baselineETH
$floorETH = $floorRaw / $ETH_DECIMALS

Write-Host ("  Baseline ETH back : {0:F8} ETH" -f $baselineETH)
Write-Host ("  Initial peak      : {0:F8} ETH" -f $peakETH)
Write-Host ("  Initial floor     : {0:F8} ETH  (peak - {1} %)" -f $floorETH, $TrailPct)
Write-Host ""

# ── step 4: poll with trailing floor ─────────────────────────────────────────

$iteration = 0

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $q       = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
        $current = [double]$q.buyAmount
        $ethBack = $current / $ETH_DECIMALS
        $ts2     = Get-Date -Format "HH:mm:ss"

        # Update peak if new high
        if ($current -gt $peakRaw) {
            $peakRaw  = $current
            $floorRaw = $peakRaw * (1.0 - $TrailPct / 100.0)
            $peakETH  = $peakRaw / $ETH_DECIMALS
            $floorETH = $floorRaw / $ETH_DECIMALS
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

        Write-Host ("[$ts2] {0:F8} ETH  peak: {1:F8}  floor: {2:F8}  ({3:F4} % from peak)" -f $ethBack, $peakETH, $floorETH, $pctFromPeak) -ForegroundColor $color

        if ($current -le $floorRaw) {
            $gainPct = (($current - $baselineRaw) / $baselineRaw) * 100.0
            Write-Host ""
            Write-Host ("Floor breached! {0:F8} ETH back  ({1:F4} % vs baseline)" -f $ethBack, $gainPct) -ForegroundColor Red
            Run-Sell $tokenStr
        }
    } catch {
        Write-Warning "Quote failed on poll $iteration : $_ - retrying next interval."
    }
}

# ── max iterations hit ────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Max iterations ($MaxIterations) reached. Selling now." -ForegroundColor Yellow
Run-Sell $tokenStr
