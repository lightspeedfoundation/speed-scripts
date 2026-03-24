<#
.SYNOPSIS
    Value averaging: on each interval, buy the deficit (or sell the surplus)
    needed to keep a portfolio value trajectory growing by -TargetIncrement (in -BaseToken)
    per interval. Buys more when price is low, less when high.

.DESCRIPTION
    1. Auto-detects token decimals via on-chain RPC call.
    2. Starts with zero accumulated tokens and a zero target value.
    3. Each interval:
       a. Raises the target value by -TargetIncrement (BaseToken units).
       b. Quotes the current accumulated position value.
       c. Computes deficit (target - current) or surplus (current - target).
       d. If deficit > 0: buys min(deficit, MaxBuyPerInterval) BaseToken of tokens.
       e. If surplus > 0 and -AllowSell: sells proportional token fraction.
       f. Prints: interval, target, current value, action, average entry cost.
    4. Runs -Intervals times then prints a final summary.

    Because target grows linearly, the bot buys more tokens when price is low
    (large deficit) and less when price is high (small deficit). If -AllowSell
    is set it trims over-performing positions automatically.

.PARAMETER Token
    Token contract address or shorthand alias ('speed').
    Value targets are in -BaseToken (default: speed).

.PARAMETER TargetIncrement
    BaseToken growth target per interval (e.g. 0.001 = grow position value by 0.001 base
    per interval). This is the "pace" of accumulation.

.PARAMETER Intervals
    Total number of intervals to run. Default: 20.

.PARAMETER IntervalSeconds
    Seconds between intervals. Default: 3600 (1 hour).

.PARAMETER MaxBuyPerInterval
    Maximum BaseToken to spend in any single interval. Caps runaway buys when
    position is far below target. Default: TargetIncrement * 3.

.PARAMETER AllowSell
    Switch. When set, sell the surplus fraction of the position when current
    value exceeds the target. Converts value averaging into a full two-way
    rebalancer.

.PARAMETER DryRun
    Print plan and projected actions without executing any swaps.

.PARAMETER DustThreshold
    Minimum base-token buy size per interval; skips smaller buys. Default 0.0001 in base
    units — override for low-decimal bases (e.g. USDC: -DustThreshold 0.5).

.EXAMPLE
    .\value-average-any.ps1 -Chain base -Token speed -TargetIncrement 0.001 -Intervals 24 -IntervalSeconds 3600
    .\value-average-any.ps1 -Chain base -Token speed -TargetIncrement 0.001 -Intervals 10 -IntervalSeconds 1800 -AllowSell
    .\value-average-any.ps1 -Chain base -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf -TokenSymbol cbBTC -TargetIncrement 0.002 -Intervals 12 -IntervalSeconds 3600 -AllowSell
    .\value-average-any.ps1 -Chain base -Token speed -TargetIncrement 0.001 -Intervals 10 -DryRun
#>

