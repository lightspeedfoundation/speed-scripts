<#
.SYNOPSIS
    TWAP buy: split a total -BaseToken amount into N equal slices and execute one buy
    per -IntervalSeconds, regardless of price. Reduces timing risk and average
    entry variance on larger positions.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Computes sliceAmount = TotalAmount / Slices.
    3. For each slice 1..Slices:
       a. Quotes BaseToken -> <Token> for sliceAmount (preview).
       b. Executes the buy (or logs in DryRun).
       c. Records tokens received and effective price.
       d. Waits IntervalSeconds before the next slice (skipped on last).
    4. Prints a full execution summary: total tokens, average price, variance.

    TWAP is an execution algorithm, not a strategy. The goal is minimising
    market impact and timing risk on a known total order size, not accumulation
    over an indefinite period (that is DCA / value-average).

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    Slices spend -TotalAmount of -BaseToken (default: speed).

.PARAMETER TotalAmount
    Total -BaseToken to deploy across all slices.

.PARAMETER Slices
    Number of equal buy slices. Default: 5.

.PARAMETER IntervalSeconds
    Wait time between slices. Default: 300 (5 minutes).

.PARAMETER DryRun
    Quote each slice and log timing without executing any buys.

.EXAMPLE
    .\twap-buy-any.ps1 -Chain base -Token speed -TotalAmount 0.01 -Slices 5 -IntervalSeconds 300
    .\twap-buy-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -TotalAmount 0.05 -Slices 10 -IntervalSeconds 600
    .\twap-buy-any.ps1 -Chain base -Token speed -TotalAmount 0.01 -Slices 5 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $TotalAmount,
    [string]  $TokenSymbol     = "",
    [int]     $Slices          = 5,
    [int]     $IntervalSeconds = 300,
    [switch]  $DryRun,
    [string]                       $BaseToken       = 'speed',
    [string]                       $BaseTokenSymbol = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Join-Path $PSScriptRoot '..') '_speed_json.ps1')

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

if ($Slices -lt 1)          { Write-Error "-Slices must be >= 1."; exit 1 }
if ($IntervalSeconds -lt 0) { Write-Error "-IntervalSeconds must be >= 0."; exit 1 }

# Compute slice amount
$totalEth  = [double]$TotalAmount
$sliceEth  = $totalEth / $Slices
$sliceStr  = $sliceEth.ToString("F18").TrimEnd('0').TrimEnd('.')
# Ensure at least 6 significant figures for the swap
if ($sliceStr -notmatch '\.') { $sliceStr = $sliceEth.ToString("F8") }

$totalDuration = ($Slices - 1) * $IntervalSeconds

Write-Host ""
Write-Host "=== Speed TWAP Buy ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- no buys will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain          : $Chain"
Write-Host "  Token          : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host "  Total base     : $TotalAmount $($script:BaseLabel)"
Write-Host "  Slices         : $Slices  (${sliceEth} $($script:BaseLabel) each)"
Write-Host "  Interval       : $IntervalSeconds s between slices"
Write-Host ("  Total duration : {0} min  ({1} s)" -f [int]($totalDuration / 60), $totalDuration)
Write-Host ""

# -- execution loop ------------------------------------------------------------

$slicePrices   = @()   # base-per-token price for each slice
$sliceTokens   = @()   # raw token amount received per slice
$totalTokenRaw = [double]0
$failedSlices  = 0

