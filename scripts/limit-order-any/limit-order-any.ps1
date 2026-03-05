<#
.SYNOPSIS
    Limit order: buy any token with ETH, then sell when ETH return rises by -TargetPct.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call (no manual -TokenDecimals needed).
    2. Quotes ETH -> <Token> to show what you will get.
    3. Executes the buy (ETH -> <Token>).
    4. Polls <Token> -> ETH every -PollSeconds seconds.
    5. Fires the sell when ETH return >= original ETH * (1 + TargetPct/100).
    6. Falls back to selling after -MaxIterations polls regardless.

    Success is measured in ETH: you spent X ETH, you want X * (1 + target%) back.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH / native is always the sell token.

.EXAMPLE
    .\limit-order-any.ps1 -Chain base -Token speed -Amount 0.001 -TargetPct 5
    .\limit-order-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -Amount 0.002 -TargetPct 2.5
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,      # address or alias
    [Parameter(Mandatory)][string] $Amount,     # ETH you are spending
    [Parameter(Mandatory)][double] $TargetPct,
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

    # aliases are always 18
    $lower = $tokenAddr.ToLower()
    if ($lower -eq 'speed' -or $lower -eq 'eth' -or $lower -eq 'native') { return 18 }
    if (-not $tokenAddr.StartsWith("0x")) { return 18 }

    $rpc = $RPC_URLS[$chainName.ToLower()]
    if (-not $rpc) {
        Write-Warning "Unknown chain '$chainName' for RPC decimals lookup, assuming 18."
        return 18
    }

    # eth_call decimals() = 0x313ce567
    $body = '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"' + $tokenAddr + '","data":"0x313ce567"},"latest"],"id":1}'
    try {
        $resp   = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
        $hex    = $resp.result -replace '^0x', ''
        $dec    = [Convert]::ToInt32($hex.TrimStart('0'), 16)
        return $dec
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

# Auto-detect decimals
Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$TOKEN_DECIMALS = [Math]::Pow(10, $tokenDecimals)

$TokenLabel = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

Write-Host ""
Write-Host "=== Speed Limit Order ===" -ForegroundColor Yellow
Write-Host "  Chain         : $Chain"
Write-Host "  Token         : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  ETH spent     : $Amount ETH"
Write-Host "  Target return : +$TargetPct %"
Write-Host "  Poll interval : $PollSeconds s"
Write-Host "  Max polls     : $MaxIterations"
Write-Host ""

# ── step 1: quote the buy ─────────────────────────────────────────────────────

Write-Host "Step 1 - Quoting ETH -> $TokenLabel for $Amount ETH..." -ForegroundColor DarkCyan

$buyQuote   = Get-Quote -sellTok 'eth' -buyTok $Token -sellAmt $Amount
$tokenRaw   = [double]$buyQuote.buyAmount
$tokenHuman = $tokenRaw / $TOKEN_DECIMALS
# Format as plain decimal (no scientific notation) using token's own decimal count
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

# ── step 3: baseline sell quote ───────────────────────────────────────────────

Write-Host "Step 3 - Baseline sell quote ($TokenLabel -> ETH)..." -ForegroundColor DarkCyan

$sellQuote   = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
$baselineRaw = [double]$sellQuote.buyAmount
$baselineETH = $baselineRaw / $ETH_DECIMALS

$targetRaw = [double]$Amount * $ETH_DECIMALS * (1.0 + $TargetPct / 100.0)
$targetETH = [double]$Amount * (1.0 + $TargetPct / 100.0)

Write-Host ("  Baseline ETH back : {0:F8} ETH" -f $baselineETH)
Write-Host ("  Target ETH back   : {0:F8} ETH  (paid {1} ETH, want +{2} %)" -f $targetETH, $Amount, $TargetPct)
Write-Host ""

# ── step 4: poll for target ───────────────────────────────────────────────────

$iteration = 0

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $q        = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $tokenStr
        $current  = [double]$q.buyAmount
        $ethBack  = $current / $ETH_DECIMALS
        $pctDelta = (($current - $targetRaw) / $targetRaw) * 100.0
        $ts2      = Get-Date -Format "HH:mm:ss"

        if ($current -ge $targetRaw) {
            $color = "Green"
            $sign  = "+"
        } elseif ($pctDelta -gt -1) {
            $color = "White"
            $sign  = ""
        } else {
            $color = "DarkRed"
            $sign  = ""
        }

        Write-Host ("[$ts2] {0:F8} ETH back  ({1}{2:F4} % vs target)" -f $ethBack, $sign, $pctDelta) -ForegroundColor $color

        if ($current -ge $targetRaw) {
            Write-Host ""
            Write-Host ("Target reached! {0:F8} ETH back  (+{1:F4} % gain)" -f $ethBack, $pctDelta) -ForegroundColor Green
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
