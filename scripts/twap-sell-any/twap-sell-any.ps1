<#
.SYNOPSIS
    TWAP sell: sell an existing token position in N equal slices over time,
    regardless of price. Pure exit tool — no initial buy.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Parses -TokenAmount and computes sliceAmount = TokenAmount / Slices.
    3. For each slice 1..Slices:
       a. Quotes <Token> -> ETH for sliceAmount (preview).
       b. Executes the sell (or logs in DryRun).
       c. Records ETH received and effective price.
       d. Waits IntervalSeconds before the next slice (skipped on last).
    4. Prints a full execution summary: total ETH, average price, best/worst slice.

    Difference from ladder-sell-any: ladder-sell exits at price targets (N profit
    levels). TWAP sell exits on time regardless of price — useful for large
    positions on thin liquidity where a single market sell causes significant
    slippage.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    ETH / native is always the quote currency.

.PARAMETER TokenAmount
    Total token amount to sell (in human-readable units, e.g. "98000" or "0.00002287").
    Run 'speed balance' to find your current holdings.

.PARAMETER Slices
    Number of equal sell slices. Default: 5.

.PARAMETER IntervalSeconds
    Wait time between slices. Default: 300 (5 minutes).

.PARAMETER DryRun
    Quote each slice and log timing without executing any sells.

.EXAMPLE
    .\twap-sell-any.ps1 -Chain base -Token speed -TokenAmount 98000 -Slices 5 -IntervalSeconds 300
    .\twap-sell-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -TokenAmount 0.00002287 -Slices 5 -IntervalSeconds 600
    .\twap-sell-any.ps1 -Chain base -Token speed -TokenAmount 50000 -Slices 5 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][string] $TokenAmount,
    [string]  $TokenSymbol     = "",
    [int]     $Slices          = 5,
    [int]     $IntervalSeconds = 300,
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

# -- setup ---------------------------------------------------------------------

Write-Host ""
Write-Host "Detecting token decimals..." -ForegroundColor DarkGray
$tokenDecimals = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$TOKEN_SCALE   = [Math]::Pow(10, $tokenDecimals)
$TokenLabel    = if ($TokenSymbol -ne "") { $TokenSymbol } else { $Token }

if ($Slices -lt 1)          { Write-Error "-Slices must be >= 1."; exit 1 }
if ($IntervalSeconds -lt 0) { Write-Error "-IntervalSeconds must be >= 0."; exit 1 }

$totalTokenHuman = [double]$TokenAmount
$sliceTokenHuman = $totalTokenHuman / $Slices
$sliceStr        = $sliceTokenHuman.ToString("F$tokenDecimals")

if ([double]$sliceStr -le 0) {
    Write-Error "Slice token amount resolved to 0. Check -TokenAmount and -Slices."
    exit 1
}

$totalDuration = ($Slices - 1) * $IntervalSeconds

Write-Host ""
Write-Host "=== Speed TWAP Sell ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- no sells will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain          : $Chain"
Write-Host "  Token          : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host ("  Total to sell  : {0} {1}" -f $TokenAmount, $TokenLabel)
Write-Host ("  Slices         : {0}  ({1} {2} each)" -f $Slices, $sliceStr, $TokenLabel)
Write-Host "  Interval       : $IntervalSeconds s between slices"
Write-Host ("  Total duration : {0} min  ({1} s)" -f [int]($totalDuration / 60), $totalDuration)
Write-Host ""

# -- execution loop ------------------------------------------------------------

$slicePrices  = @()
$sliceEths    = @()
$totalEthRaw  = [double]0
$failedSlices = 0

