<#
.SYNOPSIS
    Limit order: buy any token with -BaseToken, then sell when base return rises by -TargetPct.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call (no manual -TokenDecimals needed).
    2. Quotes BaseToken -> <Token> to show what you will get.
    3. Executes the buy (BaseToken -> <Token>).
    4. Polls <Token> -> BaseToken every -PollSeconds seconds.
    5. Fires the sell when base return >= original base spent * (1 + TargetPct/100).
    6. Falls back to selling after -MaxIterations polls regardless.

    Success is measured in BaseToken: you spent X base, you want X * (1 + target%) back.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    Target is measured in -BaseToken returned vs. amount spent.

.EXAMPLE
    .\limit-order-any.ps1 -Chain base -Token speed -Amount 0.001 -TargetPct 5
    .\limit-order-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -Amount 0.002 -TargetPct 2.5
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,      # address or alias
    [Parameter(Mandatory)][string] $Amount,     # base token units you are spending (-BaseToken)
    [Parameter(Mandatory)][double] $TargetPct,
    [string]                       $TokenSymbol   = "",
    [int]                          $PollSeconds   = 60,
    [int]                          $MaxIterations = 1440,
    [string]                       $BaseToken       = 'speed',
    [string]                       $BaseTokenSymbol = '',
    [switch]                       $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"


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
    if ($script:DryRun) {
        Write-Host ">>> [DRY-RUN] Would execute: speed swap -c $Chain --sell $Token --buy $BaseToken -a $tokenAmount -y" -ForegroundColor Yellow
        return
    }
    Write-Host ">>> Executing: speed swap -c $Chain --sell $Token --buy $BaseToken -a $tokenAmount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell $Token --buy $BaseToken -a $tokenAmount -y
    exit $LASTEXITCODE
}

# ── setup ─────────────────────────────────────────────────────────────────────

# Auto-detect decimals
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
Write-Host "=== Speed Limit Order ===" -ForegroundColor Yellow
Write-Host "  Chain         : $Chain"
Write-Host "  Token         : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  Base spent    : $Amount $($script:BaseLabel)"
Write-Host "  Target return : +$TargetPct %"
Write-Host "  Poll interval : $PollSeconds s"
Write-Host "  Max polls     : $MaxIterations"
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- no swaps will execute ***" -ForegroundColor Yellow }
Write-Host ""

# ── step 1: quote the buy ─────────────────────────────────────────────────────

Write-Host "Step 1 - Quoting $($script:BaseLabel) -> $TokenLabel for $Amount $($script:BaseLabel)..." -ForegroundColor DarkCyan

$buyQuote   = Get-Quote -sellTok $BaseToken -buyTok $Token -sellAmt $Amount
$tokenRaw   = [double]$buyQuote.buyAmount
$tokenHuman = $tokenRaw / $TOKEN_DECIMALS
# Format as plain decimal (no scientific notation) using token's own decimal count
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
    Write-Host ""
} else {
    Write-Host "Step 2 - Buying $TokenLabel..." -ForegroundColor DarkCyan
    Write-Host ">>> Executing: speed swap -c $Chain --sell $BaseToken --buy $Token -a $Amount -y" -ForegroundColor Cyan
    speed swap -c $Chain --sell $BaseToken --buy $Token -a $Amount -y
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Buy swap failed (exit $LASTEXITCODE). Aborting."
        exit $LASTEXITCODE
    }
    Write-Host ""
}

# ── step 3: baseline sell quote ───────────────────────────────────────────────

Write-Host "Step 3 - Baseline sell quote ($TokenLabel -> $($script:BaseLabel))..." -ForegroundColor DarkCyan

$sellQuote   = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $tokenStr
$baselineRaw = [double]$sellQuote.buyAmount
$baselineETH = $baselineRaw / $script:BASE_DECIMALS_SCALE

$targetRaw = [double]$Amount * $script:BASE_DECIMALS_SCALE * (1.0 + $TargetPct / 100.0)
$targetETH = [double]$Amount * (1.0 + $TargetPct / 100.0)

Write-Host ("  Baseline {1} back : {0:F8} {1}" -f $baselineETH, $script:BaseLabel)
Write-Host ("  Target {3} back   : {0:F8} {3}  (paid {1} {3}, want +{2} %)" -f $targetETH, $Amount, $TargetPct, $script:BaseLabel)
Write-Host ""

# ── step 4: poll for target ───────────────────────────────────────────────────

$iteration = 0

while ($iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration / $MaxIterations - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $q        = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $tokenStr
        $current  = [double]$q.buyAmount
        $ethBack  = $current / $script:BASE_DECIMALS_SCALE
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

        Write-Host ("[$ts2] {0:F8} {3} back  ({1}{2:F4} % vs target)" -f $ethBack, $sign, $pctDelta, $script:BaseLabel) -ForegroundColor $color

        if ($current -ge $targetRaw) {
            Write-Host ""
            Write-Host ("Target reached! {0:F8} {2} back  (+{1:F4} % gain)" -f $ethBack, $pctDelta, $script:BaseLabel) -ForegroundColor Green
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
