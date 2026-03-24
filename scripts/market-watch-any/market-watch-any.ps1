<#
.SYNOPSIS
    Quote-only market watcher for any target/base token pair.

.DESCRIPTION
    1. Quotes BaseToken -> Token for -Amount to derive a fixed reference token size.
    2. Polls Token -> BaseToken every -PollSeconds seconds.
    3. Prints current base return, % vs baseline, and session high/low.
    4. Never executes swaps (watch-only).
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,      # target token (address or alias)
    [Parameter(Mandatory)][string] $Amount,     # base-token amount used to build reference position
    [string]                       $TokenSymbol   = "",
    [string]                       $BaseToken     = "speed",
    [string]                       $BaseTokenSymbol = "",
    [int]                          $PollSeconds   = 60,
    [int]                          $MaxIterations = 0   # 0 = run forever
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
    "10"       = "https://mainnet.optimism.io"
    "arbitrum" = "https://arb1.arbitrum.io/rpc"
    "42161"    = "https://arb1.arbitrum.io/rpc"
    "polygon"  = "https://polygon.llamarpc.com"
    "137"      = "https://polygon.llamarpc.com"
    "bsc"      = "https://bsc-dataseed.binance.org"
    "56"       = "https://bsc-dataseed.binance.org"
}

function Get-TokenDecimals {
    param([string]$tokenAddr, [string]$chainName)

    $lower = $tokenAddr.ToLower()
    if ($lower -in @("speed", "eth", "native", "ether")) { return 18 }
    if (-not $tokenAddr.StartsWith("0x")) { return 18 }

    $rpc = $RPC_URLS[$chainName.ToLower()]
    if (-not $rpc) { return 18 }

    $body = '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"' + $tokenAddr + '","data":"0x313ce567"},"latest"],"id":1}'
    try {
        $resp = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
        $hex  = $resp.result -replace '^0x', ''
        return [Convert]::ToInt32($hex.TrimStart('0'), 16)
    } catch {
        return 18
    }
}