for ($i = 1; $i -le $Slices; $i++) {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$ts] Slice {0}/{1} - quoting {2} {4} -> {3}..." -f $i, $Slices, $sliceEth, $TokenLabel, $script:BaseLabel) -ForegroundColor DarkCyan

    try {
        $q        = Get-Quote -sellTok $BaseToken -buyTok $Token -sellAmt $sliceStr
        $tokRaw   = [double]$q.buyAmount
        $tokHuman = $tokRaw / $TOKEN_SCALE
        $tokStr   = $tokHuman.ToString("F$tokenDecimals")
        # Price: base per token = sliceEth / tokHuman
        $price    = if ($tokHuman -gt 0) { $sliceEth / $tokHuman } else { 0.0 }

        Write-Host ("         Quote: {0} {1}  (price: {2:F8} {3}/token)" -f $tokStr, $TokenLabel, $price, $script:BaseLabel) -ForegroundColor DarkGray

        if ($DryRun) {
            Write-Host ("         [DRY-RUN] Would BUY {0} {3} -> {1} {2}" -f $sliceEth, $tokStr, $TokenLabel, $script:BaseLabel) -ForegroundColor DarkYellow
            $slicePrices += $price
            $sliceTokens += $tokRaw
            $totalTokenRaw += $tokRaw
        } else {
            Write-Host ("         >>> speed swap -c $Chain --sell $BaseToken --buy $Token -a $sliceStr -y") -ForegroundColor Cyan
            speed swap -c $Chain --sell $BaseToken --buy $Token -a $sliceStr -y
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Slice $i buy failed (exit $LASTEXITCODE). Skipping."
                $failedSlices++
            } else {
                $actTokRaw = $tokRaw
                $actTokHuman = $actTokRaw / $TOKEN_SCALE
                $actPrice    = if ($actTokHuman -gt 0) { $sliceEth / $actTokHuman } else { 0.0 }
                $slicePrices += $actPrice
                $sliceTokens += $actTokRaw
                $totalTokenRaw += $actTokRaw
                $actStr = $actTokHuman.ToString("F$tokenDecimals")
                Write-Host ("         Slice {0} complete. Got {1} {2}." -f $i, $actStr, $TokenLabel) -ForegroundColor Green
            }
        }
    } catch {
        Write-Warning "Slice $i failed: $_ -- skipping."
        $failedSlices++
    }

    # Wait before next slice (skip after the last one)
    if ($i -lt $Slices -and $IntervalSeconds -gt 0) {
        $ts2 = Get-Date -Format "HH:mm:ss"
        Write-Host ("[$ts2] Waiting $IntervalSeconds s before slice {0}..." -f ($i + 1)) -ForegroundColor DarkGray
        Start-Sleep -Seconds $IntervalSeconds
    }
}

# -- summary -------------------------------------------------------------------

Write-Host ""
Write-Host "=== TWAP Buy Complete ===" -ForegroundColor Yellow

$successSlices = $Slices - $failedSlices
$ethSpent      = $successSlices * $sliceEth
$totalTokenHuman = $totalTokenRaw / $TOKEN_SCALE

Write-Host ("  Slices completed : {0} / {1}" -f $successSlices, $Slices)
Write-Host ("  Total base spent : {0:F8} {1}" -f $ethSpent, $script:BaseLabel)
Write-Host ("  Total received   : {0} {1}" -f $totalTokenHuman.ToString("F$tokenDecimals"), $TokenLabel)

if ($slicePrices.Count -gt 0) {
    $avgPrice  = ($slicePrices | Measure-Object -Average).Average
    $minPrice  = ($slicePrices | Measure-Object -Minimum).Minimum
    $maxPrice  = ($slicePrices | Measure-Object -Maximum).Maximum
    $variance  = if ($avgPrice -gt 0) { (($maxPrice - $minPrice) / $avgPrice) * 100.0 } else { 0.0 }
    $si = 0
    $bestSlice  = ($slicePrices | ForEach-Object { $si++; [PSCustomObject]@{ P = $_; I = $si } } | Sort-Object P | Select-Object -First 1)
    $si = 0
    $worstSlice = ($slicePrices | ForEach-Object { $si++; [PSCustomObject]@{ P = $_; I = $si } } | Sort-Object P -Descending | Select-Object -First 1)

    Write-Host ("  Average price    : {0:F8} {1}/token" -f $avgPrice, $script:BaseLabel)
    Write-Host ("  Price range      : {0:F8} to {1:F8} {2}/token" -f $minPrice, $maxPrice, $script:BaseLabel)
    Write-Host ("  Variance         : +/-{0:F2}%" -f ($variance / 2))
    Write-Host ("  Best slice       : Slice {0}  ({1:F8} {2}/token)" -f $bestSlice.I, $bestSlice.P, $script:BaseLabel)
    Write-Host ("  Worst slice      : Slice {0}  ({1:F8} {2}/token)" -f $worstSlice.I, $worstSlice.P, $script:BaseLabel)
}

if ($failedSlices -gt 0) {
    Write-Host ("  WARNING: {0} slice(s) failed -- manual review required." -f $failedSlices) -ForegroundColor Yellow
}