param(
    [Parameter(Mandatory)][string] $Chain,
    [Parameter(Mandatory)][string] $Token,
    [Parameter(Mandatory)][double] $TargetIncrement,
    [string]                       $TokenSymbol        = "",
    [int]                          $Intervals          = 20,
    [int]                          $IntervalSeconds    = 3600,
    [double]                       $MaxBuyPerInterval  = -1,   # -1 = auto (TargetIncrement * 3)
    [switch]                       $AllowSell,
    [switch]                       $DryRun,
    [string]                       $BaseToken       = 'speed',
    [string]                       $BaseTokenSymbol = '',
    [double]                       $DustThreshold   = 0.0001
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

# ── helpers ───────────────────────────────────────────────────────────────────

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

# ── setup ─────────────────────────────────────────────────────────────────────

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

if ($TargetIncrement -le 0) { Write-Error "-TargetIncrement must be > 0."; exit 1 }
if ($Intervals -lt 1)       { Write-Error "-Intervals must be >= 1."; exit 1 }

# Resolve default MaxBuyPerInterval
if ($MaxBuyPerInterval -lt 0) { $MaxBuyPerInterval = $TargetIncrement * 3.0 }

$totalTargetETH = $TargetIncrement * $Intervals

Write-Host ""
Write-Host "=== Speed Value Averaging ===" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY-RUN MODE -- no swaps will execute ***" -ForegroundColor DarkYellow }
Write-Host "  Chain              : $Chain"
Write-Host "  Token              : $TokenLabel  (decimals: $tokenDecimals)"
Write-Host ("  Target increment   : {0:F8} {1} per interval" -f $TargetIncrement, $script:BaseLabel)
Write-Host ("  Max buy/interval   : {0:F8} {1}" -f $MaxBuyPerInterval, $script:BaseLabel)
Write-Host "  Intervals          : $Intervals"
Write-Host "  Interval length    : $IntervalSeconds s"
Write-Host ("  Final target value : {0:F8} {1}  (after all intervals)" -f $totalTargetETH, $script:BaseLabel)
Write-Host ("  Dust threshold     : {0:F8} {1}  (min buy; raise for 6-dec stablecoins, etc.)" -f $DustThreshold, $script:BaseLabel)
Write-Host "  Allow sell         : $($AllowSell.IsPresent)"
Write-Host ""

# ── state ─────────────────────────────────────────────────────────────────────

$accTokenHuman    = 0.0    # accumulated token balance (human units)
$targetValueETH   = 0.0    # current target portfolio value in base token
$totalEthSpent    = 0.0
$totalEthReceived = 0.0
$totalBuys        = 0
$totalSells       = 0
$skippedDust      = 0

# ── interval loop ─────────────────────────────────────────────────────────────

for ($interval = 1; $interval -le $Intervals; $interval++) {
    $ts = Get-Date -Format "HH:mm:ss"

    if ($interval -gt 1) {
        Write-Host ""
        Write-Host ("[$ts] Interval {0}/{1} - waiting {2} s..." -f $interval, $Intervals, $IntervalSeconds) -ForegroundColor DarkGray
        Start-Sleep -Seconds $IntervalSeconds
    } else {
        Write-Host ("[$ts] Interval {0}/{1} - starting now..." -f $interval, $Intervals) -ForegroundColor DarkGray
    }

    $ts2 = Get-Date -Format "HH:mm:ss"

    # a) Raise target
    $targetValueETH += $TargetIncrement

    # b) Get current position value
    $currentValueETH = 0.0
    $currentValueRaw = [double]0

    if ($accTokenHuman -gt 0) {
        try {
            $accStr    = $accTokenHuman.ToString("F$tokenDecimals")
            $valQuote  = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $accStr
            $currentValueRaw = [double]$valQuote.buyAmount
            $currentValueETH = $currentValueRaw / $script:BASE_DECIMALS_SCALE
        } catch {
            Write-Warning "Could not get position value on interval $interval : $_ -- using 0."
            $currentValueETH = 0.0
            $currentValueRaw = [double]0
        }
    }

    # c) Compute deficit / surplus
    $deficitETH  = $targetValueETH - $currentValueETH
    $avgCostStr  = if ($accTokenHuman -gt 0) {
                       ("{0:F8}" -f ($totalEthSpent / $accTokenHuman))
                   } else { "N/A" }

    Write-Host ""
    Write-Host ("=== Interval {0}/{1}  [{2}] ===" -f $interval, $Intervals, $ts2) -ForegroundColor Yellow
    Write-Host ("  Target value    : {0:F8} {1}" -f $targetValueETH, $script:BaseLabel)
    Write-Host ("  Current value   : {0:F8} {3}  ({1} {2} held)" -f $currentValueETH, $accTokenHuman.ToString("F$tokenDecimals"), $TokenLabel, $script:BaseLabel)
    $deficitDisp = if ($deficitETH -ge 0) { '+' + $deficitETH.ToString('F8') } else { $deficitETH.ToString('F8') }
    Write-Host ("  Deficit/Surplus : {0} {1}" -f $deficitDisp, $script:BaseLabel)
    Write-Host ("  Avg entry cost  : {0} {2} per {1}" -f $avgCostStr, $TokenLabel, $script:BaseLabel)

    # d) Buy if below target
    if ($deficitETH -gt 0) {
        $buyETH = [Math]::Min($deficitETH, $MaxBuyPerInterval)

        if ($buyETH -lt $DustThreshold) {
            Write-Host ("  Action          : SKIP (buy amount {0:F8} {1} below dust threshold {2:F8} {1})" -f $buyETH, $script:BaseLabel, $DustThreshold) -ForegroundColor DarkGray
            $skippedDust++
        } else {
            Write-Host ("  Action          : BUY {0:F8} {2} of {1}" -f $buyETH, $TokenLabel, $script:BaseLabel) -ForegroundColor Cyan
            $buyEthStr = $buyETH.ToString("F8")

            if ($DryRun) {
                # Estimate token amount for running tallies
                try {
                    $dryQ       = Get-Quote -sellTok $BaseToken -buyTok $Token -sellAmt $buyEthStr
                    $dryTokRaw  = [double]$dryQ.buyAmount
                    $dryTokHuman= $dryTokRaw / $TOKEN_SCALE
                    $accTokenHuman   += $dryTokHuman
                    $totalEthSpent   += $buyETH
                    $totalBuys++
                    Write-Host ("  [DRY-RUN] Would buy {0} {1} for {2:F8} {3}" -f `
                        $dryTokHuman.ToString("F$tokenDecimals"), $TokenLabel, $buyETH, $script:BaseLabel) -ForegroundColor DarkYellow
                } catch {
                    Write-Warning "Dry-run quote failed: $_"
                }
            } else {
                try {
                    Write-Host ("  >>> speed --json --yes swap -c {0} --sell $BaseToken --buy {1} -a {2} -y" -f `
                        $Chain, $Token, $buyEthStr) -ForegroundColor Cyan

                    $preBuyQ   = Get-Quote -sellTok $BaseToken -buyTok $Token -sellAmt $buyEthStr
                    $preTokRaw = [double]$preBuyQ.buyAmount

                    $swapOut = speed --json --yes swap -c $Chain --sell $BaseToken --buy $Token -a $buyEthStr -y 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "Buy swap failed (exit $LASTEXITCODE)." }

                    $swapObj  = Get-SwapJsonFromSpeedOutput -out $swapOut
                    $gotTokRaw = Resolve-SpeedSwapBuyAmountRaw -SwapJson $swapObj -QuoteBuyRawFallback $preTokRaw
                    if ($null -eq $gotTokRaw) { throw "Could not resolve buy amount from swap JSON." }
                    $gotTokHuman = $gotTokRaw / $TOKEN_SCALE
                    $accTokenHuman += $gotTokHuman
                    $totalEthSpent   += $buyETH
                    $totalBuys++
                } catch {
                    Write-Warning "Buy failed on interval $interval : $_ -- skipping."
                }
            }
        }
    # e) Sell if above target and AllowSell
    } elseif ($deficitETH -lt 0 -and $AllowSell) {
        $surplusETH = -$deficitETH

        if ($currentValueETH -le 0 -or $accTokenHuman -le 0) {
            Write-Host "  Action          : SKIP SELL (no position to sell)" -ForegroundColor DarkGray
        } else {
            # Sell the fraction of tokens that represents the surplus
            $sellRatio   = $surplusETH / $currentValueETH
            if ($sellRatio -gt 1.0) { $sellRatio = 1.0 }
            $sellHuman   = $accTokenHuman * $sellRatio
            $sellStr     = $sellHuman.ToString("F$tokenDecimals")

            if ([double]$sellStr -lt [Math]::Pow(10, -$tokenDecimals)) {
                Write-Host "  Action          : SKIP SELL (amount too small)" -ForegroundColor DarkGray
            } else {
                Write-Host ("  Action          : SELL {0} {1}  (surplus: {2:F8} {4}, {3:F4}% of position)" -f `
                    $sellStr, $TokenLabel, $surplusETH, $sellRatio * 100.0, $script:BaseLabel) -ForegroundColor Magenta

                if ($DryRun) {
                    try {
                        $dryQ2   = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $sellStr
                        $dryEth2 = [double]$dryQ2.buyAmount / $script:BASE_DECIMALS_SCALE
                        Write-Host ("  [DRY-RUN] Would sell {0} {1} for approx {2:F8} {3}" -f `
                            $sellStr, $TokenLabel, $dryEth2, $script:BaseLabel) -ForegroundColor DarkYellow
                        $accTokenHuman   -= $sellHuman
                        $totalEthReceived+= $dryEth2
                        $totalSells++
                    } catch {
                        Write-Warning "Dry-run sell quote failed: $_"
                    }
                } else {
                    try {
                        Write-Host ("  >>> speed --json --yes swap -c {0} --sell {1} --buy $BaseToken -a {2} -y" -f `
                            $Chain, $Token, $sellStr) -ForegroundColor Cyan

                        $preSellQ   = Get-Quote -sellTok $Token -buyTok $BaseToken -sellAmt $sellStr
                        $preBaseRaw = [double]$preSellQ.buyAmount

                        $swapOut = speed --json --yes swap -c $Chain --sell $Token --buy $BaseToken -a $sellStr -y 2>&1
                        if ($LASTEXITCODE -ne 0) { throw "Sell swap failed (exit $LASTEXITCODE)." }

                        $swapObj    = Get-SwapJsonFromSpeedOutput -out $swapOut
                        $gotBaseRaw = Resolve-SpeedSwapBuyAmountRaw -SwapJson $swapObj -QuoteBuyRawFallback $preBaseRaw
                        if ($null -ne $gotBaseRaw) {
                            $ethRec = $gotBaseRaw / $script:BASE_DECIMALS_SCALE
                            $totalEthReceived += $ethRec
                        }

                        $accTokenHuman -= $sellHuman
                        $totalSells++
                    } catch {
                        Write-Warning "Sell failed on interval $interval : $_ -- skipping."
                    }
                }
            }
        }
    } else {
        Write-Host "  Action          : HOLD (value at target)" -ForegroundColor DarkGray
    }
}

# ── final summary ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Value Averaging Complete ===" -ForegroundColor Yellow
Write-Host ("  Intervals run      : {0}" -f $Intervals)
Write-Host ("  Total buys         : {0}" -f $totalBuys)
Write-Host ("  Total sells        : {0}" -f $totalSells)
Write-Host ("  Dust skips         : {0}" -f $skippedDust)
Write-Host ("  Base spent         : {0:F8} {1}" -f $totalEthSpent, $script:BaseLabel)
Write-Host ("  Base received      : {0:F8} {1}" -f $totalEthReceived, $script:BaseLabel)

$netDeployed = $totalEthSpent - $totalEthReceived
Write-Host ("  Net base deployed  : {0:F8} {1}" -f $netDeployed, $script:BaseLabel)

if ($accTokenHuman -gt 0) {
    $accStr = $accTokenHuman.ToString("F$tokenDecimals")
    Write-Host ("  Final position     : {0} {1}" -f $accStr, $TokenLabel)
    if ($totalEthSpent -gt 0 -and $accTokenHuman -gt 0) {
        $avgCost = $totalEthSpent / $accTokenHuman
        Write-Host ("  Avg entry cost     : {0:F8} {2} per {1}" -f $avgCost, $TokenLabel, $script:BaseLabel)
    }
    Write-Host ""
    Write-Host "  Position remains open. Use trailing-stop-any.ps1 or limit-order-any.ps1 to exit." -ForegroundColor DarkGray
} else {
    Write-Host "  Final position     : 0 (fully sold or nothing accumulated)" -ForegroundColor DarkGray
}