function Get-Quote {
    param([string]$sellTok, [string]$buyTok, [string]$sellAmt)
    $raw  = speed quote --json -c $Chain --sell $sellTok --buy $buyTok -a $sellAmt 2>&1
    $line = $raw | Where-Object { $_ -match '^\{' } | Select-Object -First 1
    if (-not $line) { throw "No JSON from quote. Output:`n$($raw -join "`n")" }
    $obj = $line | ConvertFrom-Json
    if (-not ($obj.PSObject.Properties.Name -contains "buyAmount")) { throw "Quote error: $($obj.error)" }
    return $obj
}

if ($BaseToken.ToLower() -eq $Token.ToLower()) { $BaseToken = "eth" }

$tokenDecimals = Get-TokenDecimals -tokenAddr $Token -chainName $Chain
$baseDecimals  = Get-TokenDecimals -tokenAddr $BaseToken -chainName $Chain
$TOKEN_SCALE   = [Math]::Pow(10, $tokenDecimals)
$BASE_SCALE    = [Math]::Pow(10, $baseDecimals)

$TokenLabel = if ($TokenSymbol) { $TokenSymbol } else { $Token }
$BaseLabel  = if ($BaseTokenSymbol) { $BaseTokenSymbol } else { $BaseToken }

Write-Host ""
Write-Host "=== Speed Market Watch (Quotes Only) ===" -ForegroundColor Yellow
Write-Host "  Chain         : $Chain"
Write-Host "  Target token  : $TokenLabel (decimals: $tokenDecimals)"
Write-Host "  Base token    : $BaseLabel (decimals: $baseDecimals)"
Write-Host "  Reference buy : $Amount $BaseLabel"
Write-Host "  Poll interval : $PollSeconds s"
Write-Host "  Max polls     : $(if ($MaxIterations -le 0) { "infinite" } else { "$MaxIterations" })"
Write-Host ""

Write-Host "Step 1 - Building reference position from quote ($BaseLabel -> $TokenLabel)..." -ForegroundColor DarkCyan
$buyQuote  = Get-Quote -sellTok $BaseToken -buyTok $Token -sellAmt $Amount
$tokenRaw  = [double]$buyQuote.buyAmount
$tokenAmt  = $tokenRaw / $TOKEN_SCALE
$tokenStr  = $tokenAmt.ToString("F$tokenDecimals")

if ([double]$tokenStr -le 0) {
    Write-Error "Reference token amount resolved to 0 (raw=$tokenRaw, decimals=$tokenDecimals)."
    exit 1
}

Write-Host ("  Ref position  : {0} {1}" -f $tokenStr, $TokenLabel)
Write-Host ""

Write-Host "Step 2 - Baseline quote ($TokenLabel -> $BaseLabel)..." -ForegroundColor DarkCyan
$baselineQ   = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $tokenStr
$baselineRaw = [double]$baselineQ.buyAmount
$baselineVal = $baselineRaw / $BASE_SCALE

$highRaw = $baselineRaw
$lowRaw  = $baselineRaw

Write-Host ("  Baseline      : {0:F8} {1}" -f $baselineVal, $BaseLabel)
Write-Host ""

$iteration = 0
$lastRaw = $baselineRaw
while ($MaxIterations -le 0 -or $iteration -lt $MaxIterations) {
    $iteration++
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] Poll $iteration - waiting $PollSeconds s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds

    try {
        $q         = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $tokenStr
        $currentRaw = [double]$q.buyAmount
        $lastRaw = $currentRaw
        if ($currentRaw -gt $highRaw) { $highRaw = $currentRaw }
        if ($currentRaw -lt $lowRaw)  { $lowRaw  = $currentRaw }

        $currentVal = $currentRaw / $BASE_SCALE
        $highVal    = $highRaw / $BASE_SCALE
        $lowVal     = $lowRaw / $BASE_SCALE
        $pctVsBase  = (($currentRaw - $baselineRaw) / $baselineRaw) * 100.0

        $color = if ($pctVsBase -ge 0) { "Green" } else { "DarkRed" }
        $ts2 = Get-Date -Format "HH:mm:ss"
        Write-Host ("[{0}] {1:F8} {2}  ({3:+0.0000;-0.0000}% vs baseline)  [H {4:F8} / L {5:F8}]" -f $ts2, $currentVal, $BaseLabel, $pctVsBase, $highVal, $lowVal) -ForegroundColor $color
    } catch {
        Write-Warning "Quote failed on poll ${iteration}: $_"
    }
}

Write-Host ""
if ($MaxIterations -gt 0) {
    $lastVal      = $lastRaw / $BASE_SCALE
    $highVal      = $highRaw / $BASE_SCALE
    $lowVal       = $lowRaw / $BASE_SCALE
    $netPct       = (($lastRaw - $baselineRaw) / $baselineRaw) * 100.0
    $rangePct     = (($highRaw - $lowRaw) / $baselineRaw) * 100.0
    $drawdownPct  = (($highRaw - $lastRaw) / $baselineRaw) * 100.0

    Write-Host "=== Market Watch Summary ===" -ForegroundColor Yellow
    Write-Host ("  Polls         : {0}" -f $iteration)
    Write-Host ("  Baseline      : {0:F8} {1}" -f $baselineVal, $BaseLabel)
    Write-Host ("  Last          : {0:F8} {1}  ({2:+0.0000;-0.0000}% vs baseline)" -f $lastVal, $BaseLabel, $netPct)
    Write-Host ("  High / Low    : {0:F8} / {1:F8} {2}" -f $highVal, $lowVal, $BaseLabel)
    Write-Host ("  Range         : {0:F4}% of baseline" -f $rangePct)
    Write-Host ("  Off high      : -{0:F4}% from session high" -f $drawdownPct)
    Write-Host ""
    Write-Host "Done: reached MaxIterations ($MaxIterations)." -ForegroundColor Yellow
}