for ($i = 1; $i -le $Slices; $i++) {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$ts] Slice {0}/{1} - quoting {2} {3} -> ETH..." -f $i, $Slices, $sliceStr, $TokenLabel) -ForegroundColor DarkCyan

    try {
        $q       = Get-Quote -sellTok $Token -buyTok 'eth' -sellAmt $sliceStr
        $ethRaw  = [double]$q.buyAmount
        $ethBack = $ethRaw / $ETH_DECIMALS
        $price   = if ($sliceTokenHuman -gt 0) { $ethBack / $sliceTokenHuman } else { 0.0 }

        Write-Host ("         Quote: {0:F8} ETH  (price: {1:F8} ETH/token)" -f $ethBack, $price) -ForegroundColor DarkGray

        if ($DryRun) {
            Write-Host ("         [DRY-RUN] Would SELL {0} {1} -> {2:F8} ETH" -f $sliceStr, $TokenLabel, $ethBack) -ForegroundColor DarkYellow
            $slicePrices += $price
            $sliceEths   += $ethBack
            $totalEthRaw += $ethRaw
        } else {
            Write-Host ("         >>> speed swap -c $Chain --sell $Token --buy eth -a $sliceStr -y") -ForegroundColor Cyan
            speed swap -c $Chain --sell $Token --buy eth -a $sliceStr -y
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Slice $i sell failed (exit $LASTEXITCODE). Skipping."
                $failedSlices++
            } else {
                $slicePrices += $price
                $sliceEths   += $ethBack
                $totalEthRaw += $ethRaw
                Write-Host ("         Slice {0} complete. Got {1:F8} ETH." -f $i, $ethBack) -ForegroundColor Green
            }
        }
    } catch {
        Write-Warning "Slice $i failed: $_ -- skipping."
        $failedSlices++
    }

    if ($i -lt $Slices -and $IntervalSeconds -gt 0) {
        $ts2 = Get-Date -Format "HH:mm:ss"
        Write-Host ("[$ts2] Waiting $IntervalSeconds s before slice {0}..." -f ($i + 1)) -ForegroundColor DarkGray
        Start-Sleep -Seconds $IntervalSeconds
    }
}

# -- summary -------------------------------------------------------------------

Write-Host ""
Write-Host "=== TWAP Sell Complete ===" -ForegroundColor Yellow

$successSlices   = $Slices - $failedSlices
$totalEthReceived = $totalEthRaw / $ETH_DECIMALS
$totalTokenSold  = $successSlices * $sliceTokenHuman

Write-Host ("  Slices completed  : {0} / {1}" -f $successSlices, $Slices)
Write-Host ("  Total tokens sold : {0} {1}" -f $totalTokenSold.ToString("F$tokenDecimals"), $TokenLabel)
Write-Host ("  Total ETH received: {0:F8} ETH" -f $totalEthReceived)

if ($slicePrices.Count -gt 0) {
    $avgPrice  = ($slicePrices | Measure-Object -Average).Average
    $minPrice  = ($slicePrices | Measure-Object -Minimum).Minimum
    $maxPrice  = ($slicePrices | Measure-Object -Maximum).Maximum

    $bestSlice  = ($slicePrices | ForEach-Object -Begin { $idx=0 } -Process { [PSCustomObject]@{P=$_; I=++$idx} } | Sort-Object P -Descending | Select-Object -First 1)
    $worstSlice = ($slicePrices | ForEach-Object -Begin { $idx=0 } -Process { [PSCustomObject]@{P=$_; I=++$idx} } | Sort-Object P | Select-Object -First 1)

    Write-Host ("  Average price     : {0:F8} ETH/token" -f $avgPrice)
    Write-Host ("  Price range       : {0:F8} to {1:F8} ETH/token" -f $minPrice, $maxPrice)
    Write-Host ("  Best slice        : Slice {0}  ({1:F8} ETH/token)" -f $bestSlice.I, $bestSlice.P)
    Write-Host ("  Worst slice       : Slice {0}  ({1:F8} ETH/token)" -f $worstSlice.I, $worstSlice.P)
}

if ($failedSlices -gt 0) {
    Write-Host ("  WARNING: {0} slice(s) failed -- check wallet balance for unsold tokens." -f $failedSlices) -ForegroundColor Yellow
}
